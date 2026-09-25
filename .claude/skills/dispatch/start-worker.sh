#!/usr/bin/env bash
# Start one worker session for one repo of a workstream.
#
# usage: start-worker.sh --workspace <abs path> --plan <abs path to plans/<slug>> \
#          --repo <folder> --branch <workstream slug> [--no-worktree] [--no-plan] \
#          [--read-only | --review] [--window] [--catch-up] [--effort low|medium|high|xhigh|max]
#          [--model <alias or id>] [--add-dir <path>] [--prompt "<text>"] [--dry-run]
#
# What it does, in order:
#   1. preflight: repo exists, plan folder exists, README carries an approval line (plan mode)
#   2. base branch: PR target from REPOS.md, fetched from origin when possible
#   3. checkout: a git worktree under <workspace>/.worktrees/<branch>/<repo> on the workstream
#      branch, or (--no-worktree) the main checkout, which must be clean
#   4. copy the repo's untracked rule files (CLAUDE.md, .claude/) into the worktree
#   5. start the worker: a window in the worker backend (herdr or tmux, see backend.sh) running claude in
#      the permission mode WORKER_PERMISSION_MODE names in workflow.conf, auto by default (routine prompts
#      are answered by the classifier; guard.sh and the deny list still hard-block the dangerous commands)
#   6. record the worker in <plan>/.dispatch/workers.tsv (columns: stamp, repo, name, runner, workspace id,
#      pane, checkout, effort, harness, model, branch, commit; branch and commit are what the worker saw)
#
# --read-only (lookup mode): uses the main checkout as it is, creates no branch or worktree, and gives
#   the worker a profile that denies edits and commits inside the repo; only the report file is writable.
# --review: a read-only worker that grades a diff (integrate's independent reviewer): same profile as
#   --read-only, but model and effort come from MODEL_REVIEW and EFFORT_REVIEW.
# Read-only workers run headless (a background claude -p, no window) when LOOKUP_BACKEND=headless in
#   workflow.conf, which is the default; --window puts this one in the window backend instead.
# --add-dir: an extra folder the worker may read (the plan folder is always added); repeatable.
# --catch-up: reuse the existing worktree and branch and start a worker whose only job is to merge the
#   current origin/<PR target> into the branch and resolve conflicts (the guard allows exactly that merge
#   via WORKSTREAM_ALLOW_MERGE); used by ship-workstream when the merge pre-check fails.
# --model: model for the worker session, a Claude Code alias or id. Defaults come from workflow.conf:
#   MODEL_LOOKUP for read-only lookups, MODEL_REVIEW for reviews, MODEL_CODE for change work; "default" starts claude without a
#   model flag, so the worker runs the model Claude Code starts with on this machine. Recorded with the
#   harness in workers.tsv columns 9 and 10 so metrics can compare harnesses and models later.
# --effort: reasoning effort for the worker session. Defaults come from workflow.conf: EFFORT_LOOKUP for
#   read-only lookups, EFFORT_REVIEW for reviews, EFFORT_CODE for change work.
#
# It never pushes, never touches main/master/staging, and never reads credential files.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/backend.sh"

WORKSPACE=""; PLAN=""; REPO=""; BRANCH=""; WORKTREE=1; NOPLAN=0; READONLY=0; CATCHUP=0; PROMPT=""; DRY=0; EFFORT=""; MODEL=""; ROLE=""; WINDOW=0; EXTRA_DIRS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --workspace) WORKSPACE="$2"; shift 2;;
    --plan) PLAN="$2"; shift 2;;
    --repo) REPO="$2"; shift 2;;
    --branch) BRANCH="$2"; shift 2;;
    --no-worktree) WORKTREE=0; shift;;
    --no-plan) NOPLAN=1; shift;;
    --read-only) READONLY=1; NOPLAN=1; WORKTREE=0; ROLE=lookup; shift;;
    --review) READONLY=1; NOPLAN=1; WORKTREE=0; ROLE=review; shift;;
    --window) WINDOW=1; shift;;
    --add-dir) EXTRA_DIRS+=("$2"); shift 2;;
    --catch-up) CATCHUP=1; shift;;
    --effort) EFFORT="$2"; shift 2;;
    --model) MODEL="$2"; shift 2;;
    --prompt) PROMPT="$2"; shift 2;;
    --dry-run) DRY=1; shift;;
    *) echo "unknown argument: $1" >&2; exit 2;;
  esac
