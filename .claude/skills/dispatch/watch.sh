#!/usr/bin/env bash
# Wait for the first live worker to settle and say what happened.
#
# usage: watch.sh [--hook] [--max-seconds N]
#
# Finds every worker recorded in plans/*/.dispatch/workers.tsv whose herdr agent is still alive and
# has no report yet, blocks on `herdr agent wait` for all of them at once, and reports the first one
# that settles:
#   done      <repo> <plan>: report written
#   blocked   <repo> <plan>: <what the pane shows>
#   stopped   <repo> <plan>: agent idle with no report
#
# --hook: run as the coordinator's Stop hook (asyncRewake). Exits 0 silently when nothing is live or
#   another watcher already runs; exits 2 with the line on stderr when something needs the model.
# Without --hook: prints the line to stdout and exits 0, for use inside a skill.
#
# Reads only. Never sends input to a worker.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
HOOK=0; MAX=21600
while [ $# -gt 0 ]; do case "$1" in --hook) HOOK=1;; --max-seconds) MAX="$2"; shift;; esac; shift; done
WS="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
PLANS="$WS/plans"
[ -d "$PLANS" ] || exit 0
command -v herdr >/dev/null || exit 0
LOCK="$PLANS/.watch.lock"

say() { if [ "$HOOK" = 1 ]; then echo "$*" >&2; else echo "$*"; fi; }

# one watcher at a time; a stale lock (dead pid) is taken over
if mkdir "$LOCK" 2>/dev/null; then echo $$ > "$LOCK/pid"
else
  op="$(cat "$LOCK/pid" 2>/dev/null || echo 0)"
  if [ "$op" -gt 0 ] && kill -0 "$op" 2>/dev/null; then exit 0; fi
  echo $$ > "$LOCK/pid"
fi
cleanup() { rm -rf "$LOCK"; [ -n "${PIDS:-}" ] && kill $PIDS 2>/dev/null; }
trap cleanup EXIT

# live workers: the latest herdr row per agent name, agent still known to herdr, and either still
# working/blocked or idle without a report newer than its start (a relaunch or catch-up rewrites the report)
live_names=(); live_repos=(); live_plans=(); live_starts=()
agents="$(herdr agent list 2>/dev/null | jq -r '.result.agents[]? | "\(.name)\t\(.agent_status)"' 2>/dev/null)"
report_is_fresh() { # $1 report path, $2 start stamp (YYYY-MM-DDTHH:MM:SS local)
  [ -f "$1" ] || return 1
  local rm st; rm="$(file_mtime "$1")"; st="$(stamp_epoch "$2")"
  [ "$rm" -ge "$st" ]
}
for tsv in "$PLANS"/*/.dispatch/workers.tsv; do
  [ -f "$tsv" ] || continue
  plan="$(basename "$(dirname "$(dirname "$tsv")")")"
  while IFS=$'\t' read -r stamp repo name runner _ _ _ _; do
    [ "$runner" = herdr ] || continue
    st="$(printf '%s\n' "$agents" | awk -F'\t' -v n="$name" '$1==n {print $2}' | tail -1)"
    [ -n "$st" ] || continue
    case "$st" in working|blocked) ;; *) report_is_fresh "$PLANS/$plan/reports/$repo.md" "$stamp" && continue;; esac
    # keep the latest row per name
    for i in "${!live_names[@]}"; do if [ "${live_names[$i]}" = "$name" ]; then unset 'live_names[i]' 'live_repos[i]' 'live_plans[i]' 'live_starts[i]'; fi; done
    live_names+=("$name"); live_repos+=("$repo"); live_plans+=("$plan"); live_starts+=("$stamp")
  done < "$tsv"
done
live_names=("${live_names[@]:-}"); live_repos=("${live_repos[@]:-}"); live_plans=("${live_plans[@]:-}"); live_starts=("${live_starts[@]:-}")
[ -n "${live_names[0]:-}" ] || exit 0

# already-settled agents need no wait
for i in "${!live_names[@]}"; do
  st="$(herdr agent get "${live_names[$i]}" 2>/dev/null | jq -r '.result.agent.agent_status // empty')"
  if [ "$st" = blocked ]; then
    tail="$(herdr agent read "${live_names[$i]}" --source recent-unwrapped --lines 30 2>/dev/null | grep -E -v '^\s*$' | tail -6 | tr '\n' ' ' | cut -c1-300)"
    say "blocked ${live_repos[$i]} ${live_plans[$i]}: $tail"
    [ "$HOOK" = 1 ] && exit 2 || exit 0
  fi
done

# wait for the first settle; each wait writes its own line to a temp dir
TMP="$(mktemp -d)"; PIDS=""
for i in "${!live_names[@]}"; do
  ( r="$(herdr agent wait "${live_names[$i]}" --until done --until blocked --until idle --timeout $((MAX*1000)) 2>/dev/null | jq -r '.result.agent.agent_status // .error.code // "unknown"')"
    echo "$r" > "$TMP/$i" ) &
  PIDS="$PIDS $!"
done
# poll for the first result file (portable; `wait -n` needs bash 4.3 and is not relied on)
waited=0
while [ "$(ls "$TMP" 2>/dev/null | wc -l | tr -d ' ')" = 0 ] && [ "$waited" -lt "$MAX" ]; do sleep 2; waited=$((waited+2)); done
sleep 1
for i in "${!live_names[@]}"; do
  [ -f "$TMP/$i" ] || continue
  st="$(cat "$TMP/$i")"; repo="${live_repos[$i]}"; plan="${live_plans[$i]}"; name="${live_names[$i]}"
  rm -rf "$TMP"
  case "$st" in
    timeout) exit 0;;
    blocked)
      tail="$(herdr agent read "$name" --source recent-unwrapped --lines 30 2>/dev/null | grep -E -v '^\s*$' | tail -6 | tr '\n' ' ' | cut -c1-300)"
      say "blocked $repo $plan: $tail";;
    *)
      if report_is_fresh "$PLANS/$plan/reports/$repo.md" "${live_starts[$i]}"; then say "done $repo $plan: report at plans/$plan/reports/$repo.md"
      else say "stopped $repo $plan: agent $st with no report; read its pane"; fi;;
  esac
  [ "$HOOK" = 1 ] && exit 2 || exit 0
done
exit 0
