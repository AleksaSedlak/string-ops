#!/usr/bin/env bash
# Gate 2 from any device: the coordinator asks "Approve plan <workstream>?" with AskUserQuestion, and
# this hook, not the model, writes the approval line when the person picks "Approve". The answer comes
# from the person's own tap or keypress (in the terminal or the Claude app), so the model still cannot
# approve its own plan. Editing the README line by hand keeps working.
#
# Wired in the workspace settings on AskUserQuestion:
#   PreToolUse:  approve.sh --guard   refuses a call that carries its own answers; answers come from the person
#   PostToolUse: approve.sh           for each "Approve plan <workstream>?" answered "Approve", rewrites the
#                                     README status line of plans/<workstream>/ to "approved <date>"
# Reads the hook JSON on stdin. Writes only that one line.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
input="$(cat)"

if [ "${1:-}" = --guard ]; then
  n="$(printf '%s' "$input" | jq -r '(.tool_input.answers // {}) | length' 2>/dev/null || echo 0)"
  if [ "${n:-0}" -gt 0 ]; then
    echo "BLOCKED: answers come from the person. Ask again without the answers field." >&2
    exit 2
  fi
  exit 0
fi

PLANS="$(ws_root)/plans"; today="$(date +%Y-%m-%d)"; done_list=""
while IFS=$'\t' read -r q a; do
  ws="$(printf '%s' "$q" | sed -nE 's/^Approve plan ([a-z0-9][a-z0-9-]*)\?$/\1/p')"
  [ -n "$ws" ] && [ "$a" = Approve ] || continue
  r="$PLANS/$ws/README.md"
  grep -Eq '^> \*\*Status:\*\* landed ' "$r" 2>/dev/null || continue
  awk -v d="$today" '!s && /^> \*\*Status:\*\* landed / { print "> **Status:** approved " d " (answered Approve)"; s=1; next } { print }' "$r" > "$r.tmp" && mv "$r.tmp" "$r" \
    && done_list="$done_list $ws"
done <<< "$(printf '%s' "$input" | jq -r '(.tool_response.answers // {}) | to_entries[] | [.key, .value] | @tsv' 2>/dev/null)"

[ -n "$done_list" ] || exit 0
jq -n --arg m "The person answered Approve; the approval line is written for:$done_list. Dispatch may start." \
  '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $m}}'
exit 0
