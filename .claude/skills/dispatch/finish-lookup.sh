#!/usr/bin/env bash
# End of a lookup, in one command: every report is in, learnings are harvested, cross-repo ties the
# reports revealed are recorded in REPOS.md, the metrics row is written, and the workers'
# windows are closed. The plan folder and its reports stay.
#
#   finish-lookup.sh --plan <abs path to plans/q-<slug>> [--force]
#
# Refuses when a repo listed in TASK.md has no report yet (a worker is still running or stopped);
# --force finishes anyway. Safe to re-run: learnings and links are deduplicated by their scripts, the
# metrics row is written once (stamp in .dispatch/finished), closed workspaces are skipped, and a
# worker that is still working is never closed.
set -uo pipefail
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$D/backend.sh"
WS="${WORKSPACE_ROOT:-$(cd "$D/../../.." && pwd)}"
PLAN=""; FORCE=0
while [ $# -gt 0 ]; do case "$1" in --plan) PLAN="$2"; shift 2;; --force) FORCE=1; shift;; *) echo "unknown argument: $1" >&2; exit 2;; esac; done
fail() { echo "finish-lookup: $*" >&2; exit 1; }
[ -n "$PLAN" ] && [ -f "$PLAN/TASK.md" ] || fail "need --plan with a TASK.md"
head -1 "$PLAN/TASK.md" | grep -q '^# Lookup' || fail "$PLAN is not a lookup (TASK.md does not start with '# Lookup')"

repos="$(grep -m1 '^Repos:' "$PLAN/TASK.md" | sed 's/^Repos://' | tr ',' ' ')"
missing=""
for r in $repos; do [ -f "$PLAN/reports/$r.md" ] || missing="$missing $r"; done
if [ -n "$missing" ] && [ "$FORCE" = 0 ]; then fail "no report yet for:$missing. Run watch.sh until every worker settles, or --force to finish without them"; fi
[ -z "$missing" ] || echo "finishing without reports for:$missing"

echo "--- learnings"; "$D/learn.sh" --plan "$PLAN"
echo "--- registry links"; "$D/link-repos.sh" --plan "$PLAN"
echo "--- metrics"
if [ -f "$PLAN/.dispatch/finished" ]; then echo "row already written on $(head -1 "$PLAN/.dispatch/finished")"
else "$WS/.claude/skills/wrap-workstream/metrics.sh" --plan "$PLAN" && { mkdir -p "$PLAN/.dispatch"; date +%FT%T > "$PLAN/.dispatch/finished"; }; fi

echo "--- workspaces"
tsv="$PLAN/.dispatch/workers.tsv"
if [ -f "$tsv" ] && [ "$(be_name)" != none ]; then
  awk -F'\t' '{print $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6}' "$tsv" | sort -u -k4,4 | while IFS=$'\t' read -r repo name runner wsid pane; do
    [ -n "$wsid" ] || continue
    st="$(be_status "$name" "$pane" "$PLAN/.dispatch/state/$repo")"
    case "$st" in
      working|blocked) echo "kept $wsid: $name is $st (steer it or wait, then re-run)";;
      gone) echo "$runner worker $name already closed";;
      *) be_close "$wsid" && echo "closed $runner worker $name" || echo "$runner worker $name already closed";;
    esac
  done
else echo "no worker windows recorded"; fi

echo "--- reports"
for r in $repos; do [ -f "$PLAN/reports/$r.md" ] && echo "$PLAN/reports/$r.md"; done
exit 0
