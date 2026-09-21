#!/usr/bin/env bash
# Wait for the first live worker to settle and say what happened.
#
# usage: watch.sh [--hook] [--max-seconds N]
#
# Finds every worker recorded in plans/*/.dispatch/workers.tsv that is still live (working or blocked,
# or idle without a report newer than its start), watches all of them through backend.sh, and reports
# the first one that settles:
#   done      <repo> <plan>: report written
#   blocked   <repo> <plan>: <what the pane shows>
#   stopped   <repo> <plan>: worker idle or gone with no report
#
# --hook: run as the coordinator's Stop hook (asyncRewake). Exits 0 silently when nothing is live or
#   another watcher already runs; exits 2 with the line on stderr when something needs the model.
# Without --hook: prints the line to stdout and exits 0, for use inside a skill.
#
# Reads only. Never sends input to a worker.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/backend.sh"
HOOK=0; MAX=21600
while [ $# -gt 0 ]; do case "$1" in --hook) HOOK=1;; --max-seconds) MAX="$2"; shift;; --plan) shift;; esac; shift; done
WS="$(ws_root)"; PLANS="$WS/plans"
[ -d "$PLANS" ] || exit 0
[ "$(be_name)" != none ] || exit 0
LOCK="$PLANS/.watch.lock"
say() { if [ "$HOOK" = 1 ]; then echo "$*" >&2; else echo "$*"; fi; }

# one watcher at a time; a stale lock (dead pid) is taken over
if mkdir "$LOCK" 2>/dev/null; then echo $$ > "$LOCK/pid"
else
  op="$(cat "$LOCK/pid" 2>/dev/null || echo 0)"
  if [ "$op" -gt 0 ] && kill -0 "$op" 2>/dev/null; then exit 0; fi
  echo $$ > "$LOCK/pid"
fi
trap 'rm -rf "$LOCK"' EXIT

report_is_fresh() { # $1 report path, $2 start stamp
  [ -f "$1" ] || return 1
  [ "$(file_mtime "$1")" -ge "$(stamp_epoch "$2")" ]
}
pane_tail() { be_read "$1" "$2" 30 | grep -E -v '^\s*$' | tail -6 | tr '\n' ' ' | cut -c1-300; }

# live rows: plan, repo, name, id, pane, stamp (latest row per worker name)
rows="$(be_rows "$PLANS")"
live=""
while IFS=$'\t' read -r plan repo name id pane stamp; do
  [ -n "$name" ] || continue
  st="$(be_status "$name" "$pane" "$PLANS/$plan/.dispatch/state/$repo")"
  case "$st" in
    working|blocked) ;;
    *) report_is_fresh "$PLANS/$plan/reports/$repo.md" "$stamp" && continue;;
  esac
  live="$live$plan	$repo	$name	$id	$pane	$stamp
"
done <<< "$rows"
[ -n "$live" ] || exit 0

# poll until the first one settles
waited=0
while [ "$waited" -le "$MAX" ]; do
  while IFS=$'\t' read -r plan repo name id pane stamp; do
    [ -n "$name" ] || continue
    st="$(be_status "$name" "$pane" "$PLANS/$plan/.dispatch/state/$repo")"
    case "$st" in
      working) continue;;
      blocked) say "blocked $repo $plan: $(pane_tail "$name" "$pane")";;
      *) if report_is_fresh "$PLANS/$plan/reports/$repo.md" "$stamp"; then say "done $repo $plan: report at plans/$plan/reports/$repo.md"
         else say "stopped $repo $plan: worker $st with no report; read its pane"; fi;;
    esac
    [ "$HOOK" = 1 ] && exit 2 || exit 0
  done <<< "$live"
  sleep 2; waited=$((waited+2))
done
exit 0
