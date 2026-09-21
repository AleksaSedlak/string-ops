#!/usr/bin/env bash
# Compare the files a branch changed with the files its task files list. Extras are findings.
#
# usage: scope-check.sh --checkout <abs path> --base <ref, e.g. origin/staging> --tasks <dir with task-*.md> [--tasks <file or dir> ...]
#
# Planned files are every backticked path under a "## Files to touch" heading in the task files
# (the repo prefix "<repo>/" is stripped). Test files next to planned files are allowed without being
# listed: paths under test/, tests/, __tests__/, e2e/, or named *.test.* / *.spec.*. Everything else
# that changed is printed as UNPLANNED. Exit 0 always; the caller decides what is blocking.
set -uo pipefail
CO=""; BASE=""; TASKS=()
while [ $# -gt 0 ]; do case "$1" in --checkout) CO="$2"; shift 2;; --base) BASE="$2"; shift 2;; --tasks) TASKS+=("$2"); shift 2;; *) echo "unknown argument: $1" >&2; exit 2;; esac; done
[ -n "$CO" ] && [ -n "$BASE" ] && [ ${#TASKS[@]} -gt 0 ] || { echo "need --checkout, --base, --tasks" >&2; exit 2; }
repo="$(basename "$CO")"
planned="$(for t in "${TASKS[@]}"; do if [ -d "$t" ]; then cat "$t"/task-*.md 2>/dev/null; else cat "$t" 2>/dev/null; fi; done \
  | awk '/^## Files to touch/{f=1;next} /^## /{f=0} f' | grep -oE '`[^`]+`' | tr -d '`' | sed -E "s#^$repo/##; s#^\./##; s#[[:space:]].*##" | sort -u)"
changed="$(git -C "$CO" diff --name-only "$BASE...HEAD" 2>/dev/null | sort -u)"  # three dots: only the branch's own changes since the merge base
[ -n "$changed" ] || { echo "no changes between $BASE and HEAD"; exit 0; }
echo "planned files: $(printf '%s\n' "$planned" | grep -c . )"
unplanned=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if printf '%s\n' "$planned" | grep -qxF "$f"; then echo "PLANNED   $f"; continue; fi
  if printf '%s' "$f" | grep -qE '(^|/)(test|tests|__tests__|e2e)/|\.(test|spec)\.[a-z]+$'; then echo "TEST      $f"; continue; fi
  echo "UNPLANNED $f"; unplanned=$((unplanned+1))
done <<< "$changed"
echo "unplanned: $unplanned"
