---
name: start
description: Set up this workspace, with repos already dropped in or from nothing. Use when I say start, set up, get going, or when REPOS.md or workflow.conf is missing.
---

# Start

The only command a new user has to learn. It ends with the workspace registered and one sentence: "Now just talk. Ask a question, or describe a change." Everything after that is decided from what the user says (see `CLAUDE.md`).

The mechanics live in `start.sh` next to this file; read its header once. Run everything from the workspace root.

## 1. Tools

Run `start.sh --check`. If anything is missing, show the lines and stop; nothing works without git, jq and one of herdr or tmux, and the ship step needs gh. Do not try to install tools for the user.

## 2. Instance files

Run `start.sh --init`. It creates `REPOS.md`, `ROUTING.md`, `workflow.conf`, `METRICS.md`, `plans/` and `learnings/` when they do not exist and never overwrites. Then show `workflow.conf` and ask one question: keep these defaults (protected branches, worker cap, effort levels) or change something. Apply the answer with the Edit tool.

## 3. Repos, or none

Run `start.sh --repos`.

**Repositories are there.** For every folder without an entry:

- Register it with `/add-repo`. That skill screens the repo through a read-only worker and, when the repo has no `CLAUDE.md`, has the same worker draft one from `templates/child-CLAUDE.md` with the real install, test, lint and run commands it found. Several repos can be screened at once, up to the worker cap: start them all, then confirm the drafts with the user in the order they finish. A confirmed `CLAUDE.md` is written into the repo untracked; the user decides whether to commit it there.

When every repo has an entry, write the first `ROUTING.md` rows: one row per area you can see in the registry's `Touch when` and `Does` lines, using the words a request would use. Show the table and ask the user to correct it.

**The folder is empty.** Ask three things with AskUserQuestion, one at a time: the project's name (a folder name), what it should do in one sentence, and the stack, with "you choose" as an option. Then:

1. `start.sh --scaffold <name> --description "<sentence>"` creates the repository with a README, a CLAUDE.md from the template and a first commit on `main`.
2. If the user chose a stack, fill the commands in `<name>/CLAUDE.md` (install, test, lint, run) with the Edit tool. If they said "you choose", leave them for the first workstream to fill and say so.
3. Register it with `/add-repo`; the screening worker will report a mostly empty repo, which is correct.
4. Tell the user the first workstream is "build the first version of <name>", and that describing what it should do starts the normal flow: route, plan, workers, review, pull requests. Offer `gh repo create` for a remote only if they ask; the flow works without one until the ship step.

## 4. Finish

Print what exists now (registry entries, routing rows, `workflow.conf` values) in a short block, then the sentence: "Now just talk. Ask a question, or describe a change."

## Rules

- Never read credential files while screening; the worker rules already forbid it.
- Never edit an existing `REPOS.md` entry here; that is `/refresh-repos`.
- Running `/start` twice is safe: it keeps every file it finds and only registers what is missing.
