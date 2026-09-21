#!/usr/bin/env bash
# Worker-side hook: records the worker's own state so the workspace can watch it without a backend
# that tracks agents. Writes "<state> <stamp>" to the file named by WORKER_STATE_FILE (set by
# start-worker when it opens the window). Wired in worker-settings.json:
#   PreToolUse and UserPromptSubmit -> working
#   Notification permission_prompt|agent_needs_input|elicitation_dialog -> blocked
#   Notification idle_prompt and Stop -> idle
# usage: state.sh working|idle|blocked|from-notification   (reads the hook JSON on stdin when needed)
set -u
f="${WORKER_STATE_FILE:-}"; [ -n "$f" ] || exit 0
st="${1:-}"
if [ "$st" = from-notification ]; then
  kind="$(jq -r '.notification_type // .matcher // empty' 2>/dev/null)"
  case "$kind" in idle_prompt) st=idle;; permission_prompt|agent_needs_input|elicitation_dialog) st=blocked;; *) exit 0;; esac
fi
case "$st" in working|idle|blocked) mkdir -p "$(dirname "$f")"; printf '%s %s\n' "$st" "$(date +%Y-%m-%dT%H:%M:%S)" > "$f";; esac
exit 0
