#!/usr/bin/env bash
# Learnings lifecycle, driven by worker reports. Never touches a file git tracks.
#
#   new learning   report "## Learnings" bullet  -> learnings/<repo>.md (pending: the next worker verifies it)
#   verified true  report "## Learnings verified" "- <text> | still true"      -> removed from learnings/<repo>.md,
#                                                                                 appended to <repo>/CLAUDE.local.md
#   verified false report "## Learnings verified" "- <text> | no longer true"  -> removed from learnings/<repo>.md
#
# usage: learn.sh --plan <abs path to plans/<slug>>
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
PLAN=""
while [ $# -gt 0 ]; do case "$1" in --plan) PLAN="$2"; shift 2;; *) echo "unknown argument: $1" >&2; exit 2;; esac; done
[ -n "$PLAN" ] && [ -d "$PLAN/reports" ] || { echo "need --plan with a reports/ folder" >&2; exit 2; }
WS="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
slug="$(basename "$PLAN")"; today="$(date +%F)"; added=0; promoted=0; dropped=0
mkdir -p "$WS/learnings"

# remove one pending bullet (matched on its text, ignoring the date tag) from learnings/<repo>.md
drop_pending() { local file="$1" text="$2" tmp; tmp="$(mktemp)"; grep -vF -- "- $text (" "$file" > "$tmp" || true; mv "$tmp" "$file"; }

for rep in "$PLAN"/reports/*.md; do
  [ -f "$rep" ] || continue
  repo="$(basename "$rep" .md)"; out="$WS/learnings/$repo.md"

  # verdicts on pending learnings
  verdicts="$(awk '/^## Learnings verified/{f=1;next} /^## /{f=0} f && /^- /{print}' "$rep" | sed -E 's/^- +//' || true)"
  if [ -n "$verdicts" ] && [ -f "$out" ]; then
    while IFS= read -r v; do
      [ -n "$v" ] || continue
      text="$(printf '%s' "$v" | sed -E 's/[[:space:]]*\|.*$//')"
      verdict="$(printf '%s' "$v" | sed -nE 's/^.*\|[[:space:]]*(still true|no longer true).*$/\1/p')"
      [ -n "$verdict" ] || continue
      grep -qF -- "- $text (" "$out" || continue
      if [ "$verdict" = "still true" ]; then
        local_md="$WS/$repo/CLAUDE.local.md"
        if git -C "$WS/$repo" ls-files --error-unmatch CLAUDE.local.md >/dev/null 2>&1; then
          echo "refusing to write $repo/CLAUDE.local.md: git tracks it, learnings must never be pushed" >&2; continue
        fi
        [ -f "$local_md" ] || printf '# Local notes for %s\n\nVerified gotchas from workspace workers. Never committed (globally gitignored).\n\n## Verified learnings\n' "$repo" > "$local_md"
        grep -q '^## Verified learnings' "$local_md" || printf '\n## Verified learnings\n' >> "$local_md"
        if ! grep -qF -- "- $text" "$local_md"; then
          # the user's cap (2026-09-21): at most 15 verified bullets per repo, so the file stays a list of
          # instructions and never grows into an overview; the oldest bullet makes room
          n="$(awk '/^## Verified learnings/{f=1;next} /^## /{f=0} f && /^- /' "$local_md" | grep -c .)"
          if [ "$n" -ge "$LEARNINGS_CAP" ]; then
            oldest="$(awk '/^## Verified learnings/{f=1;next} /^## /{f=0} f && /^- /{print; exit}' "$local_md")"
            tmp="$(mktemp)"; awk -v o="$oldest" '!d && $0==o {d=1; next} {print}' "$local_md" > "$tmp" && mv "$tmp" "$local_md"
            echo "$repo: at the cap of $LEARNINGS_CAP, dropped the oldest verified learning: ${oldest#- }"
          fi
          printf -- '- %s (verified %s, %s)\n' "$text" "$today" "$slug" >> "$local_md"
        fi
        echo "$repo: promoted to CLAUDE.local.md: $text"; promoted=$((promoted+1))
      else
        echo "$repo: dropped as no longer true: $text"; dropped=$((dropped+1))
      fi
      drop_pending "$out" "$text"
    done <<< "$verdicts"
  fi

  # new learnings
  bullets="$(awk '/^## Learnings$/{f=1;next} /^## /{f=0} f && /^- /{print}' "$rep" | sed -E 's/^- +//' | grep -v -i -E '^(none|n/a)\.?$' || true)"
  [ -n "$bullets" ] || continue
  [ -f "$out" ] || printf '# Learnings - %s (pending verification)\n\nGotchas a worker reported about this repo. The next worker in this repo verifies each one while working and reports a verdict; the harvest step then removes it here and, if true, promotes it to the repo CLAUDE.local.md. Never committed.\n\n' "$repo" > "$out"
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    if grep -qF -- "- $b (" "$out"; then continue; fi
    if [ -f "$WS/$repo/CLAUDE.local.md" ] && grep -qF -- "- $b" "$WS/$repo/CLAUDE.local.md"; then continue; fi
    printf -- '- %s (%s, %s)\n' "$b" "$today" "$slug" >> "$out"
    echo "$repo: pending: $b"; added=$((added+1))
  done <<< "$bullets"
done
echo "learnings: $added new pending, $promoted promoted, $dropped dropped"
