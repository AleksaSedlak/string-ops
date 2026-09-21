#!/usr/bin/env bash
# Start one worker session for one repo of a workstream.
#
# usage: start-worker.sh --workspace <abs path> --plan <abs path to plans/<slug>> \
#          --repo <folder> --branch <workstream slug> [--no-worktree] [--no-plan] \
#          [--read-only] [--catch-up] [--effort low|medium|high|xhigh|max] [--model <alias or id>] [--prompt "<text>"] [--dry-run]
#
# What it does, in order:
#   1. preflight: repo exists, plan folder exists, README carries an approval line (plan mode)
#   2. base branch: PR target from REPOS.md, fetched from origin when possible
#   3. checkout: a git worktree under <workspace>/.worktrees/<branch>/<repo> on the workstream
#      branch, or (--no-worktree) the main checkout, which must be clean
#   4. copy the repo's untracked rule files (CLAUDE.md, .claude/) into the worktree
#   5. start the worker: a herdr workspace + claude agent in auto permission mode (routine prompts are
#      answered by the classifier; guard.sh and the deny list still hard-block the dangerous commands).
#      herdr is required; there is no other runner (the background `claude -p` path was removed 2026-09-21
#      as untested and unsteerable)
#   6. record the worker in <plan>/.dispatch/workers.tsv (columns: stamp, repo, name, runner, workspace id,
#      pane, checkout, effort, harness, model, branch, commit; branch and commit are what the worker saw)
#
# --read-only (lookup mode): uses the main checkout as it is, creates no branch or worktree, and gives
#   the worker a profile that denies edits and commits inside the repo; only the report file is writable.
# --catch-up: reuse the existing worktree and branch and start a worker whose only job is to merge the
#   current origin/<PR target> into the branch and resolve conflicts (the guard allows exactly that merge
#   via WORKSTREAM_ALLOW_MERGE); used by ship-workstream when the merge pre-check fails.
# --model: model for the worker session (default: the harness default, which is the user's model). Recorded
#   with the harness in workers.tsv columns 9 and 10 so metrics can compare harnesses and models later.
# --effort: reasoning effort for the worker session. Defaults come from workflow.conf: EFFORT_LOOKUP for
#   read-only lookups, EFFORT_CODE for change work.
#
# It never pushes, never touches main/master/staging, and never reads credential files.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

WORKSPACE=""; PLAN=""; REPO=""; BRANCH=""; WORKTREE=1; NOPLAN=0; READONLY=0; CATCHUP=0; PROMPT=""; DRY=0; EFFORT=""; MODEL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --workspace) WORKSPACE="$2"; shift 2;;
    --plan) PLAN="$2"; shift 2;;
    --repo) REPO="$2"; shift 2;;
    --branch) BRANCH="$2"; shift 2;;
    --no-worktree) WORKTREE=0; shift;;
    --no-plan) NOPLAN=1; shift;;
    --read-only) READONLY=1; NOPLAN=1; WORKTREE=0; shift;;
    --catch-up) CATCHUP=1; shift;;
    --effort) EFFORT="$2"; shift 2;;
    --model) MODEL="$2"; shift 2;;
    --prompt) PROMPT="$2"; shift 2;;
    --dry-run) DRY=1; shift;;
    *) echo "unknown argument: $1" >&2; exit 2;;
  esac
done
[ -n "$WORKSPACE" ] && [ -n "$PLAN" ] && [ -n "$REPO" ] && [ -n "$BRANCH" ] || { echo "missing --workspace, --plan, --repo or --branch" >&2; exit 2; }

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
  # reuse the main checkout's installed dependencies: a copy-on-write clone where the filesystem has
  # one, a plain copy otherwise; no shared inodes, so the worker can still run install when the lockfile differs
  if [ -d "$REPO_DIR/node_modules" ] && [ ! -e "$WT/node_modules" ]; then
    if clone_dir "$REPO_DIR/node_modules" "$WT/node_modules"; then echo "cloned node_modules into the worktree" >&2
    else rm -rf "$WT/node_modules"; echo "note: node_modules clone failed; the worker installs from scratch" >&2; fi
  fi
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
    PROMPT="Execute the tasks in $PLAN/$REPO/ in order, following $PLAN/AGENT-HANDOFF.md. Work only in this repository checkout. When every task is done, or a DRAFT or GATED block or a contract problem stops you, write $PLAN/reports/$REPO.md exactly as the handoff specifies, then stop. $HOUSE"
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
  jq --arg r "$REPO_DIR" '.permissions.deny += ["Edit(" + $r + "/**)", "Bash(git add:*)", "Bash(git commit:*)", "Bash(git stash:*)", "Bash(git checkout:*)", "Bash(git switch:*)", "Bash(git restore:*)", "Bash(npm install:*)", "Bash(npm ci:*)"]' "$SETTINGS" > "$RO"
  SETTINGS="$RO"
