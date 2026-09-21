#!/usr/bin/env bash
# Prove the framework works without herdr, a network or real repos: static checks on every script and
# skill, then the scripts run against a throwaway fixture workspace built by make-fixtures.sh.
# Prints one PASS/FAIL line per check; exits 1 if any failed. Runs in a few seconds.
#   tests/check.sh            all checks
#   tests/check.sh --keep     keep the fixture folder and print its path
set -u  # no pipefail: grep -q closing a pipe early must not fail a check
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S="$ROOT/.claude/skills"
KEEP=0; [ "${1:-}" = --keep ] && KEEP=1
fail=0; pass() { echo "PASS $1"; }; bad() { echo "FAIL $1"; fail=1; }
check() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$name"; else bad "$name"; fi; }

# --- static ---------------------------------------------------------------------------------------
for f in "$S"/lib.sh "$S"/*/*.sh; do bash -n "$f" 2>/dev/null && pass "syntax $(basename "$(dirname "$f")")/$(basename "$f")" || bad "syntax $f"; done
check "settings.json is valid json" jq . "$ROOT/.claude/settings.json"
check "worker-settings.json is valid json" jq . "$S/dispatch/worker-settings.json"
for d in "$S"/*/; do [ -f "$d/SKILL.md" ] || continue; grep -q '^name: ' "$d/SKILL.md" && grep -q '^description: ' "$d/SKILL.md" && pass "skill $(basename "$d") has frontmatter" || bad "skill $(basename "$d") frontmatter"; done
if grep -rl '/Users/\|/home/[a-z]' "$ROOT/.claude" "$ROOT/templates" "$ROOT/CLAUDE.md" "$ROOT/README.md" >/dev/null 2>&1; then bad "no machine paths in framework files ($(grep -rl '/Users/\|/home/[a-z]' "$ROOT/.claude" "$ROOT/templates" "$ROOT/CLAUDE.md" "$ROOT/README.md" | tr '\n' ' '))"; else pass "no machine paths in framework files"; fi
if grep -rl $'\xe2\x80\x94' "$ROOT/.claude" "$ROOT/templates" "$ROOT/CLAUDE.md" "$ROOT/README.md" "$ROOT/docs" >/dev/null 2>&1; then bad "no em dashes in framework files"; else pass "no em dashes in framework files"; fi
grep -q '__SKILL_DIR__' "$S/dispatch/worker-settings.json" && pass "worker profile uses the skill-dir placeholder" || bad "worker profile placeholder"

# --- fixture --------------------------------------------------------------------------------------
FIX="$(mktemp -d)"; export WORKSPACE_ROOT="$FIX/ws"
"$ROOT/tests/make-fixtures.sh" "$FIX" >/dev/null 2>&1 && pass "fixture workspace built" || { bad "fixture workspace built"; exit 1; }
WS="$FIX/ws"; cd "$WS" || exit 1

# start.sh
"$S/start/start.sh" --init >/dev/null 2>&1 && [ -f "$WS/ROUTING.md" ] && pass "start --init creates instance files" || bad "start --init"
"$S/start/start.sh" --repos 2>/dev/null | grep -q '^alpha .*entry=yes' && pass "start --repos lists repos with entries" || bad "start --repos"
"$S/start/start.sh" --scaffold gamma --description "A test project" >/dev/null 2>&1 && [ -f "$WS/gamma/CLAUDE.md" ] && git -C "$WS/gamma" log --oneline | grep -q 'Initial' && pass "start --scaffold creates a first repo" || bad "start --scaffold"

