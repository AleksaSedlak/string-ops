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
# settings.local.json is instance data (gitignored) and may hold this machine's paths
paths_hit="$(grep -rl --exclude=settings.local.json '/Users/\|/home/[a-z]' "$ROOT/.claude" "$ROOT/templates" "$ROOT/CLAUDE.md" "$ROOT/README.md" 2>/dev/null | tr '\n' ' ')"
[ -z "$paths_hit" ] && pass "no machine paths in framework files" || bad "no machine paths in framework files ($paths_hit)"
if grep -rl $'\xe2\x80\x94' "$ROOT/.claude" "$ROOT/templates" "$ROOT/CLAUDE.md" "$ROOT/README.md" "$ROOT/docs" >/dev/null 2>&1; then bad "no em dashes in framework files"; else pass "no em dashes in framework files"; fi
grep -q '__SKILL_DIR__' "$S/dispatch/worker-settings.json" && pass "worker profile uses the skill-dir placeholder" || bad "worker profile placeholder"
check "statusline.sh is executable" test -x "$S/statusline.sh"
[ "$(printf '{"model":{"display_name":"Fable 5.1"},"effort":{"level":"high"},"context_window":{"used_percentage":12.7}}' | "$S/statusline.sh" | sed 's/\x1b\[[0-9;]*m//g')" = "Fable 5.1 | effort high | context 12% used" ] && pass "statusline shows model, effort and context" || bad "statusline output"
[ "$(printf '{"model":{"display_name":"Fable 5.1"},"context_window":{"used_percentage":null}}' | "$S/statusline.sh" | sed 's/\x1b\[[0-9;]*m//g')" = "Fable 5.1" ] && pass "statusline copes with missing effort and context" || bad "statusline missing fields"
jq -e '.statusLine.command | test("statusline.sh")' "$ROOT/.claude/settings.json" >/dev/null 2>&1 && pass "coordinator settings carry the status line" || bad "coordinator statusLine"
jq -e '.statusLine.command | test("statusline.sh")' "$S/dispatch/worker-settings.json" >/dev/null 2>&1 && pass "worker profile carries the status line" || bad "worker statusLine"

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
for c in 'find . -name "*.log" -delete' 'find src -name x -exec rm {} \;' 'sort -o package.json package.json' 'sed -n -i s/a/b/ file' "sed -n '1w out.txt' file" 'git branch -D main'; do
  out="$(printf '{"tool_input":{"command":%s}}' "$(printf '%s' "$c" | jq -Rs .)" | "$S/dispatch/guard.sh" 2>/dev/null)"
  printf '%s' "$out" | grep -q '"allow"' && bad "guard waved through a writer: $c" || pass "guard does not pre-approve: $c"
