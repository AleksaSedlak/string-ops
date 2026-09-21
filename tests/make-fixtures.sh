#!/usr/bin/env bash
# Build a throwaway workspace with two fake repos (alpha, beta), bare remotes for them, and one landed
# plan, for testing the flow without touching real code. usage: make-fixtures.sh <empty dir>
set -euo pipefail
FIX="${1:?fixture root}"
rm -rf "$FIX"; mkdir -p "$FIX/ws" "$FIX/remotes"
WS="$FIX/ws"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"  # the framework checkout

cp "$SRC/CLAUDE.md" "$WS/CLAUDE.md"
mkdir -p "$WS/.claude"; ln -s "$SRC/.claude/skills" "$WS/.claude/skills"; ln -s "$SRC/templates" "$WS/templates"; cp "$SRC/templates/workflow.conf" "$WS/workflow.conf"

mkrepo() {
  local name="$1"
  local dir="$WS/$name"
  git init -q -b main "$FIX/remotes/$name.git" --bare
  git init -q -b main "$dir"
  git -C "$dir" config user.email test@example.com; git -C "$dir" config user.name Test
  cat > "$dir/package.json" <<EOF
{ "name": "$name", "version": "1.0.0", "type": "module", "scripts": { "test": "node --test" } }
EOF
  mkdir -p "$dir/src" "$dir/test"
  echo "export const name = '$name';" > "$dir/src/index.js"
  cat > "$dir/test/index.test.js" <<'EOF'
import { test } from 'node:test';
import assert from 'node:assert';
import { name } from '../src/index.js';
test('name is set', () => { assert.ok(name.length > 0); });
EOF
  echo "node_modules/" > "$dir/.gitignore"
  git -C "$dir" add -A; git -C "$dir" commit -q -m "chore: initial"
  git -C "$dir" branch staging
  git -C "$dir" remote add origin "$FIX/remotes/$name.git"
  git -C "$dir" push -q origin main staging
  git -C "$dir" checkout -q staging
  # untracked rule file, as in the real repos (CLAUDE.md is globally gitignored)
  cat > "$dir/CLAUDE.md" <<EOF
# $name

Test repo. Rules: run \`npm test\` before every commit. Commit messages use the conventional format (feat:, fix:, chore:). Branch from staging; PRs target staging.
EOF
  mkdir -p "$dir/.claude"; echo '{"permissions":{"allow":["Bash(npm test:*)"]}}' > "$dir/.claude/settings.json"
}
mkrepo alpha
mkrepo beta

cat > "$WS/REPOS.md" <<'EOF'
# Repos

## alpha
- Path: alpha · Stack: node, npm
- Branches: default main · PR target staging
- Does: fake contract owner
- Screened at: 0000000 (2026-09-18, on staging)

## beta
- Path: beta · Stack: node, npm
- Branches: default main · PR target staging
- Does: fake consumer
- Screened at: 0000000 (2026-09-18, on staging)
EOF

P="$WS/plans/greeting"
mkdir -p "$P/alpha" "$P/beta" "$P/reports"
cat > "$P/README.md" <<'EOF'
# Greeting

> **Status:** approved 2026-09-18
> **Scope:** alpha (owner), beta (consumer)
> **Backwards compatibility:** nothing breaks; new exports only.

## Tasks

### alpha

| # | File | One-liner | Status |
|---|------|-----------|--------|
| 1 | [alpha/task-1-greet.md](alpha/task-1-greet.md) | Add greet() | Ready |

### beta

| # | File | One-liner | Status |
|---|------|-----------|--------|
| 1 | [beta/task-1-use-greet.md](beta/task-1-use-greet.md) | Format a greeting per the contract | Ready |

## Rollout order (recommended)

- **Wave 1 (contract owners):** alpha
- **Between waves:** nothing
- **Wave 2 (consumers):** beta
EOF
cat > "$P/CONTRACT.md" <<'EOF'
# Contract - Greeting

Owned by `alpha`.

## Function

`greet(name: string): string` in `alpha/src/greet.js`, exported as a named export. Returns exactly `Hello, <name>!`. Throws `TypeError` when `name` is not a non-empty string.

## Consumer shape

`beta` exposes `formatGreeting(name)` in `beta/src/format.js` returning the same string, computed locally (no import across repos).
EOF
cat > "$P/NOTES.md" <<'EOF'
# Notes - Greeting

Workers: if the contract cannot be implemented as written, or a task file has drifted from the code, write the problem here (repo, task, what is wrong, what you propose) and stop that task. Do not improvise around it. The integrate step reads this file first.
EOF
cat > "$P/AGENT-HANDOFF.md" <<'EOF'
# Agent Handoff Protocol - Greeting

## What the agent should do before writing code

1. Read `CONTRACT.md` in this folder.
2. Verify the task hasn't drifted: confirm every file the task cites exists. If a cited file does not exist and the task depends on it, do not guess: write the problem to `NOTES.md` in this folder (repo, task, what is wrong, what you propose), skip that task, and say so in your report.
3. One branch per workstream, one commit per task. Base branch, commit format and verification per this repo's CLAUDE.md.
4. Implement only this repo's bucket. Do not change CONTRACT.md.
5. Never push, never open a pull request, never touch main, master or staging.
6. End by writing `reports/<repo>.md` in this folder with these headings: `## Tasks done`, `## Commits` (hash and subject), `## Tests` (command and result), `## Deviations from the contract`, `## Open questions`.

## Attribution

Commit messages and code contain no references to Claude, AI or Anthropic, no co-author lines, no trailers, no emojis.
EOF
cat > "$P/alpha/task-1-greet.md" <<'EOF'
# alpha Task 1 - Add greet()

> **Status:** Ready
> **Depends on:** nothing
> **Blocks:** beta/task-1-use-greet

## Scope

Add `src/greet.js` exporting `greet(name)` per CONTRACT.md, with a test in `test/greet.test.js` covering the happy path and the TypeError. Export it from `src/index.js` too.

## Files to touch

- `alpha/src/greet.js` (new)
- `alpha/src/index.js`
- `alpha/test/greet.test.js` (new)

## Verification

Follow this repo's CLAUDE.md for what to run before committing.
EOF
cat > "$P/beta/task-1-use-greet.md" <<'EOF'
# beta Task 1 - Format a greeting

> **Status:** Ready
> **Depends on:** alpha/task-1-greet
> **Blocks:** nothing

## Scope

Add `src/format.js` exporting `formatGreeting(name)` per CONTRACT.md, with a test. Then update the existing legacy formatter so it delegates to the new function.

## Files to touch

- `beta/src/format.js` (new)
- `beta/test/format.test.js` (new)
- `beta/src/legacy/formatter.js` (make it call formatGreeting)

## Verification

Follow this repo's CLAUDE.md for what to run before committing.
EOF
echo "fixtures at $WS"
