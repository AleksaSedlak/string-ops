#!/usr/bin/env bash
# The one check that needs the real thing: start a read-only worker on the fixture repo in whichever
# backend you have, wait for it, finish the lookup. Takes a few minutes and uses your Claude Code session.
#   tests/live.sh                 auto backend (herdr when installed, else tmux)
#   WORKER_BACKEND=tmux tests/live.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; S="$ROOT/.claude/skills"
. "$S/dispatch/backend.sh"; be_require || { echo "no worker backend; tests/check.sh covers everything else"; exit 1; }; echo "backend: $(be_name)"
FIX="$(mktemp -d)"; export WORKSPACE_ROOT="$FIX/ws"; WS="$FIX/ws"
"$ROOT/tests/make-fixtures.sh" "$FIX" >/dev/null
P="$WS/plans/q-live"; mkdir -p "$P/reports"
cat > "$P/TASK.md" <<EOF
# Lookup - live check

Repos: alpha

## Question

What does alpha export from src/index.js, and what does its test check? Cite file and line.

## Conventions

Read only: change no file in the repository, commit nothing, install nothing. Follow WORKER-RULES.md in this folder.

## Report

Write $P/reports/alpha.md with the answer, evidence, and what you could not determine.
EOF
echo "starting a worker (background window)..."
"$S/dispatch/start-worker.sh" --workspace "$WS" --plan "$P" --repo alpha --branch q-live --read-only || exit 1
echo "waiting for it to settle..."
"$S/dispatch/watch.sh" --plan "$P" --max-seconds 900
if [ -f "$P/reports/alpha.md" ]; then
  head -3 "$P/reports/alpha.md" | grep -q '^Read at: ' && echo "PASS report starts with the Read at line" || echo "FAIL report has no Read at line"
  "$S/dispatch/finish-lookup.sh" --plan "$P"
  echo "PASS live lookup finished; fixture at $WS (delete it when done)"
else
  echo "FAIL no report; read the worker: $S/dispatch/backend.sh read q-live-alpha <pane from $P/.dispatch/workers.tsv> 80"; exit 1
fi