done
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
"$S/dispatch/start-worker.sh" --workspace "$WS" --plan "$P" --repo alpha --branch q-check --read-only --dry-run 2>/dev/null | grep -q 'model default, effort medium' && pass "start-worker takes model and effort for lookups from the defaults" || bad "start-worker lookup defaults"
MODEL_LOOKUP=sonnet EFFORT_LOOKUP=low "$S/dispatch/start-worker.sh" --workspace "$WS" --plan "$P" --repo alpha --branch q-check --read-only --dry-run 2>/dev/null | grep -q 'model sonnet, effort low' && pass "start-worker takes MODEL_LOOKUP and EFFORT_LOOKUP from the config" || bad "start-worker config model/effort"
"$S/dispatch/start-worker.sh" --workspace "$WS" --plan "$P" --repo alpha --branch q-check --read-only --dry-run --model opus 2>/dev/null | grep -q 'model opus, effort medium' && pass "start-worker --model overrides the config" || bad "start-worker --model override"
"$S/dispatch/start-worker.sh" --workspace "$WS" --plan "$P" --repo alpha --branch q-check --read-only --dry-run 2>/dev/null | grep -q 'via headless' && pass "read-only workers run headless by default" || bad "headless default"
LOOKUP_BACKEND=window WORKER_BACKEND=tmux "$S/dispatch/start-worker.sh" --workspace "$WS" --plan "$P" --repo alpha --branch q-check --read-only --dry-run 2>/dev/null | grep -q 'via tmux' && pass "LOOKUP_BACKEND=window uses the window backend" || bad "LOOKUP_BACKEND window"
WORKER_BACKEND=tmux "$S/dispatch/start-worker.sh" --workspace "$WS" --plan "$P" --repo alpha --branch q-check --read-only --window --dry-run 2>/dev/null | grep -q 'via tmux' && pass "--window forces one lookup into a window" || bad "--window"
"$S/dispatch/start-worker.sh" --workspace "$WS" --plan "$P" --repo alpha --branch q-check --review --add-dir "$WS/plans" --dry-run 2>/dev/null | grep -q -- "--add-dir $WS/plans" && pass "--add-dir gives a worker an extra folder" || bad "--add-dir"
"$S/dispatch/start-worker.sh" --workspace "$WS" --plan "$P" --repo alpha --branch q-check --read-only --dry-run 2>/dev/null | grep -q 'permissions auto' && pass "workers start in auto permission mode by default" || bad "permission mode default"
WORKER_PERMISSION_MODE=acceptEdits "$S/dispatch/start-worker.sh" --workspace "$WS" --plan "$P" --repo alpha --branch q-check --read-only --dry-run 2>/dev/null | grep -q 'permissions acceptEdits' && pass "WORKER_PERMISSION_MODE changes the mode" || bad "permission mode config"
WORKER_PERMISSION_MODE=bypassPermissions "$S/dispatch/start-worker.sh" --workspace "$WS" --plan "$P" --repo alpha --branch q-check --read-only --dry-run 2>&1 | grep -q 'refused: WORKER_PERMISSION_MODE' && pass "start-worker refuses an unsafe permission mode" || bad "permission mode refusal"
G="$WS/plans/greeting"
"$S/dispatch/start-wave.sh" --workspace "$WS" --plan "$G" --branch greeting --dry-run alpha beta 2>/dev/null > "$FIX/wave.out"; grep -q '^=== alpha (exit 0)' "$FIX/wave.out" && grep -q '^=== beta (exit 0)' "$FIX/wave.out" && grep -q 'would start worker greeting-alpha' "$FIX/wave.out" && pass "start-wave starts every repo of a wave and reports in order" || bad "start-wave"
"$S/dispatch/start-review.sh" --workspace "$WS" --plan "$G" --repo alpha --dry-run 2>&1 | grep -q 'no report yet' && pass "start-review refuses without the worker's report" || bad "start-review without report"
printf '# Report - alpha\n\n## Tasks done\n\n- greet\n' > "$G/reports/alpha.md"
"$S/dispatch/start-review.sh" --workspace "$WS" --plan "$G" --repo alpha --dry-run 2>/dev/null | grep -qE 'would start worker greeting-review-alpha .*--add-dir [^ ]*/plans/greeting( |$)' && grep -q "git diff origin/staging..greeting" "$WS/plans/greeting-review-alpha/TASK.md" && pass "start-review writes a path-based brief and starts a reviewer that can read the plan" || bad "start-review brief"
"$S/dispatch/start-worker.sh" --workspace "$WS" --plan "$P" --repo alpha --branch q-check --review --dry-run 2>/dev/null | grep -q 'model default, effort high' && pass "start-worker --review takes the review defaults" || bad "start-worker review defaults"
MODEL_REVIEW=opus EFFORT_REVIEW=max "$S/dispatch/start-worker.sh" --workspace "$WS" --plan "$P" --repo alpha --branch q-check --review --dry-run 2>/dev/null | grep -q 'model opus, effort max' && pass "start-worker --review reads MODEL_REVIEW and EFFORT_REVIEW" || bad "start-worker review config"
MODEL_LOOKUP='bad model' "$S/dispatch/start-worker.sh" --workspace "$WS" --plan "$P" --repo alpha --branch q-check --read-only --dry-run 2>&1 | grep -q 'refused: model looks wrong' && pass "start-worker refuses a malformed model" || bad "start-worker malformed model"
[ -f "$P/.dispatch/alpha.settings.json" ] && grep -q "$S/dispatch/guard.sh" "$P/.dispatch/alpha.settings.json" && pass "worker profile rendered with real hook paths" || bad "worker profile rendered"
printf '# Report - alpha\n\nRead at: main @ abc1234\n\n## Answer\n\nalpha exports name. The sibling repo beta consumes it; beta was not read.\n\n## Evidence\n\n- src/index.js:1\n\n## Not determined\n\n- beta not checked\n\n## Learnings verified\n\nNone\n\n## Learnings\n\n- Tests run with node --test, not jest.\n' > "$P/reports/alpha.md"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%Y-%m-%dT%H:%M:%S)" alpha q-check-alpha herdr wX wX:p1 "$WS/alpha" medium claude default main abc1234 >> "$P/.dispatch/workers.tsv"
"$S/dispatch/link-repos.sh" --plan "$P" --dry-run 2>/dev/null | grep -q 'would link alpha -> beta' && pass "link-repos finds the cross-repo mention" || bad "link-repos detection"
"$S/dispatch/finish-lookup.sh" --plan "$P" >/dev/null 2>&1; grep -q '^- Linked: beta' "$WS/REPOS.md" && grep -q 'q-check' "$WS/METRICS.md" && grep -q 'node --test' "$WS/learnings/alpha.md" && pass "finish-lookup: links, metrics row, learnings" || bad "finish-lookup"
"$S/dispatch/finish-lookup.sh" --plan "$P" 2>/dev/null | grep -q 'already written' && [ "$(grep -c '^- Linked: beta' "$WS/REPOS.md")" = 1 ] && pass "finish-lookup is idempotent" || bad "finish-lookup idempotent"
[ -f "$P/.dispatch/finished" ] && [ -z "$(. "$S/dispatch/backend.sh"; be_rows "$WS/plans" | grep q-check)" ] && pass "live scan skips a finished plan without asking the backend" || bad "finished plan skipped"
P3="$WS/plans/q-settled"; mkdir -p "$P3/.dispatch" "$P3/reports"; printf '# Lookup - settled\n\nRepos: alpha\n' > "$P3/TASK.md"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "2000-01-01T00:00:00" alpha q-settled-alpha tmux none none "$WS/alpha" medium claude default main abc1234 >> "$P3/.dispatch/workers.tsv"
printf '# Report - alpha\n' > "$P3/reports/alpha.md"
[ -n "$(. "$S/dispatch/backend.sh"; be_rows "$WS/plans" | grep q-settled)" ] && [ -z "$(. "$S/dispatch/backend.sh"; be_live_rows "$WS/plans" | grep q-settled)" ] && pass "a worker with a report newer than its start is not live" || bad "settled worker still live"
P2="$WS/plans/q-verify"; mkdir -p "$P2/reports"; printf '# Lookup - verify\n\nRepos: alpha\n' > "$P2/TASK.md"
printf '# Report - alpha\n\n## Answer\n\nok\n\n## Learnings verified\n\n- Tests run with node --test, not jest. | still true\n\n## Learnings\n\nNone\n' > "$P2/reports/alpha.md"
"$S/dispatch/learn.sh" --plan "$P2" >/dev/null 2>&1
grep -q 'node --test' "$WS/alpha/CLAUDE.local.md" && ! grep -q 'node --test' "$WS/learnings/alpha.md" && pass "learn.sh promotes a verified learning into CLAUDE.local.md" || bad "learn.sh promotion"
[ -z "$(git -C "$WS/alpha" status --porcelain -- CLAUDE.local.md)" ] && pass "CLAUDE.local.md is invisible to git in the repo" || bad "CLAUDE.local.md shows up in git status"

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
[ -z "$(WORKSPACE_ROOT="$FIX/empty" "$S/refresh-repos/remind.sh" 2>/dev/null)" ] && pass "registry reminder stays quiet before /start" || bad "reminder before setup"
jq -e '.permissions.allow | index("Bash(.claude/skills/*)")' "$ROOT/.claude/settings.json" >/dev/null 2>&1 && pass "workspace settings pre-approve the framework scripts" || bad "framework scripts allow rule"
"$S/wrap-workstream/metrics.sh" --note "check run" >/dev/null 2>&1 && grep -q 'check run' "$WS/METRICS.md" && pass "metrics change note" || bad "metrics note"
T="$WS/plans/fix-timeout"; mkdir -p "$T/reports" "$T/.dispatch"
printf '# Task - Bump the timeout\n\nRepo: alpha\nBranch: fix-timeout\n\n## What to do\n\nBump it.\n\n## Shipped 2026-09-24\n\n- alpha: https://github.com/example/alpha/pull/7 (base staging)\n' > "$T/TASK.md"
printf '# Report - alpha\n\n## Commits\n\nfix-timeout\n- abc1234 Bump timeout\n\n## Open questions\n\nNone\n' > "$T/reports/alpha.md"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "2026-09-24T10:00:00" alpha fix-timeout-alpha tmux none none "$WS/alpha" high claude default fix-timeout abc1234 >> "$T/.dispatch/workers.tsv"
row="$(PATH=/nonexistent:$PATH "$S/wrap-workstream/metrics.sh" --plan "$T" 2>/dev/null)"; printf '%s' "$row" | grep -q '| fix-timeout | task |' && printf '%s' "$row" | grep -qE '\| 1 \| [^|]* \| [^|]* \| [^|]* \|$' && pass "metrics row for a shipped no-plan task counts its PR from TASK.md" || bad "metrics no-plan PRs: $row"
"$S/status/status.sh" --all 2>/dev/null | sed -n '/^## fix-timeout/,/^## /p' | grep -q 'PRs: https://github.com/example/alpha/pull/7' && pass "status shows a no-plan task's PR from its TASK.md" || bad "status no-plan PRs"

