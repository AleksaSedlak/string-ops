#!/usr/bin/env bash
# One digest of every plan folder: what it is, where it stands, which workers are alive, what is waiting.
# Read-only. usage: status.sh [--all]   (without --all, plans whose last block is "Shipped" or that are
# lookups with all reports in are listed in one line each under "finished")
set -uo pipefail
WS="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
PLANS="$WS/plans"; ALL=0; [ "${1:-}" = --all ] && ALL=1
[ -d "$PLANS" ] || { echo "no plans folder"; exit 0; }
agents="$(herdr agent list 2>/dev/null | jq -r '.result.agents[]? | select(.name != null) | "\(.name)\t\(.agent_status)"' 2>/dev/null)"
finished=()
for P in "$PLANS"/*/; do
  P="${P%/}"; slug="$(basename "$P")"
  if [ -f "$P/README.md" ]; then kind=plan
  elif [ -f "$P/TASK.md" ] && head -1 "$P/TASK.md" | grep -q '^# Lookup'; then kind=lookup
  elif [ -f "$P/TASK.md" ]; then kind=task
  else kind=unknown; fi
  status=""; stage=""
  if [ "$kind" = plan ]; then
    status="$(grep -m1 -E '^> \*\*Status:\*\*' "$P/README.md" | sed -E 's/^> \*\*Status:\*\* //; s/\.$//' | cut -c1-60)"
    stage="landed"; grep -q '^## Dispatch' "$P/README.md" && stage="dispatched"
    grep -q '^## Integration' "$P/README.md" && stage="integrated"
    grep -q '^## Shipped' "$P/README.md" && stage="shipped"
  fi
  # buckets and reports
  if [ "$kind" = plan ]; then repos="$(find "$P" -mindepth 1 -maxdepth 1 -type d ! -name reports ! -name .dispatch ! -name '.*' -exec basename {} \; | sort | tr '\n' ' ')"
  else repos="$(sed -nE 's/^Repos?: (.*)$/\1/p' "$P/TASK.md" 2>/dev/null | head -1 | tr ',' ' ')"; fi
  nrep=0; ntot=0; missing=""
  for r in $repos; do ntot=$((ntot+1)); if [ -f "$P/reports/$r.md" ]; then nrep=$((nrep+1)); else missing="$missing $r"; fi; done
  # workers
  workers=""
  if [ -f "$P/.dispatch/workers.tsv" ]; then
    while IFS=$'\t' read -r _ repo name runner _ _ _; do
      st="$(printf '%s\n' "$agents" | awk -F'\t' -v n="$name" '$1==n {print $2}')"
      [ -n "$st" ] || st="gone"
      workers="$workers $repo=$st"
    done < "$P/.dispatch/workers.tsv"
  fi
  notes=0; [ -f "$P/NOTES.md" ] && notes="$(grep -c '^## ' "$P/NOTES.md")"
  inbox=0; [ -d "$P/.dispatch/inbox" ] && inbox="$(find "$P/.dispatch/inbox" -maxdepth 2 -name '*.md' -not -path '*/handled/*' | wc -l | tr -d ' ')"
  done_all=0; [ "$ntot" -gt 0 ] && [ "$nrep" = "$ntot" ] && done_all=1
  if [ "$ALL" = 0 ] && { [ "$stage" = shipped ] || { [ "$kind" != plan ] && [ "$done_all" = 1 ]; }; }; then
    finished+=("$slug ($kind, reports $nrep/$ntot)"); continue
  fi
  echo "## $slug ($kind)"
  [ -n "$status" ] && echo "  status: $status | stage: $stage"
  echo "  repos: ${repos:-none}"
  echo "  reports: $nrep/$ntot${missing:+ (missing:$missing)}"
  [ -n "$workers" ] && echo "  workers:$workers"
  [ "$notes" -gt 0 ] && echo "  NOTES entries: $notes (unresolved until the user says otherwise)"
  [ "$inbox" -gt 0 ] && echo "  inbox pending: $inbox"
  if [ "$kind" = plan ]; then
    prs="$(sed -n '/^## Shipped/,$p' "$P/README.md" | grep -oE 'https://github.com/[^ )]+' | tr '\n' ' ')"
    [ -n "$prs" ] && echo "  PRs: $prs"
  fi
done
if [ ${#finished[@]} -gt 0 ]; then echo "## finished (use --all to expand)"; printf '  %s\n' "${finished[@]}"; fi
echo "## worktrees"; ls -d "$WS"/.worktrees/*/* 2>/dev/null | sed "s#$WS/#  #" || true
echo "## live herdr agents"; printf '%s\n' "$agents" | grep . | sed 's/^/  /'; [ -n "$agents" ] || echo "  none"