done
[ -n "$WORKSPACE" ] && [ -n "$PLAN" ] && [ -n "$REPO" ] && [ -n "$BRANCH" ] || { echo "missing --workspace, --plan, --repo or --branch" >&2; exit 2; }

# read-only workers go headless unless the config or --window says otherwise; the backend reads WORKER_BACKEND
if [ "$READONLY" = 1 ] && [ "$WINDOW" = 0 ] && [ "$LOOKUP_BACKEND" = headless ]; then WORKER_BACKEND=headless; fi
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS_TEMPLATE="$SKILL_DIR/worker-settings.json"
# physical paths: the trust record and herdr both key on the resolved path (on macOS /var is /private/var)
WORKSPACE="$(cd "$WORKSPACE" 2>/dev/null && pwd -P)" || { echo "workspace folder not found" >&2; exit 2; }
PLAN="$(cd "$PLAN" 2>/dev/null && pwd -P)" || { echo "plan folder not found: $PLAN" >&2; exit 2; }
REPO_DIR="$WORKSPACE/$REPO"
fail() { echo "refused: $*" >&2; exit 1; }

# 1. preflight
[ -d "$REPO_DIR/.git" ] || fail "$REPO_DIR is not a git repo"
[ -d "$PLAN" ] || fail "plan folder $PLAN does not exist"
if is_protected "$BRANCH" && [ "$READONLY" != 1 ]; then fail "workstream branch may not be named $BRANCH (protected)"; fi
if [ "$CATCHUP" = 1 ]; then
  :  # the plan is already approved and dispatched; the branch exists
elif [ "$NOPLAN" = 0 ]; then
  grep -Eq '^> \*\*Status:\*\* approved [0-9]{4}-[0-9]{2}-[0-9]{2}' "$PLAN/README.md" 2>/dev/null \
    || fail "$PLAN/README.md has no line '> **Status:** approved <date>'; the user writes that line"
  [ -d "$PLAN/$REPO" ] || fail "plan has no bucket folder $PLAN/$REPO"
else
  [ -f "$PLAN/TASK.md" ] || fail "no-plan mode needs $PLAN/TASK.md"
fi
mkdir -p "$PLAN/reports" "$PLAN/.dispatch"
rm -f "$PLAN/.dispatch/finished"  # a new worker reopens the plan for the live scans (backend.sh be_rows)
# hard cap on live workers (WORKER_CAP in workflow.conf), checked before any checkout work. Counts workers
# that are working or blocked across every open plan; finished or idle workers do not count. Override for
# one start with WORKER_CAP=<n>.
if [ "$DRY" = 0 ]; then
  be_require || fail "no worker backend; install herdr or tmux"
  live="$(be_live_count "$WORKSPACE/plans")"
  [ "${live:-0}" -lt "$WORKER_CAP" ] || fail "$live workers are live, cap is $WORKER_CAP; wait for reports or start with WORKER_CAP=$((live+1)) if the user says so"
fi
# the worker protocol has one owner; every plan folder gets a copy so workers can read it via --add-dir
cp "$SKILL_DIR/WORKER-RULES.md" "$PLAN/WORKER-RULES.md"
[ -f "$WORKSPACE/learnings/$REPO.md" ] && cp "$WORKSPACE/learnings/$REPO.md" "$PLAN/learnings-$REPO.md"

# 2. base branch = PR target from REPOS.md, else staging if it exists on origin, else default
TARGET="$(awk -v r="## $REPO" '$0==r{f=1;next} /^## /{f=0} f && /^- Branches:/{print}' "$WORKSPACE/REPOS.md" \
  | sed -nE 's/.*PR target ([A-Za-z0-9_\/-]+(\.[A-Za-z0-9_\/-]+)*).*/\1/p' | head -1)"
if [ -z "$TARGET" ]; then
  if git -C "$REPO_DIR" show-ref --verify -q refs/remotes/origin/staging; then TARGET=staging
  else TARGET="$(git -C "$REPO_DIR" symbolic-ref -q --short refs/remotes/origin/HEAD | sed 's#origin/##')"; fi