# guard.sh: block, allow, pass-through
g() { printf '{"tool_input":{"command":"%s"}}' "$1" | "$S/dispatch/guard.sh"; }
g "git push origin main" >/dev/null 2>&1; [ $? = 2 ] && pass "guard blocks git push" || bad "guard blocks git push"
g "git checkout main" >/dev/null 2>&1; [ $? = 2 ] && pass "guard blocks checkout of a protected branch" || bad "guard protected checkout"
g "gh pr create --fill" >/dev/null 2>&1; [ $? = 2 ] && pass "guard blocks gh pr create" || bad "guard gh pr create"
g "cat > x.txt" >/dev/null 2>&1; [ $? = 2 ] && pass "guard blocks cat as a writer" || bad "guard cat writer"
g "cat .env" >/dev/null 2>&1; [ $? = 2 ] && pass "guard blocks reading .env through the shell" || bad "guard cat env file"
g "sed -n 1,5p config/.env.production" >/dev/null 2>&1; [ $? = 2 ] && pass "guard blocks env files in subfolders" || bad "guard env subfolder"
g "head -1 ~/.npmrc; cat .secrets/token" >/dev/null 2>&1; [ $? = 2 ] && pass "guard blocks .npmrc and .secrets" || bad "guard npmrc secrets"
g "cat server.key" >/dev/null 2>&1; [ $? = 2 ] && pass "guard blocks key files" || bad "guard key file"
out="$(g "cat .env.example" 2>/dev/null)"; printf '%s' "$out" | grep -q 'BLOCKED' && bad "guard env example" || pass "guard still allows .env.example"
out="$(g "npm run build -- --env production" 2>/dev/null)"; [ -z "$out" ] && pass "guard does not mistake --env flags for env files" || bad "guard env flag"
out="$(g "grep -rn environment src" 2>/dev/null)"; printf '%s' "$out" | grep -q 'BLOCKED' && bad "guard environment word" || pass "guard leaves the word environment alone"
g "ls -la src && git status" 2>/dev/null | grep -q '"permissionDecision":"allow"' && pass "guard allows read-only commands outright" || bad "guard read-only allow"
out="$(g "npm test" 2>/dev/null)"; [ -z "$out" ] && pass "guard passes other commands through" || bad "guard pass-through"
WORKSTREAM_ALLOW_MERGE=staging g "git merge --no-edit origin/staging" >/dev/null 2>&1; [ $? = 0 ] && pass "guard allows the catch-up merge only with the env set" || bad "guard catch-up merge"

# backend layer and worker state
[ "$(WORKER_BACKEND=tmux "$S/dispatch/backend.sh" name)" = tmux ] && [ "$(WORKER_BACKEND=herdr "$S/dispatch/backend.sh" name)" = herdr ] && pass "backend follows WORKER_BACKEND" || bad "backend name"
sf="$FIX/state-test"; WORKER_STATE_FILE="$sf" "$S/dispatch/state.sh" working; WORKER_STATE_FILE="$sf" "$S/dispatch/state.sh" idle
[ "$(cut -d' ' -f1 "$sf")" = idle ] && pass "state.sh records the worker state" || bad "state.sh"
printf '{"notification_type":"permission_prompt"}' | WORKER_STATE_FILE="$sf" "$S/dispatch/state.sh" from-notification; [ "$(cut -d' ' -f1 "$sf")" = blocked ] && pass "state.sh maps a permission prompt to blocked" || bad "state.sh notification"
if command -v tmux >/dev/null 2>&1; then
  export WORKER_BACKEND=tmux TMUX_SESSION="check-$$"
  o="$(. "$S/dispatch/backend.sh"; be_open "smoke/alpha" "$WS/alpha" "WORKER_STATE_FILE=$sf")"; id="${o%%	*}"
  [ -n "$id" ] && tmux has-session -t "$TMUX_SESSION" 2>/dev/null && pass "tmux backend opens a window" || bad "tmux open"
  st="$(. "$S/dispatch/backend.sh"; be_status smoke "$id" "$sf")"; [ "$st" = gone ] && pass "tmux backend reports a window without claude as gone" || bad "tmux status ($st)"
  (. "$S/dispatch/backend.sh"; be_prompt smoke "$id" "echo smoke-ok") ; sleep 1
  (. "$S/dispatch/backend.sh"; be_read smoke "$id" 20) | grep -q 'smoke-ok' && pass "tmux backend prompts and reads a window" || bad "tmux prompt/read"
  (. "$S/dispatch/backend.sh"; be_close "$id"); tmux kill-session -t "$TMUX_SESSION" 2>/dev/null; pass "tmux backend closes the window"
  unset WORKER_BACKEND TMUX_SESSION
else echo "SKIP tmux backend smoke (tmux not installed)"; fi

