#!/usr/bin/env bash
# SessionStart hook: reconcile from disk and herdr so a restarted coordinator opens knowing what is live.
# Prints the status digest when anything is open (a plan not yet shipped, a lookup missing reports, a
# live worker, a worktree); prints one quiet line otherwise. Stdout of a SessionStart hook is added to
# the session's context, so this is what the session sees first, together with the registry reminder.
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out="$("$D/status.sh" 2>/dev/null)"
open="$(printf '%s\n' "$out" | grep -cE '^## [^ ]+ \((plan|lookup|task|unknown)\)')"
agents="$(printf '%s\n' "$out" | sed -n '/^## live herdr agents/,$p' | grep -vE '^## |^  none$|^[[:space:]]*$' | grep -c .)"
trees="$(printf '%s\n' "$out" | sed -n '/^## worktrees/,/^## live/p' | grep -vE '^## |^[[:space:]]*$' | grep -c .)"
if [ "$open" -gt 0 ] || [ "$agents" -gt 0 ] || [ "$trees" -gt 0 ]; then
  echo "Workspace state at session start (from plans/ and herdr; restart changes nothing, continue from here):"
  printf '%s\n' "$out"
else
  echo "Workspace state at session start: no open plans, no live workers, no worktrees."
fi
exit 0
