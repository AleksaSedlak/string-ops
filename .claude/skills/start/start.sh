#!/usr/bin/env bash
# The mechanical half of /start. Read-only apart from creating the instance files it names.
#
#   start.sh --check     which required tools are present, with versions; exit 1 if one is missing
#   start.sh --init      create the instance files that do not exist yet (REPOS.md, ROUTING.md,
#                        workflow.conf, METRICS.md, plans/, learnings/), never overwriting
#   start.sh --repos     list top-level folders that are git repositories, marking which have a
#                        REPOS.md entry and which have a CLAUDE.md
#   start.sh --scaffold <name> [--description "<one line>"]
#                        create a first repository for a project that starts from nothing: git init,
#                        README.md, CLAUDE.md from the template, one commit on main
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
WS="$(ws_root)"; T="$WS/templates"
mode=""; NAME=""; DESC=""
while [ $# -gt 0 ]; do case "$1" in
  --check|--init|--repos) mode="${1#--}"; shift;;
  --scaffold) mode=scaffold; NAME="$2"; shift 2;;
  --description) DESC="$2"; shift 2;;
  *) echo "unknown argument: $1" >&2; exit 2;; esac; done

case "$mode" in
check)
  missing=0
  for t in git jq gh claude; do
    if command -v "$t" >/dev/null 2>&1; then
      v="$("$t" --version 2>/dev/null | head -1 | cut -c1-60)"; printf 'ok       %-6s %s\n' "$t" "$v"
    else printf 'MISSING  %-6s ' "$t"; case "$t" in
        herdr) echo "workers run in herdr terminals: https://github.com/herdr-dev/herdr";;
        gh)    echo "GitHub CLI, used for pull requests: https://cli.github.com";;
        jq)    echo "JSON on the command line: https://jqlang.github.io/jq";;
        claude) echo "Claude Code: https://code.claude.com";;
        *) echo "";; esac; missing=1; fi
  done
  if command -v herdr >/dev/null 2>&1; then printf 'ok       %-6s %s\n' herdr "$(herdr --version 2>/dev/null | head -1)"
  elif command -v tmux >/dev/null 2>&1; then printf 'ok       %-6s %s (worker windows open here)\n' tmux "$(tmux -V 2>/dev/null)"
  else echo "MISSING  herdr or tmux: worker windows need one of them. tmux comes from your package manager; herdr: https://github.com/herdr-dev/herdr"; missing=1; fi
  if command -v gh >/dev/null 2>&1; then gh auth status >/dev/null 2>&1 && echo "ok       gh is logged in" || { echo "note     gh is not logged in; run: gh auth login (needed only to open pull requests)"; }; fi
  exit $missing;;
init)
  for f in REPOS.md ROUTING.md workflow.conf; do
    if [ -f "$WS/$f" ]; then echo "kept     $f"; else cp "$T/$f" "$WS/$f" && echo "created  $f"; fi
  done
  mkdir -p "$WS/plans" "$WS/learnings"; echo "ok       plans/ learnings/"
  [ -f "$WS/METRICS.md" ] && echo "kept     METRICS.md" || { "$WS/.claude/skills/wrap-workstream/metrics.sh" --show >/dev/null && echo "created  METRICS.md"; }
  date +%F > "$WS/.claude/registry-checked"
  exit 0;;
repos)
  n=0
  for d in "$WS"/*/; do
    d="${d%/}"; r="$(basename "$d")"
    [ -d "$d/.git" ] || continue
    n=$((n+1))
    entry=no; [ -f "$WS/REPOS.md" ] && grep -qx "## $r" "$WS/REPOS.md" && entry=yes
    cl=no; { [ -f "$d/CLAUDE.md" ] || [ -f "$d/.claude/CLAUDE.md" ]; } && cl=yes
    br="$(git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
    printf '%-40s branch=%-16s entry=%-3s CLAUDE.md=%s\n' "$r" "$br" "$entry" "$cl"
  done
  [ "$n" -gt 0 ] || echo "no repositories in $WS (a repository is a top-level folder with a .git inside)"
  exit 0;;
scaffold)
  [ -n "$NAME" ] || { echo "need a name" >&2; exit 2; }
  case "$NAME" in *[!A-Za-z0-9._-]*|.*) echo "name must be letters, digits, dots, dashes or underscores" >&2; exit 2;; esac
  d="$WS/$NAME"; [ -e "$d" ] && { echo "$d already exists" >&2; exit 1; }
  mkdir -p "$d" && git init -q -b main "$d"
  printf '# %s\n\n%s\n' "$NAME" "${DESC:-Describe this project in one paragraph.}" > "$d/README.md"
  sed -e "s/<name>/$NAME/" -e "s/<one sentence: what this repository is for>/${DESC:-What this repository is for, in one sentence.}/" "$T/child-CLAUDE.md" > "$d/CLAUDE.md"
  printf '# dependencies and build output, any stack\nnode_modules/\n.venv/\nvenv/\n__pycache__/\nvendor/\ntarget/\nbuild/\ndist/\n.gradle/\nbin/\nobj/\n# secrets\n.env\n.env.*\n!.env.example\n# editors and OS\n.DS_Store\n.idea/\n.vscode/\n' > "$d/.gitignore"
  git -C "$d" add -A && git -C "$d" commit -q -m "Initial project skeleton" && echo "created  $NAME on main ($(git -C "$d" rev-parse --short HEAD))"
  echo "next     fill the commands in $NAME/CLAUDE.md once the stack exists; /add-repo registers it"
  exit 0;;
*) echo "usage: start.sh --check | --init | --repos | --scaffold <name> [--description <text>]" >&2; exit 2;;
esac
