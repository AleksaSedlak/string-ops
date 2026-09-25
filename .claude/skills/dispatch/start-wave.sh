#!/usr/bin/env bash
# Start every change worker of one wave at once, each through start-worker.sh in the background, and
# print their results in order. One cap check for the whole wave, so a wave of five never starts three.
# Repos whose REPOS.md entry says workers use the main checkout get --no-worktree without anyone
# having to remember it.
#
#   start-wave.sh --workspace <abs path> --plan <abs path to plans/<workstream>> --branch <workstream> [--dry-run] <repo> [<repo> ...]
#
# Exit 1 when any start failed; the others are still running. Each start's full output is kept in
# <plan>/.dispatch/start-<repo>.log.
set -uo pipefail
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$D/backend.sh"
WORKSPACE=""; PLAN=""; BRANCH=""; DRY=""; REPOS=()
while [ $# -gt 0 ]; do case "$1" in --workspace) WORKSPACE="$2"; shift 2;; --plan) PLAN="$2"; shift 2;; --branch) BRANCH="$2"; shift 2;; --dry-run) DRY=--dry-run; shift;; -*) echo "unknown argument: $1" >&2; exit 2;; *) REPOS+=("$1"); shift;; esac; done
[ -n "$WORKSPACE" ] && [ -n "$PLAN" ] && [ -n "$BRANCH" ] && [ ${#REPOS[@]} -gt 0 ] || { echo "need --workspace, --plan, --branch and at least one repo" >&2; exit 2; }
WORKSPACE="$(cd "$WORKSPACE" && pwd -P)"; PLAN="$(cd "$PLAN" && pwd -P)"
mkdir -p "$PLAN/.dispatch"

if [ -z "$DRY" ]; then
  be_require || { echo "no worker backend; install herdr or tmux" >&2; exit 1; }
  live="$(be_live_count "$WORKSPACE/plans")"
  if [ $(( ${live:-0} + ${#REPOS[@]} )) -gt "$WORKER_CAP" ]; then
    echo "refused: $live workers are live and this wave needs ${#REPOS[@]} more, cap is $WORKER_CAP; wait for reports or start with WORKER_CAP=$(( live + ${#REPOS[@]} )) if the user says so" >&2; exit 1
  fi
fi

exempt() { awk -v r="## $1" '$0==r{f=1;next} /^## /{f=0} f && /^- Branches:/{print}' "$WORKSPACE/REPOS.md" | grep -qi 'main checkout'; }
pids=(); logs=()
for repo in "${REPOS[@]}"; do
  log="$PLAN/.dispatch/start-$repo.log"; logs+=("$log")
  args=(--workspace "$WORKSPACE" --plan "$PLAN" --repo "$repo" --branch "$BRANCH")
  exempt "$repo" && args+=(--no-worktree)
  [ -n "$DRY" ] && args+=("$DRY")
  "$D/start-worker.sh" "${args[@]}" > "$log" 2>&1 & pids+=($!)
done
failed=0; i=0
for repo in "${REPOS[@]}"; do
  wait "${pids[$i]}"; rc=$?
  echo "=== $repo (exit $rc)"; cat "${logs[$i]}"
  [ $rc -eq 0 ] || failed=1
  i=$((i+1))
done
exit $failed