fi
[ -n "$TARGET" ] || fail "cannot determine the base branch for $REPO"
if [ "$READONLY" = 1 ]; then
  WT="$REPO_DIR"; BASE="(read-only, no branch)"
  # the checkout is read as it is; say so when it is not on the PR target, the answer describes that branch
  CUR="$(git -C "$WT" rev-parse --abbrev-ref HEAD)"
  [ "$CUR" = "$TARGET" ] || echo "note: $REPO checkout is on $CUR, PR target is $TARGET; the answer will describe $CUR"
else
if git -C "$REPO_DIR" fetch -q origin "$TARGET" 2>/dev/null; then BASE="origin/$TARGET"
elif git -C "$REPO_DIR" show-ref --verify -q "refs/remotes/origin/$TARGET"; then BASE="origin/$TARGET"; echo "warning: fetch failed, using stale origin/$TARGET" >&2
else BASE="$TARGET"; echo "warning: no origin/$TARGET, using local $TARGET" >&2; fi

# 3. checkout
if [ "$WORKTREE" = 1 ]; then
  WT="$WORKSPACE/.worktrees/$BRANCH/$REPO"
  if [ -d "$WT" ]; then
    :
  elif git -C "$REPO_DIR" show-ref --verify -q "refs/heads/$BRANCH"; then
    mkdir -p "$(dirname "$WT")"; git -C "$REPO_DIR" worktree add -q "$WT" "$BRANCH"
  else
    mkdir -p "$(dirname "$WT")"; git -C "$REPO_DIR" worktree add -q -b "$BRANCH" "$WT" "$BASE"
  fi
  # 4. untracked rule files from the main checkout
  for f in CLAUDE.md CLAUDE.local.md; do
    [ -f "$REPO_DIR/$f" ] && [ ! -e "$WT/$f" ] && cp "$REPO_DIR/$f" "$WT/$f"
  done
  if [ -d "$REPO_DIR/.claude" ]; then
    rsync -a --exclude worktrees "$REPO_DIR/.claude/" "$WT/.claude/"
  fi
  # reuse the main checkout's installed dependencies, whatever the stack keeps them in: a copy-on-write
  # clone where the filesystem has one, a plain copy otherwise; no shared inodes, so the worker can still
  # run install when the lockfile differs
  for dep in node_modules .venv venv vendor target/debug .gradle build/libs; do
    if [ -d "$REPO_DIR/$dep" ] && [ ! -e "$WT/$dep" ]; then
      mkdir -p "$(dirname "$WT/$dep")"
      if clone_dir "$REPO_DIR/$dep" "$WT/$dep"; then echo "cloned $dep into the worktree" >&2
      else rm -rf "$WT/$dep"; echo "note: $dep clone failed; the worker installs from scratch" >&2; fi
    fi
  done
else
  WT="$REPO_DIR"
  [ -z "$(git -C "$WT" status --porcelain)" ] || fail "$REPO working tree is not clean; no-worktree mode needs a clean checkout"
  CUR="$(git -C "$WT" rev-parse --abbrev-ref HEAD)"
  if [ "$CUR" != "$BRANCH" ]; then
    if git -C "$WT" show-ref --verify -q "refs/heads/$BRANCH"; then git -C "$WT" checkout -q "$BRANCH"
    else git -C "$WT" checkout -q -b "$BRANCH" "$BASE"; fi
  fi
fi
CUR="$(git -C "$WT" rev-parse --abbrev-ref HEAD)"
[ "$CUR" = "$BRANCH" ] || fail "checkout at $WT is on $CUR, not $BRANCH"
fi
HEAD_SHA="$(git -C "$WT" rev-parse --short HEAD)"  # recorded with the branch in workers.tsv: what the worker actually saw

