# How it works

The README says what this is. This page says what happens, stage by stage, and which file or script does it. Read it when something surprises you or when you want to change the flow.

## The shape

One coordinating Claude Code session runs at the workspace root. It reads two files to decide where a request goes: `REPOS.md`, the registry, and `ROUTING.md`, the vocabulary. It never opens code inside a repository. Every read and every change inside a repository is done by a worker: a separate Claude Code session started in a terminal window (a tmux window or a herdr workspace, see `backend.sh`), inside that repository's checkout, with a permission profile that limits what it can do.

Agents talk through files only. A plan folder under `plans/` holds what a worker needs (task files, contract, rules) and what it produces (a report). Steering a running worker means writing a note into its inbox folder; the worker is told "check your inbox". Nothing important lives in a chat window.

## Three kinds of request

**A question.** The coordinator picks the repos from the registry, writes `plans/q-<slug>/TASK.md` with the question, and starts one read-only worker per repo. Each worker writes `reports/<repo>.md`: the answer, a `Read at` line naming the branch and commit it read, evidence with file and line for every claim, what it could not determine, and any gotchas it noticed. The coordinator answers from the reports and keeps the citations. Then `finish-lookup.sh` files the learnings, records any cross-repo tie the reports revealed, writes a metrics row and closes the worker windows. The report files stay.

**"No planning, just do X in <repo>."** One worker, with the task in its prompt and a `TASK.md` that carries acceptance criteria. It commits on a branch named for the task and writes a report. No gates.

**A change.** The gated flow below.

## The change flow

1. **Route** (`/route`). The vocabulary gives a shortlist of areas and repos. The registry entries confirm it: `Touch when`, `Owns`, `Exposes`, `Consumes`, `Consumed by` and `Linked` lines. Lookup workers confirm inside the candidates when the registry is not enough. Output: the repos touched, the contract owner, the consumers, and why. Gate 1.
2. **Plan.** Planning happens in the coordinator at a higher effort level, with no edits and with exploration done by workers. Gate 2. `/land-plan` writes `plans/<workstream>/`: a README with the wave order and an approval line, `CONTRACT.md` (endpoints, payloads, events, error cases), `ARCHITECTURE.md` (decisions with the alternatives that were rejected), `NOTES.md` (empty; workers write contract problems there), `AGENT-HANDOFF.md`, and one folder per repo holding numbered task files. Every task file has `## Files to touch` and `## Acceptance criteria`. The user changes the README status line to `approved <date>`; nothing starts before that.
3. **Dispatch** (`/dispatch`). `start-worker.sh` creates a git worktree under `.worktrees/<workstream>/<repo>` on the workstream branch (or uses the main checkout when the registry says the repo cannot be worked on from a worktree), copies untracked rule files and installed dependencies in (`node_modules`, `.venv`, `vendor`, `target`, whichever exist), renders the worker profile, pre-trusts the folder for Claude Code, opens a worker window through the backend, starts the worker with its prompt, and records it in `.dispatch/workers.tsv`. Waves: contract owners first, consumers once wave 1 has real endpoints and types. Repos marked `Workflow: own` are human-gated steps, not workers.
4. **Waiting.** The coordinator ends its turn. The workspace's Stop hook runs `watch.sh`, which blocks on the live workers and wakes the session with one line when the first one settles: `done`, `blocked` or `stopped`, with repo and plan. A blocked worker gets its answer through `steer.sh`. A stopped one goes up the recovery ladder: look at its pane, steer, ask the user, interrupt and redirect, relaunch, fail with a stub report.
5. **Integrate** (`/integrate`). Notes first: an entry in `NOTES.md` is unresolved until the user says otherwise. Then the reports, then per repo: commits on the right branch, no attribution, clean tree, contract respected, tests re-run through `verify.sh` if the user asks, `scope-check.sh` comparing changed files with the task files' `Files to touch`, acceptance criteria with evidence. Then a fresh read-only reviewer worker per repo, at coding effort, whose verdict goes into the summary under "Review gaps". Gate 3.
6. **Ship** (`/ship-workstream`). `preflight.sh` per repo: on the workstream branch, clean, ahead of the target, no attribution in commit messages, no secrets in the added lines (gitleaks when installed, a pattern scan otherwise), merges cleanly into the current target (a dry merge, nothing written). A conflict starts a catch-up worker, the only worker ever allowed to run a merge, and integration runs again. Then push and one pull request per repo, in wave order, bodies cross-linked. The coordinator never merges.
7. **Wrap** (`/wrap-workstream`) after the merges. `metrics.sh` writes the row, worktrees are removed, worker windows closed, the plan folder deleted. The row is the only thing that survives.