# a lookup plan on the fixture: dry-run start, link detection, learnings, metrics, finish
P="$WS/plans/q-check"; mkdir -p "$P/reports"
printf '# Lookup - check\n\nRepos: alpha\n\n## Question\n\nWhat does alpha export?\n' > "$P/TASK.md"
"$S/dispatch/start-worker.sh" --workspace "$WS" --plan "$P" --repo alpha --branch q-check --read-only --dry-run 2>/dev/null | grep -q '^dry-run: would start worker q-check-alpha' && pass "start-worker dry run (read-only)" || bad "start-worker dry run"
WORKER_BACKEND=tmux "$S/dispatch/start-worker.sh" --workspace "$WS" --plan "$P" --repo alpha --branch q-check --read-only --dry-run 2>/dev/null | grep -q '^dry-run: would start worker q-check-alpha' && pass "start-worker dry run under tmux" || bad "start-worker dry run tmux"
[ -f "$P/.dispatch/alpha.settings.json" ] && grep -q "$S/dispatch/guard.sh" "$P/.dispatch/alpha.settings.json" && pass "worker profile rendered with real hook paths" || bad "worker profile rendered"
printf '# Report - alpha\n\nRead at: main @ abc1234\n\n## Answer\n\nalpha exports name. The sibling repo beta consumes it; beta was not read.\n\n## Evidence\n\n- src/index.js:1\n\n## Not determined\n\n- beta not checked\n\n## Learnings verified\n\nNone\n\n## Learnings\n\n- Tests run with node --test, not jest.\n' > "$P/reports/alpha.md"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%Y-%m-%dT%H:%M:%S)" alpha q-check-alpha herdr wX wX:p1 "$WS/alpha" medium claude default main abc1234 >> "$P/.dispatch/workers.tsv"
"$S/dispatch/link-repos.sh" --plan "$P" --dry-run 2>/dev/null | grep -q 'would link alpha -> beta' && pass "link-repos finds the cross-repo mention" || bad "link-repos detection"
"$S/dispatch/finish-lookup.sh" --plan "$P" >/dev/null 2>&1; grep -q '^- Linked: beta' "$WS/REPOS.md" && grep -q 'q-check' "$WS/METRICS.md" && grep -q 'node --test' "$WS/learnings/alpha.md" && pass "finish-lookup: links, metrics row, learnings" || bad "finish-lookup"
"$S/dispatch/finish-lookup.sh" --plan "$P" 2>/dev/null | grep -q 'already written' && [ "$(grep -c '^- Linked: beta' "$WS/REPOS.md")" = 1 ] && pass "finish-lookup is idempotent" || bad "finish-lookup idempotent"

# a change branch on alpha: scope check and ship preflight
git -C "$WS/alpha" checkout -q -b ws-check 2>/dev/null; printf 'export const greet = () => "hi";\n' >> "$WS/alpha/src/index.js"; git -C "$WS/alpha" commit -qam "Add greet" 2>/dev/null; git -C "$WS/alpha" push -q origin ws-check 2>/dev/null
mkdir -p "$P/alpha"; printf '# alpha Task 1\n\n## Files to touch\n\n- `alpha/src/index.js`\n' > "$P/alpha/task-1-greet.md"
"$S/integrate/scope-check.sh" --checkout "$WS/alpha" --base origin/staging --tasks "$P/alpha" 2>/dev/null | grep -q 'unplanned: 0' && pass "scope-check sees only planned files" || bad "scope-check"
"$S/ship-workstream/preflight.sh" --checkout "$WS/alpha" --target staging --branch ws-check 2>/dev/null | grep -q '^PASS merge' && pass "ship preflight: clean merge, no secrets, no attribution" || bad "ship preflight"
git -C "$WS/alpha" commit -q --allow-empty -m "Generated with an AI assistant" 2>/dev/null; "$S/ship-workstream/preflight.sh" --checkout "$WS/alpha" --target staging --branch ws-check 2>/dev/null | grep -q '^FAIL attribution' && pass "ship preflight catches attribution" || bad "preflight attribution"
"$S/integrate/verify.sh" --checkout "$WS/alpha" --plan "$P" --repo alpha --command "npm test" 2>/dev/null | grep -q '^PASS alpha' && pass "verify.sh re-runs a test command" || bad "verify.sh"

# status and session start
"$S/status/status.sh" 2>/dev/null | grep -q 'q-check' && pass "status digest lists the plan" || bad "status digest"
"$S/status/on-start.sh" 2>/dev/null | grep -q 'Workspace state at session start' && pass "session-start digest runs" || bad "on-start"
"$S/wrap-workstream/metrics.sh" --note "check run" >/dev/null 2>&1 && grep -q 'check run' "$WS/METRICS.md" && pass "metrics change note" || bad "metrics note"

cd "$ROOT" || exit 1
if [ "$KEEP" = 1 ]; then echo "fixture kept at $WS"; else rm -rf "$FIX"; fi
[ "$fail" = 0 ] && echo "all checks passed" || echo "some checks failed"
exit $fail