# 5. prompt and worker
HOUSE="Read $PLAN/WORKER-RULES.md with the Read tool first and follow it: it is the worker protocol (scope, git, reading, inbox, report format). Never use cat; use the Read tool or head and sed -n. This repo's CLAUDE.md is authoritative for how to work here."
if [ -z "$PROMPT" ]; then
  if [ "$CATCHUP" = 1 ]; then
    PROMPT="Catch-up task for branch $BRANCH in this checkout, following $PLAN/WORKER-RULES.md (read it with the Read tool first). The ship step found that this branch no longer merges cleanly into origin/$TARGET. Run exactly: git fetch origin $TARGET, then git merge --no-edit origin/$TARGET. Resolve every conflict so that both the workstream's intent and the incoming changes survive; never discard either side blindly. Run this repo's verification per its CLAUDE.md, commit the merge if git did not, and write $PLAN/reports/$REPO.md again with a new section '## Catch-up' listing the conflicted files and how each was resolved. This merge is the only merge you may run."
  elif [ "$READONLY" = 1 ]; then
    PROMPT="Answer the question in $PLAN/TASK.md by reading this repository. This is a lookup: change no file in the repository, commit nothing, run nothing that writes. Write your answer to $PLAN/reports/$REPO.md as TASK.md specifies, starting with the Read at line WORKER-RULES.md asks for and citing files and lines, then stop. $HOUSE"
  elif [ "$NOPLAN" = 0 ]; then
    PROMPT="Execute the tasks in $PLAN/$REPO/ in order. Read $PLAN/ARCHITECTURE.md and $PLAN/CONTRACT.md first; the contract is not yours to change. Work only in this repository checkout. When every task is done, or a DRAFT or GATED block or a contract problem stops you, write $PLAN/reports/$REPO.md in the report format from WORKER-RULES.md, then stop. $HOUSE"
  else
    PROMPT="Execute the task in $PLAN/TASK.md, following the conventions in that file. Work only in this repository checkout. When done or blocked, write $PLAN/reports/$REPO.md as TASK.md specifies, then stop. $HOUSE"
  fi
fi

# worker profile: the shared template with this skill folder's hook paths filled in
SETTINGS="$PLAN/.dispatch/$REPO.settings.json"
sed "s#__SKILL_DIR__#$SKILL_DIR#g" "$SETTINGS_TEMPLATE" > "$SETTINGS"
# read-only profile: the shared profile plus denies on editing or committing inside this repo
if [ "$READONLY" = 1 ]; then
  RO="$PLAN/.dispatch/$REPO.readonly-settings.json"
  jq --arg r "$REPO_DIR" '.permissions.deny += ["Edit(" + $r + "/**)", "Bash(git add:*)", "Bash(git commit:*)", "Bash(git stash:*)", "Bash(git checkout:*)", "Bash(git switch:*)", "Bash(git restore:*)", "Bash(npm install:*)", "Bash(npm ci:*)", "Bash(pnpm install:*)", "Bash(yarn install:*)", "Bash(pip install:*)", "Bash(pip3 install:*)", "Bash(uv sync:*)", "Bash(uv pip:*)", "Bash(poetry install:*)", "Bash(go get:*)", "Bash(go mod download:*)", "Bash(cargo build:*)", "Bash(cargo add:*)", "Bash(bundle install:*)", "Bash(composer install:*)", "Bash(mvn install:*)", "Bash(gradle build:*)", "Bash(dotnet restore:*)", "Bash(mix deps.get:*)"]' "$SETTINGS" > "$RO"
  SETTINGS="$RO"
fi
# role defaults from workflow.conf; --effort and --model override for this one worker
case "$ROLE" in
  lookup) : "${EFFORT:=$EFFORT_LOOKUP}"; : "${MODEL:=$MODEL_LOOKUP}";;
  review) : "${EFFORT:=$EFFORT_REVIEW}"; : "${MODEL:=$MODEL_REVIEW}";;
  *)      : "${EFFORT:=$EFFORT_CODE}";   : "${MODEL:=$MODEL_CODE}";;
esac
case "$EFFORT" in low|medium|high|xhigh|max) ;; *) fail "unknown effort $EFFORT";; esac
case "$WORKER_PERMISSION_MODE" in auto|acceptEdits|default) ;; *) fail "WORKER_PERMISSION_MODE must be auto, acceptEdits or default, not $WORKER_PERMISSION_MODE";; esac
[ "$MODEL" = default ] && MODEL=""  # no flag: the worker runs whatever model claude starts with here
case "$MODEL" in *[!A-Za-z0-9._\[\]-]*) fail "model looks wrong: $MODEL (expected a Claude Code alias or model id)";; esac
dirs=(--add-dir "$PLAN"); for d in ${EXTRA_DIRS[@]+"${EXTRA_DIRS[@]}"}; do dirs+=(--add-dir "$d"); done  # bash 3.2: empty array under set -u
NAME="$(printf '%s-%s' "$BRANCH" "$REPO" | tr -c 'a-z0-9_-\n' '-' | tr '[:upper:]' '[:lower:]' | sed -E 's/^[^a-z]+//' | cut -c1-32)"
STAMP="$(date +%Y-%m-%dT%H:%M:%S)"

