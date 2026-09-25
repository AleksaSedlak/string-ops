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

# credential files are never read through the shell either: Claude Code's deny rules stop the Read tool,
# this stops cat, head, sed and friends. *.env.example stays readable; --env flags are not files.
if printf '%s' "$cmd" | sed -E 's/\.env\.example//g' | grep -Eiq '(^|[/[:space:]"=])([a-z0-9_.-]*\.env(\.[a-z0-9_-]+)?|\.npmrc|\.netrc|\.pypirc|[a-z0-9_.-]*\.(pem|key|p12|pfx|jks))([[:space:]"]|$)|(^|[/[:space:]])\.secrets(/|[[:space:]]|$)'; then
  block "reading a credential file; ask the user for the value instead"
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
if printf '%s' "$cmd" | grep -Eq '(^|[;&|]|\s)((npm|pnpm|yarn|bun)\s+(publish|version)|cargo\s+publish|gem\s+push|twine\s+upload|(poetry|uv|flit|hatch)\s+publish|mvn\s+deploy|gradle\s+publish|dotnet\s+nuget\s+push|mix\s+hex\.publish)\b'; then block "package publish or version bump"; fi
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
    if ! printf '%s' "$seg" | grep -Eq '^(cat|head|tail|less|grep|rg|ls|find|wc|echo|printf|sort|uniq|tr|cut|jq|diff|stat|file|basename|dirname|pwd|which|sed -n|git (show|log|diff|status|branch|ls-files|ls-tree|rev-parse|cat-file|rev-list|describe|remote -v|blame|shortlog)|(node|python3?|go|cargo|rustc|ruby|java|dotnet|php|mvn|gradle) (--version|version|-v|-V)|(npm|pnpm|yarn|pip3?|cargo|go|bundle|composer) (ls|list|view|tree|show|info|--version))( |$)'; then ok=0; break; fi
    # a read-only utility with an argument that writes or deletes is not read-only: find -delete/-exec,
    # sort -o, sed -i or a w command, git branch -D/-m (the block list above catches the other git forms)
    if printf '%s' "$seg" | grep -Eq '^find .*(-delete|-exec|-execdir|-ok|-okdir|-fprint|-fprint0|-fprintf|-fls)( |$)|^sort .*(-o( |$)|--output)|^sed -n .*(-i|--in-place|(^|[0-9$/,;{[:space:]"'"'"'])w[[:space:]])|^git branch .*(-[dDmM]|--delete|--move)( |$)'; then ok=0; break; fi
  done < <(printf '%s\n' "$cmd" | tr '\n' ';' | sed -E 's/&&|\|\||\|/;/g' | tr ';' '\n'; echo)
  if [ "$ok" = 1 ]; then
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"read-only command allowed by the workstream guard"}}'
    exit 0
  fi
fi
exit 0
