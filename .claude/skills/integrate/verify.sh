#!/usr/bin/env bash
# Re-run a worker's verification command in its checkout and keep the output out of the coordinator's
# context: full log to <plan>/.dispatch/verify-<repo>.log, only the verdict and the last lines printed.
#
# usage: verify.sh --checkout <abs path> --plan <abs plan> --repo <repo> --command "<exactly what the report says it ran>"
#
# Refuses commands that could push, publish or deploy. Runs with a 20 minute cap (portable watchdog, no coreutils needed).
set -uo pipefail
CO=""; PLAN=""; REPO=""; CMD=""
while [ $# -gt 0 ]; do case "$1" in --checkout) CO="$2"; shift 2;; --plan) PLAN="$2"; shift 2;; --repo) REPO="$2"; shift 2;; --command) CMD="$2"; shift 2;; *) echo "unknown argument: $1" >&2; exit 2;; esac; done
[ -n "$CO" ] && [ -n "$PLAN" ] && [ -n "$REPO" ] && [ -n "$CMD" ] || { echo "need --checkout, --plan, --repo, --command" >&2; exit 2; }
if printf '%s' "$CMD" | grep -qE 'git (push|merge|rebase|tag)|gh pr|gcloud|kubectl|vercel|npm publish|npm version|rm -rf'; then echo "refused: verification command looks mutating: $CMD" >&2; exit 2; fi
mkdir -p "$PLAN/.dispatch"; LOG="$PLAN/.dispatch/verify-$REPO.log"
{ echo "# $(date +%Y-%m-%dT%H:%M:%S) in $CO"; echo "# $CMD"; } > "$LOG"
( cd "$CO" && bash -lc "$CMD" ) >> "$LOG" 2>&1 & pid=$!
( sleep 1200; kill "$pid" 2>/dev/null && echo "# killed after 20 minutes" >> "$LOG" ) & wd=$!
wait "$pid"; rc=$?; kill "$wd" 2>/dev/null; wait "$wd" 2>/dev/null
if [ $rc -eq 0 ]; then echo "PASS $REPO: '$CMD' exited 0"; else echo "FAIL $REPO: '$CMD' exited $rc"; fi
echo "log: $LOG"; echo "--- last lines"; tail -n 15 "$LOG" | cut -c1-200
exit $rc