if [ "$DRY" = 1 ]; then
  echo "dry-run: would start worker $NAME in $WT (branch $BRANCH from $BASE) via $(be_name), model ${MODEL:-default}, effort $EFFORT, permissions $WORKER_PERMISSION_MODE, reads ${dirs[*]:-}"
  echo "prompt: $PROMPT"
  exit 0
fi

# Pre-trust the repo so the worker does not stall on Claude Code's trust dialog. Claude Code keys
# trust on the main repo path (a worktree resolves to it), so both paths are marked. This writes the
# same flag the dialog writes; every repo here is the user's own, so the answer is always yes. A lock
# serialises the read-modify-write, since a wave starts several workers at once. Headless workers
# never see the dialog and skip this.
CJ="$HOME/.claude.json"
if [ -f "$CJ" ] && [ "$(be_name)" != headless ]; then
  LOCK="$HOME/.claude/.trust.lock"; i=0
  until mkdir "$LOCK" 2>/dev/null; do i=$((i+1)); [ $i -lt 100 ] || { rm -rf "$LOCK"; break; }; sleep 0.1; done
  for p in "$REPO_DIR" "$WT"; do
    if [ "$(jq -r --arg p "$p" '.projects[$p].hasTrustDialogAccepted // false' "$CJ")" != true ]; then
      tmp="$(mktemp)"
      jq --arg p "$p" '.projects[$p] = ((.projects[$p] // {}) + {hasTrustDialogAccepted: true, allowedTools: ((.projects[$p].allowedTools) // [])})' "$CJ" > "$tmp" && mv "$tmp" "$CJ"
      echo "pre-trusted $p for Claude Code" >&2
    fi
  done
  rm -rf "$LOCK"
fi

# open the window; the worker reports its state through state.sh into this file
STATE="$PLAN/.dispatch/state/$REPO"; mkdir -p "$PLAN/.dispatch/state"; rm -f "$STATE"
envs=("WORKER_STATE_FILE=$STATE" "WORKER_REPORT_FILE=$PLAN/reports/$REPO.md"); [ "$CATCHUP" = 1 ] && envs+=("WORKSTREAM_ALLOW_MERGE=$TARGET")
opened="$(BE_LAUNCH_DIR="$PLAN/.dispatch" be_open "$BRANCH/$REPO" "$WT" "${envs[@]}")" || fail "could not open a worker window ($(be_name))"
wsid="${opened%%	*}"; pane="${opened##*	}"
[ -n "$pane" ] && [ "$pane" != null ] || fail "the $(be_name) backend returned no window: $opened"
# record before starting, so a failed or blocked start still leaves a trace for integrate and wrap
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$STAMP" "$REPO" "$NAME" "$(be_name)" "$wsid" "$pane" "$WT" "$EFFORT" claude "${MODEL:-default}" "$CUR" "$HEAD_SHA" >> "$PLAN/.dispatch/workers.tsv"
BE_LAUNCH_DIR="$PLAN/.dispatch" be_start "$NAME" "$pane" "$PROMPT" "${dirs[@]}" --permission-mode "$WORKER_PERMISSION_MODE" --effort "$EFFORT" ${MODEL:+--model "$MODEL"} --settings "$SETTINGS" || fail "the worker did not start"
if [ "$(be_name)" = headless ]; then echo "started $NAME (headless, model ${MODEL:-default}, effort $EFFORT) in $WT; run dir ${pane#headless:}"
else echo "started $NAME ($(be_name) $wsid, pane $pane, model ${MODEL:-default}, effort $EFFORT) in $WT"; fi
echo "read:   .claude/skills/dispatch/backend.sh read $NAME $pane 120"
echo "$(be_attach_hint)"