## What keeps workers safe

Two layers, both in `.claude/skills/dispatch/`:

- `worker-settings.json` is the permission profile every worker starts with: a broad allow list for reading, building and testing; a deny list for pushing, publishing, deploying and reading credential files; automatic answers for routine prompts so a worker does not stall on a shell loop. Read-only workers get an extra deny on editing and committing.
- `guard.sh` is a hook that sees every shell command before it runs and blocks `git push`, merge, rebase, tag, cherry-pick, checking out a protected branch, deleting branches, hard resets, worktree changes, remote changes, `gh pr` mutations, package publishing and cloud tooling, in any spelling. It also blocks reading credential files through the shell (env files, `.npmrc`, `.secrets/`, key files; `.env.example` stays readable), since Claude Code's own deny rules cover the Read tool but not `cat`. Plainly read-only commands go through without a prompt.

`WORKER-RULES.md` is the single owner of the worker protocol (scope, git, reading, inbox, report format). It is copied into every plan folder and the worker reads it first. Task files and handoffs point at it instead of restating it.

## What accumulates

- **Registry** (`REPOS.md`). Written by `/add-repo` from a screening worker's report (the same worker drafts a `CLAUDE.md` for a repo that has none, and the coordinator writes it once confirmed, untracked), refreshed by `/refresh-repos` when the target branch has moved past the `Screened at` commit. A session-start reminder fires when the check is more than seven days old. `link-repos.sh` adds `Linked` lines when a worker report names a repo the entry does not.
- **Learnings** (`learnings/<repo>.md`). `learn.sh` harvests the `## Learnings` section of every report as pending bullets. The next worker in that repo is asked to verify them in passing and reports a verdict; verified-true bullets move into that repo's `CLAUDE.local.md` (gitignored, at most `LEARNINGS_CAP` bullets, oldest dropped), false ones are dropped. Each bullet is checked once, by one worker.
- **Metrics** (`METRICS.md`). One row per workstream or lookup: repos, workers, harness and model, effort, time from dispatch to last report, relaunches, blocked events, review gaps, verification results, unplanned files, pull requests and their outcomes. Below it, one dated note per change to the flow itself, so a number can be read next to what changed before it.

## Worker windows

`backend.sh` is the only script that knows how windows are opened, prompted, read and closed. With herdr, its agent API reports whether a worker is working, blocked or idle. With tmux, the worker reports its own state: hooks in the worker profile write `working`, `blocked` or `idle` into a state file, and the backend reads that file plus whether the window still runs Claude Code. `WORKER_BACKEND` in `workflow.conf` picks one; `auto` takes herdr when installed and tmux otherwise. With tmux, every worker is a window in one session, and `tmux attach -t workers` shows them.

## Session start

Two hooks run when a session opens at the root: `on-start.sh` prints the status digest (open plans, missing reports, live workers, worktrees) or one quiet line, and `remind.sh` says when the registry check is overdue. A restarted coordinator continues from that digest.

## Settings

`workflow.conf`, written by `/start`: protected branches, the live-worker cap, the learnings cap, and the effort level per role (planning, change workers, lookup workers). Every script reads it through `.claude/skills/lib.sh`, which also holds the portable helpers (file times, date parsing, copy-on-write cloning, desktop notifications) so the same scripts run on macOS and Linux.

## Tests

`tests/make-fixtures.sh` builds a throwaway workspace with two small Node repos, bare remotes and a landed plan. `tests/check.sh` runs every script against it: syntax, the guard's block and allow paths, a dry-run dispatch, link detection, learnings, metrics, scope check, ship preflight including the attribution and merge checks, the status digest. It needs no herdr and no network. `tests/live.sh` starts one real worker in herdr on the fixture and finishes the lookup.

## Changing the flow

Skills state no repo rules; those come from each repository's own CLAUDE.md. Every change to a skill, script or rule gets a dated note in `METRICS.md` in the same turn, so the metrics stay readable. `tests/check.sh` should pass before the change is committed.
