#!/usr/bin/env bash
# SessionStart hook for the workspace: if the registry check is older than seven days (or never ran),
# print a one-line reminder. Stdout of a SessionStart hook is added to the session's context.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
WS="$(ws_root)"
[ -f "$WS/REPOS.md" ] || exit 0  # not set up yet: /start creates the registry and stamps the first check
stamp="$WS/.claude/registry-checked"
if [ ! -f "$stamp" ]; then
  echo "Registry check has never run. Tell the user first thing: run 'refresh the registry' (the /refresh-repos skill) so routing is not based on stale entries."
  exit 0
fi
last="$(head -1 "$stamp" | tr -d '[:space:]')"
age=$(( ( $(date +%s) - $(date_epoch "$last") ) / 86400 ))
if [ "$age" -ge 7 ]; then
  echo "Registry check is $age days old (last $last). Tell the user first thing: run 'refresh the registry' (the /refresh-repos skill) before routing anything."
fi
exit 0
