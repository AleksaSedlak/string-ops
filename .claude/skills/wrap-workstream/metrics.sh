#!/usr/bin/env bash
# Workspace metrics: one row per workstream, plus dated notes for every change to the flow itself.
#
#   metrics.sh --plan <abs path to plans/<slug>>     append the workstream's row (run by wrap before deleting)
#   metrics.sh --note "<what changed in the flow>"    append a dated change note
#   metrics.sh --show                                 print the file
#
# Everything comes from the plan folder and, when gh can see the PRs, from GitHub. Read-only apart from
# appending to METRICS.md at the workspace root.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
WS="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
M="$WS/METRICS.md"
init() { [ -f "$M" ] || cat > "$M" <<'EOF'
# Metrics

One row per workstream, written by wrap before the plan folder is deleted, and one dated note per change to the flow (skills, scripts, rules). Read the two together: a number only means something next to what changed before it.

## Workstreams

| date | workstream | kind | repos | workers | harness/model | effort | dispatch to last report | relaunches | blocked | review gaps | verify | unplanned files | PRs | merged | closed | review rounds |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|

## Changes to the flow

| date | change |
|---|---|
EOF
}
mode=""; PLAN=""; NOTE=""
while [ $# -gt 0 ]; do case "$1" in --plan) mode=plan; PLAN="$2"; shift 2;; --note) mode=note; NOTE="$2"; shift 2;; --show) mode=show; shift;; *) echo "unknown argument: $1" >&2; exit 2;; esac; done
init
case "$mode" in
  show) cat "$M"; exit 0;;
  note) [ -n "$NOTE" ] || { echo "empty note" >&2; exit 2; }; printf '| %s | %s |\n' "$(date +%F)" "$(printf '%s' "$NOTE" | tr '|' '/' | tr -s ' ')" >> "$M"; echo "noted"; exit 0;;
  plan) ;;
  *) echo "usage: metrics.sh --plan <dir> | --note <text> | --show" >&2; exit 2;;
esac

[ -d "$PLAN" ] || { echo "no plan folder $PLAN" >&2; exit 2; }
slug="$(basename "$PLAN")"
if [ -f "$PLAN/README.md" ]; then kind=plan; elif [ -f "$PLAN/TASK.md" ] && head -1 "$PLAN/TASK.md" | grep -q '^# Lookup'; then kind=lookup; else kind=task; fi
tsv="$PLAN/.dispatch/workers.tsv"
repos="$(ls "$PLAN/reports" 2>/dev/null | sed 's/\.md$//' | tr '\n' ' ' | sed 's/ $//')"
workers=0; relaunches=0; hm="-"; effort="-"; first=""; blocked=0
if [ -f "$tsv" ]; then
  workers="$(cut -f2 "$tsv" | sort -u | grep -c .)"
  rows="$(grep -c . "$tsv")"; relaunches=$((rows-workers)); [ $relaunches -lt 0 ] && relaunches=0
  first="$(head -1 "$tsv" | cut -f1)"
  effort="$(cut -f8 "$tsv" | grep . | sort -u | tr '\n' '/' | sed 's#/$##')"; [ -n "$effort" ] || effort="-"
  hm="$(awk -F'\t' '{h=($9==""?"claude":$9); m=($10==""?"default":$10); print h "/" m}' "$tsv" | sort -u | tr '\n' ' ' | sed 's/ $//')"
fi
dur="-"
if [ -n "$first" ] && [ -d "$PLAN/reports" ] && [ -n "$repos" ]; then
  last="$(ls -t "$PLAN"/reports/*.md 2>/dev/null | head -1)"
  s="$(stamp_epoch "$first")"; e="$(file_mtime "$last")"
  [ "$s" -gt 0 ] && [ "$e" -ge "$s" ] && dur="$(( (e-s)/60 )) min"
fi
gaps="-"; verify="-"; unplanned="-"; prs=0; merged="-"; closed="-"; rounds="-"
if [ -f "$PLAN/README.md" ]; then
  blocked="$(sed -n '/^## Dispatch/,/^## Integration/p' "$PLAN/README.md" | grep -ci 'blocked')"
  integ="$(awk '/^## Integration/{f=1} f' "$PLAN/README.md")"
  if [ -n "$integ" ]; then
    gaps="$(printf '%s\n' "$integ" | awk '/^Review gaps/{f=1;next} /^[A-Z][a-z]/{f=0} f && /^- /' | grep -vic 'none$')"
    verify="$(printf '%s\n' "$integ" | grep -oE 'Verification re-run: .*' | head -1 | sed 's/Verification re-run: //' | grep -oE 'PASS|FAIL|not requested' | sort | uniq -c | awk '{printf "%s %s ", $1, $2}' | sed 's/ $//')"; [ -n "$verify" ] || verify="-"
    unplanned="$(printf '%s\n' "$integ" | grep -oE 'Scope: .*' | head -1 | grep -oE '[0-9]+ unplanned' | awk '{s+=$1} END {print s+0}')"
  fi
fi
# the shipped block lives in README.md for a planned workstream and in TASK.md for a no-plan task
shipfile=""; [ "$kind" = plan ] && shipfile="$PLAN/README.md"; [ "$kind" = task ] && shipfile="$PLAN/TASK.md"
if [ -n "$shipfile" ]; then
  urls="$(sed -n '/^## Shipped/,$p' "$shipfile" | grep -oE 'https://github.com/[^ )]+/pull/[0-9]+' | sort -u)"
  prs="$(printf '%s\n' "$urls" | grep -c .)"
  if [ "$prs" -gt 0 ] && command -v gh >/dev/null; then
    m=0; c=0; r=0
    while IFS= read -r u; do
      [ -n "$u" ] || continue
      j="$(gh pr view "$u" --json state,reviews 2>/dev/null)" || continue
      st="$(printf '%s' "$j" | jq -r '.state')"; [ "$st" = MERGED ] && m=$((m+1)); [ "$st" = CLOSED ] && c=$((c+1))
      r=$((r + $(printf '%s' "$j" | jq '[.reviews[]? | select(.state=="CHANGES_REQUESTED")] | length')))
    done <<< "$urls"
    merged=$m; closed=$c; rounds=$r
  fi
fi
row="$(printf '| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |' \
  "$(date +%F)" "$slug" "$kind" "${repos:--}" "$workers" "$hm" "$effort" "$dur" "$relaunches" "$blocked" "$gaps" "$verify" "$unplanned" "$prs" "$merged" "$closed" "$rounds")"
# insert the row at the end of the workstreams table, which sits above the change notes
tmp="$(mktemp)"; awk -v row="$row" '
  /^## Changes to the flow/ && !done { for (i=n; i>0; i--) if (buf[i] ~ /^\|/) { last=i; break }
    for (i=1; i<=n; i++) { print buf[i]; if (i==last) print row }; done=1; n=0 }
  !done { buf[++n]=$0; next } { print }
  END { if (!done) { for (i=1; i<=n; i++) print buf[i]; print row } }' "$M" > "$tmp" && mv "$tmp" "$M"
echo "$row"