# the Claude app: approval from an answer, workers off the app
A="$WS/plans/phone-demo"; mkdir -p "$A"; printf '# Phone demo\n\n> **Status:** landed 2026-09-25, awaiting approval. (Dispatch refuses to start until this line reads `approved <date>`.)\n> **Scope:** alpha\n' > "$A/README.md"
ask() { jq -n --arg q "$1" --arg a "$2" '{hook_event_name: "PostToolUse", tool_name: "AskUserQuestion", tool_input: {questions: [{question: $q}]}, tool_response: {answers: {($q): $a}}}' | "$S/land-plan/approve.sh"; }
jq -n '{tool_input: {questions: [{question: "Approve plan phone-demo?"}], answers: {"Approve plan phone-demo?": "Approve"}}}' | "$S/land-plan/approve.sh" --guard >/dev/null 2>&1; [ $? = 2 ] && pass "approve guard refuses a pre-answered question" || bad "approve guard pre-answered"
jq -n '{tool_input: {questions: [{question: "Approve plan phone-demo?"}]}}' | "$S/land-plan/approve.sh" --guard >/dev/null 2>&1 && pass "approve guard lets a plain question through" || bad "approve guard plain"
ask "Approve plan phone-demo?" "Not yet" >/dev/null; grep -q 'landed 2026-09-25' "$A/README.md" && pass "Not yet leaves the plan unapproved" || bad "approve Not yet"
ask "Approve plan missing-plan?" "Approve" >/dev/null; ask "Ship phone-demo?" "Approve" >/dev/null; grep -q 'landed 2026-09-25' "$A/README.md" && pass "other questions never approve" || bad "approve other questions"
out="$(ask "Approve plan phone-demo?" "Approve")"; grep -Eq '^> \*\*Status:\*\* approved [0-9]{4}-[0-9]{2}-[0-9]{2}' "$A/README.md" && ! grep -q 'landed 2026-09-25' "$A/README.md" && printf '%s' "$out" | jq -e '.hookSpecificOutput.additionalContext | test("phone-demo")' >/dev/null 2>&1 && pass "Approve writes the approval line dispatch reads and tells the session" || bad "approve writes line"
[ "$(grep -c 'Status:' "$A/README.md")" = 1 ] && grep -q '^> \*\*Scope:\*\* alpha' "$A/README.md" && pass "approval rewrites one line and keeps the rest" || bad "approve keeps README"
jq -e '.remoteControlAtStartup == false' "$S/dispatch/worker-settings.json" >/dev/null 2>&1 && pass "workers start with Remote Control off" || bad "worker Remote Control"
jq -e '.inputNeededNotifEnabled and .agentPushNotifEnabled and (.hooks.PreToolUse[] | select(.matcher == "AskUserQuestion")) and (.hooks.PostToolUse[] | select(.matcher == "AskUserQuestion"))' "$ROOT/.claude/settings.json" >/dev/null 2>&1 && pass "coordinator settings carry pushes and the app hooks" || bad "coordinator app settings"
cd "$ROOT" || exit 1
if [ "$KEEP" = 1 ]; then echo "fixture kept at $WS"; else rm -rf "$FIX"; fi
[ "$fail" = 0 ] && echo "all checks passed" || echo "some checks failed"
exit $fail
