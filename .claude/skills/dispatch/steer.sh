#!/usr/bin/env bash
# Send an instruction to a worker through its inbox, then ring a one-line doorbell in its window.
#
# usage: steer.sh --plan <abs path to plans/<slug>> --repo <repo> --message "<text>"
#
# The message lands in <plan>/.dispatch/inbox/<repo>/NNN.md; the window only gets "check your inbox".
# Ringing twice is harmless: the worker reads whatever is there and moves it to handled/.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/backend.sh"
PLAN=""; REPO=""; MSG=""
while [ $# -gt 0 ]; do case "$1" in --plan) PLAN="$2"; shift 2;; --repo) REPO="$2"; shift 2;; --message) MSG="$2"; shift 2;; *) echo "unknown argument: $1" >&2; exit 2;; esac; done
[ -n "$PLAN" ] && [ -n "$REPO" ] && [ -n "$MSG" ] || { echo "need --plan, --repo, --message" >&2; exit 2; }
[ -f "$PLAN/.dispatch/workers.tsv" ] || { echo "no workers recorded in $PLAN" >&2; exit 1; }
row="$(awk -F'\t' -v r="$REPO" '$2==r {n=$3 "\t" $6} END {print n}' "$PLAN/.dispatch/workers.tsv")"
name="${row%%	*}"; pane="${row##*	}"
[ -n "$name" ] || { echo "no worker for $REPO in $PLAN" >&2; exit 1; }
st="$(be_status "$name" "$pane" "$PLAN/.dispatch/state/$REPO")"
[ "$st" != gone ] || { echo "worker $name is gone; relaunch it instead" >&2; exit 1; }

INBOX="$PLAN/.dispatch/inbox/$REPO"; mkdir -p "$INBOX/handled"
n="$( { ls "$INBOX" "$INBOX/handled" 2>/dev/null | grep -E '^[0-9]{3}\.md$' || true; } | sort | tail -1 | sed 's/\.md//')"
next="$(printf '%03d' $(( ${n:-0} + 1 )))"
printf '# Message %s (%s)\n\n%s\n' "$next" "$(date +%Y-%m-%dT%H:%M:%S)" "$MSG" > "$INBOX/$next.md"

be_prompt "$name" "$pane" "Check your inbox: $INBOX. Read every file there in name order, act on each, then move it to $INBOX/handled/."
echo "queued $INBOX/$next.md and rang $name"
