#!/usr/bin/env bash
# Status line for every Claude Code window the framework opens: the coordinator (.claude/settings.json)
# and each worker (dispatch/worker-settings.json). Claude Code pipes session JSON on stdin; this prints
# one dim line: model, reasoning effort, context used. The three things to know before trusting a
# session's output, always visible, in herdr and tmux alike.
#   Fable 5.1 | effort high | context 12% used
# Effort is absent when the model does not take one; context is absent before the first response.
set -u
command -v jq >/dev/null 2>&1 || { printf 'statusline: jq missing'; exit 0; }
line="$(jq -r '
  [ (.model.display_name // .model.id // "model?"),
    (if .effort.level then "effort \(.effort.level)" else empty end),
    (if (.context_window.used_percentage // null) != null then "context \(.context_window.used_percentage | floor)% used" else empty end)
  ] | join(" | ")' 2>/dev/null)"
printf '\033[2m%s\033[0m' "${line:-model?}"
