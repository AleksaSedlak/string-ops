#!/usr/bin/env bash
# Notice when a worker report mentions another repo the registry does not tie to the worker's repo, and
# record that tie in REPOS.md as a `Linked:` line on both entries. This is how contracts that no import
# or call makes visible (a JSON payload two repos agree on, a topic consumed by name) get into the
# registry without anyone editing it by hand.
#
#   link-repos.sh --plan <abs path to plans/<slug>> [--dry-run]
#
# For every reports/<repo>.md: find whole-word mentions of other registry repos (folder name and the
# GitHub remote's short name). A mention counts only when the
# mentioning repo's entry does not already name that repo anywhere (Consumes, Exposes, Consumed by,
# Linked). Each new tie is appended to both entries as
#   - Linked: <other repo> (<the report line that mentioned it, shortened>; noted <date> from <slug>)
# Re-runs are no-ops: a repo that is already named in the entry is never linked again. Nothing else in
# REPOS.md is touched. Prints one line per link added ("linked A -> B") and a final count.
set -uo pipefail
WS="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
R="$WS/REPOS.md"
PLAN=""; DRY=0
while [ $# -gt 0 ]; do case "$1" in --plan) PLAN="$2"; shift 2;; --dry-run) DRY=1; shift;; *) echo "unknown argument: $1" >&2; exit 2;; esac; done
[ -n "$PLAN" ] && [ -d "$PLAN/reports" ] || { echo "need --plan with a reports/ folder" >&2; exit 2; }
[ -f "$R" ] || { echo "no REPOS.md at $R" >&2; exit 2; }
slug="$(basename "$PLAN")"; today="$(date +%F)"

# name<TAB>alias, one line per alias
aliases="$(awk '
  /^## /{name=substr($0,4); print name "\t" name}
  /^- Path:.*Remote: `/{m=$0; sub(/.*Remote: `/,"",m); sub(/`.*/,"",m); sub(/.*\//,"",m); print name "\t" m}
' "$R" | sort -u)"
entry() { awk -v r="## $1" '$0==r{f=1;next} /^## /{f=0} f' "$R"; }
has_entry() { grep -qx "## $1" "$R"; }
entry_names() { awk -v n="$1" -F'\t' '$1==n{print $2}' <<< "$aliases"; }
is_linked() { # $1 entry repo, $2 other repo: does the entry already name the other repo?
  local e n; e="$(entry "$1")"
  while IFS= read -r n; do [ -n "$n" ] || continue; printf '%s\n' "$e" | grep -qwF -- "$n" && return 0; done <<< "$(entry_names "$2")"
  return 1
}
add_line() { # $1 entry repo, $2 line to append at the end of that entry
  local n; n="$(awk -v r="## $1" '$0==r{f=1;next} /^## /{f=0} f && NF {n=NR} END{print n+0}' "$R")"
  [ "$n" -gt 0 ] || return 1
  local tmp; tmp="$(mktemp)"; awk -v n="$n" -v line="$2" 'NR==n{print; print line; next} {print}' "$R" > "$tmp" && mv "$tmp" "$R"
}
shorten() { # one clause, at most 200 characters: cut at the last sentence or clause break when the line is longer
  local full t; full="$(printf '%s' "$1" | sed -E 's/^[-*] +//; s/\|/\//g' | tr -s ' ')"; t="$(printf '%s' "$full" | cut -c1-200)"
  [ "${#t}" -lt "${#full}" ] && t="$(printf '%s' "$t" | sed -E 's/[;.:,][^;.:,]*$//; s/ [^ ]*$//')"
  printf '%s' "$t" | sed -E 's/[;.:, ]+$//'
}

added=0
for rep in "$PLAN"/reports/*.md; do
  [ -f "$rep" ] || continue
  repo="$(basename "$rep" .md)"
  has_entry "$repo" || { echo "skip $repo: no registry entry"; continue; }
  seen=""
  while IFS=$'\t' read -r other alias; do
    [ -n "$other" ] && [ "$other" != "$repo" ] || continue
    case " $seen " in *" $other "*) continue;; esac
    line="$(grep -m1 -wF -- "$alias" "$rep" || true)"; [ -n "$line" ] || continue
    seen="$seen $other"
    reason="$(shorten "$line")"
    for pair in "$repo:$other" "$other:$repo"; do
      a="${pair%%:*}"; b="${pair##*:}"
      is_linked "$a" "$b" && continue
      l="- Linked: $b ($reason; noted $today from $slug)"
      if [ "$DRY" = 1 ]; then echo "would link $a -> $b: $reason"
      else add_line "$a" "$l" && echo "linked $a -> $b: $reason"; fi
      added=$((added+1))
    done
  done <<< "$aliases"
done
echo "links added: $added"
