#!/usr/bin/env bash
# PreToolUse hook for dispatched workers. Blocks commands that push, publish, merge, tag, open PRs,
# touch the protected branches, or reach cloud tooling, whatever form they are spelled in.
# Exit 2 = block with the message on stderr. Exit 0 = allow.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
input="$(cat)"
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)"
[ -n "$cmd" ] || exit 0

block() { echo "BLOCKED by the workstream guard: $1. Workers never do this; write it in your report instead." >&2; exit 2; }

# cat used as a writer (heredoc or redirection) stalls on the user's ask rule; say what to use instead
if printf '%s' "$cmd" | grep -Eq '(^|[;&|]|\s)cat(\s[^;&|]*)?(>|<<)'; then
  echo "BLOCKED by the workstream guard: cat used to write a file. Use the Write or Edit tool for files; use the Read tool, head or sed -n to read." >&2; exit 2
fi

# git subcommands, tolerant of `git -C path`, `git --no-pager`, `command git`, chained commands
if printf '%s' "$cmd" | grep -Eq '(^|[;&|]|\s)git(\s+(-C\s+\S+|--no-pager|-c\s+\S+))*\s+push\b'; then block "git push"; fi
if printf '%s' "$cmd" | grep -Eq '(^|[;&|]|\s)git(\s+(-C\s+\S+|--no-pager|-c\s+\S+))*\s+(merge|rebase|tag|cherry-pick)(\s|$)'; then
  # a catch-up worker may merge the PR target into its own branch, nothing else
  if [ -n "${WORKSTREAM_ALLOW_MERGE:-}" ] && printf '%s' "$cmd" | grep -Eq "(^|[;&|]|\\s)git(\\s+(-C\\s+\\S+|--no-pager|-c\\s+\\S+))*\\s+merge(\\s+(--no-edit|--no-ff|-m\\s+\"[^\"]*\"|-m\\s+'[^']*'))*\\s+origin/${WORKSTREAM_ALLOW_MERGE}(\\s|$)" \
     && ! printf '%s' "$cmd" | grep -Eq '(^|[;&|]|\s)git(\s+(-C\s+\S+|--no-pager|-c\s+\S+))*\s+(rebase|tag|cherry-pick)(\s|$)'; then :
  else block "git merge/rebase/tag/cherry-pick"; fi
fi
if printf '%s' "$cmd" | grep -Eq '(^|[;&|]|\s)git(\s+(-C\s+\S+|--no-pager|-c\s+\S+))*\s+(checkout|switch)\s+(\S+\s+)*('"$(protected_alt)"')(\s|$)'; then block "checking out a protected branch"; fi
if printf '%s' "$cmd" | grep -Eq '(^|[;&|]|\s)git(\s+(-C\s+\S+|--no-pager|-c\s+\S+))*\s+(branch\s+(-D|-d|--delete)|reset\s+--hard|worktree\s+(add|remove|prune)|remote\s+(add|set-url|remove))\b'; then block "branch deletion, hard reset, worktree or remote changes"; fi
if printf '%s' "$cmd" | grep -Eq '(^|[;&|]|\s)gh\s+(pr\s+(create|merge|close|edit)|release|repo\s+(delete|edit))\b'; then block "gh pr/release/repo mutation"; fi
if printf '%s' "$cmd" | grep -Eq '(^|[;&|]|\s)(npm|pnpm|yarn)\s+(publish|version)\b'; then block "package publish or version bump"; fi
if printf '%s' "$cmd" | grep -Eq '(^|[;&|]|\s)(gcloud|kubectl|helm|terraform|vercel|firebase|eas)\b'; then block "cloud or deploy tooling"; fi
# Read-only commands are allowed outright, so a user-level ask rule (for example on cat) cannot stall
# the worker. Every segment must start with a read-only utility, there must be no redirection, and no
# path may look like a credential. Anything else falls through to the normal permission checks.
if ! printf '%s' "$cmd" | grep -Eq '[<>]|\$\(|`' \
   && ! printf '%s' "$cmd" | grep -Eiq '(^|[^a-z])env([^a-z]|$)|\.npmrc|\.secrets|\.pem\b|\.key\b|credential|token|password' ; then
  ok=1
  while IFS= read -r seg; do
    seg="$(printf '%s' "$seg" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/^([A-Za-z_][A-Za-z0-9_]*=[^ ]*( +|$))*//')"
    [ -z "$seg" ] && continue
    if ! printf '%s' "$seg" | grep -Eq '^(cat|head|tail|less|grep|rg|ls|find|wc|echo|printf|sort|uniq|tr|cut|jq|diff|stat|file|basename|dirname|pwd|which|sed -n|git (show|log|diff|status|branch|ls-files|ls-tree|rev-parse|cat-file|rev-list|describe|remote -v|blame|shortlog)|node --version|npm (ls|list|view|--version))( |$)'; then ok=0; break; fi
  done < <(printf '%s\n' "$cmd" | tr '\n' ';' | sed -E 's/&&|\|\||\|/;/g' | tr ';' '\n'; echo)
  if [ "$ok" = 1 ]; then
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"read-only command allowed by the workstream guard"}}'
    exit 0
  fi
fi
exit 0
