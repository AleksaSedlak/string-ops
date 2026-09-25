#!/usr/bin/env bash
# Start the independent reviewer for one repo of a workstream: a read-only worker on MODEL_REVIEW at
# EFFORT_REVIEW that grades the branch against the task files, the contract and the worker's own report.
# The worker that wrote a diff never grades it.
#
#   start-review.sh --workspace <abs path> --plan <abs path to plans/<workstream>> --repo <repo> [--dry-run]
#
# Writes plans/<workstream>-review-<repo>/TASK.md with paths into the workstream folder (the reviewer reads
# the task files, CONTRACT.md and the report itself; nothing is pasted, so the coordinator never has to
# load them) and starts the worker with both folders readable. Dispatch runs it for every repo of a wave
# as soon as that wave's reports are in, so the review of wave 1 runs while wave 2 codes; integrate runs
# it for any repo that still has no review. Refuses without the worker's report. Re-running it while the
# review is live or done says so and starts nothing.
set -euo pipefail
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$D/backend.sh"
WORKSPACE=""; PLAN=""; REPO=""; DRY=""
while [ $# -gt 0 ]; do case "$1" in --workspace) WORKSPACE="$2"; shift 2;; --plan) PLAN="$2"; shift 2;; --repo) REPO="$2"; shift 2;; --dry-run) DRY=--dry-run; shift;; *) echo "unknown argument: $1" >&2; exit 2;; esac; done
[ -n "$WORKSPACE" ] && [ -n "$PLAN" ] && [ -n "$REPO" ] || { echo "need --workspace, --plan, --repo" >&2; exit 2; }
WORKSPACE="$(cd "$WORKSPACE" && pwd -P)"; PLAN="$(cd "$PLAN" && pwd -P)"
fail() { echo "start-review: $*" >&2; exit 1; }
WS_SLUG="$(basename "$PLAN")"
[ -f "$PLAN/reports/$REPO.md" ] || fail "no report yet at $PLAN/reports/$REPO.md; the reviewer needs the worker's report"
[ -d "$PLAN/$REPO" ] || fail "plan has no bucket folder $PLAN/$REPO"
TARGET="$(awk -v r="## $REPO" '$0==r{f=1;next} /^## /{f=0} f && /^- Branches:/{print}' "$WORKSPACE/REPOS.md" \
  | sed -nE 's/.*PR target ([A-Za-z0-9_\/-]+(\.[A-Za-z0-9_\/-]+)*).*/\1/p' | head -1)"
[ -n "$TARGET" ] || TARGET="$(git -C "$WORKSPACE/$REPO" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#origin/##')"
[ -n "$TARGET" ] || fail "cannot determine the PR target for $REPO"

RP="$WORKSPACE/plans/$WS_SLUG-review-$REPO"
if [ -f "$RP/reports/$REPO.md" ] && [ -f "$RP/.dispatch/workers.tsv" ] \
   && [ "$(file_mtime "$RP/reports/$REPO.md")" -ge "$(stamp_epoch "$(tail -1 "$RP/.dispatch/workers.tsv" | cut -f1)")" ]; then
  echo "review of $REPO already done: $RP/reports/$REPO.md"; exit 0
fi
if [ -f "$RP/.dispatch/workers.tsv" ]; then
  row="$(tail -1 "$RP/.dispatch/workers.tsv")"; st="$(be_status "$(printf '%s' "$row" | cut -f3)" "$(printf '%s' "$row" | cut -f6)" "$RP/.dispatch/state/$REPO")"
  case "$st" in working|blocked) echo "review of $REPO is already $st in $RP"; exit 0;; esac
fi
mkdir -p "$RP/reports"
cat > "$RP/TASK.md" <<TASK
# Lookup - review of $REPO for workstream $WS_SLUG

Repos: $REPO

## Question

Review the branch \`$WS_SLUG\` of this repository against its task files, their acceptance criteria and the contract. Read the diff with \`git diff origin/$TARGET..$WS_SLUG\` and files with \`git show $WS_SLUG:<path>\`; the branch lives in a worktree, so do not rely on the working tree you are in.

Report only gaps that affect correctness or a stated requirement: an acceptance criteria line not met, or met without a test proving it; a listed edge case without a test; a change to a file no task lists (say which); a departure from CONTRACT.md, including a payload, route, type or topic that differs from what the contract says (quote both); a test that asserts less than the task asks. Do not report style, naming or preferences. For each gap: file and line, which requirement it breaks, and what the fix is. If you find none, say so plainly.

## Inputs (read these with the Read tool; they are in the workstream folder, which you may read)

- Task files: $PLAN/$REPO/task-*.md
- Contract: $PLAN/CONTRACT.md
- The worker's report, including its acceptance-criteria evidence: $PLAN/reports/$REPO.md
- Notes workers left: $PLAN/NOTES.md

## Conventions

Read only: change no file, commit nothing, install nothing. Follow \`WORKER-RULES.md\` in this folder for reading and report rules.

## Report

Write \`$RP/reports/$REPO.md\` with: \`Read at: <branch> @ <short commit>\` of the reviewed branch, then \`## Verdict\` (\`ready\` or \`gaps\`), \`## Gaps\` (one bullet each, or "None"), \`## Contract\` ("respected" or one bullet per deviation), \`## Not determined\`, \`## Learnings verified\`, \`## Learnings\`.
TASK
"$D/start-worker.sh" --workspace "$WORKSPACE" --plan "$RP" --repo "$REPO" --branch "$WS_SLUG-review" --review --add-dir "$PLAN" $DRY
