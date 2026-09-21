#!/usr/bin/env bash
# Notification hook for workers: a worker that needs a person pings the desktop, naming its checkout.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
input="$(cat)"
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)"
kind="$(printf '%s' "$input" | jq -r '.notification_type // .matcher // "needs input"' 2>/dev/null)"
name="$(basename "$cwd" 2>/dev/null)"
notify_desktop "Workspace worker needs you" "$name: $kind"
exit 0