fi
if [ -z "$EFFORT" ]; then if [ "$READONLY" = 1 ]; then EFFORT="$EFFORT_LOOKUP"; else EFFORT="$EFFORT_CODE"; fi; fi
case "$EFFORT" in low|medium|high|xhigh|max) ;; *) fail "unknown effort $EFFORT";; esac
NAME="$(printf '%s-%s' "$BRANCH" "$REPO" | tr -c 'a-z0-9_-\n' '-' | tr '[:upper:]' '[:lower:]' | sed -E 's/^[^a-z]+//' | cut -c1-32)"
STAMP="$(date +%Y-%m-%dT%H:%M:%S)"

if [ "$DRY" = 1 ]; then
  echo "dry-run: would start worker $NAME in $WT (branch $BRANCH from $BASE) via herdr, effort $EFFORT"
  echo "prompt: $PROMPT"
  exit 0
fi

# Pre-trust the repo so the worker does not stall on Claude Code's trust dialog. Claude Code keys
# trust on the main repo path (a worktree resolves to it), so both paths are marked. This writes the
# same flag the dialog writes; every repo here is the user's own, so the answer is always yes.
CJ="$HOME/.claude.json"
if [ -f "$CJ" ]; then
  for p in "$REPO_DIR" "$WT"; do
    if [ "$(jq -r --arg p "$p" '.projects[$p].hasTrustDialogAccepted // false' "$CJ")" != true ]; then
      tmp="$(mktemp)"
      jq --arg p "$p" '.projects[$p] = ((.projects[$p] // {}) + {hasTrustDialogAccepted: true, allowedTools: ((.projects[$p].allowedTools) // [])})' "$CJ" > "$tmp" && mv "$tmp" "$CJ"
      echo "pre-trusted $p for Claude Code" >&2
    fi
  done
fi

# hard cap on live workers (WORKER_CAP in workflow.conf). Counts named herdr agents that are working or
# blocked; finished or idle workers do not count. Override for one start with WORKER_CAP=<n> in the environment.
CAP="$WORKER_CAP"
command -v herdr >/dev/null || fail "herdr is not installed or not on PATH; workers run only in herdr"
live="$(herdr agent list 2>/dev/null | jq '[.result.agents[]? | select(.name != null and (.agent_status == "working" or .agent_status == "blocked"))] | length' 2>/dev/null || echo 0)"
[ "${live:-0}" -lt "$CAP" ] || fail "$live workers are live, cap is $CAP; wait for reports or start with WORKER_CAP=$((live+1)) if the user says so"

if [ "$CATCHUP" = 1 ]; then created="$(herdr workspace create --cwd "$WT" --label "$BRANCH/$REPO" --env "WORKSTREAM_ALLOW_MERGE=$TARGET" --no-focus)"
else created="$(herdr workspace create --cwd "$WT" --label "$BRANCH/$REPO" --no-focus)"; fi
pane="$(printf '%s\n' "$created" | jq -r '.result.root_pane.pane_id')"
wsid="$(printf '%s\n' "$created" | jq -r '.result.workspace.workspace_id')"
[ -n "$pane" ] && [ "$pane" != null ] || fail "herdr did not return a pane: $created"
# record before starting, so a failed or blocked start still leaves a trace for integrate and wrap
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$STAMP" "$REPO" "$NAME" herdr "$wsid" "$pane" "$WT" "$EFFORT" claude "${MODEL:-default}" "$CUR" "$HEAD_SHA" >> "$PLAN/.dispatch/workers.tsv"
herdr agent start "$NAME" --kind claude --pane "$pane" --timeout 120000 -- \
  --add-dir "$PLAN" --permission-mode auto --effort "$EFFORT" ${MODEL:+--model "$MODEL"} --settings "$SETTINGS" --name "$NAME" >/dev/null
herdr agent prompt "$NAME" "$PROMPT" >/dev/null
# confirm the turn actually started; a bare `agent wait` right after a prompt can return the old idle state
herdr agent wait "$NAME" --until working --until blocked --timeout 20000 >/dev/null || echo "warning: $NAME did not start working within 20 s; read its pane" >&2
echo "started $NAME (herdr workspace $wsid, pane $pane, effort $EFFORT) in $WT"
echo "wait:   herdr agent wait $NAME --timeout 1800000"
echo "read:   herdr agent read $NAME --source recent-unwrapped --lines 120"
