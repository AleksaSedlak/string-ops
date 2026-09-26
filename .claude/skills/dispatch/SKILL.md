---
name: dispatch
description: Start worker sessions for an approved workstream, in waves, or one worker for a no-planning task. Use when I say dispatch <workstream>, start the workers, kick off the workstream, or no planning, just do X in <repo>.
---

# Dispatch workers

Run from the workspace root. Two modes:

- **Plan mode**: `dispatch <workstream>`. Needs `plans/<workstream>/` written by `/land-plan` and a README whose status line reads `> **Status:** approved <date>`, written by the user or by the approval hook when the user answers `Approve` to land-plan's question. Starts one worker per repo bucket, in waves.
- **No-plan mode**: "no planning, do X in <repo>". Writes `plans/<slug>/TASK.md`, starts one worker, returns its report. No gates, no contract, no land-plan.
- **Lookup mode**: any question that needs reading inside a repo ("how does X work", "what is the format of Y", "where is Z"). Writes `plans/<slug>/TASK.md`, starts one read-only worker per repo involved, returns the answers. The workspace session never reads repo code itself; this keeps it clean so several lookups and tasks can run at once. Read-only workers run headless by default (`LOOKUP_BACKEND` in `workflow.conf`): a background process with no window, so an answer costs the model's own time and nothing else. Pass `--window` to `start-worker.sh` when the user wants to watch one.

Workers are Claude Code sessions started inside a checkout of one repo, with read access to the plan folder. They never push. Files are the only channel back: `plans/<workstream>/reports/<repo>.md`.

The mechanical parts live in this skill folder; read each header once and do not reimplement them inline: `backend.sh` (the only place that talks to herdr or tmux: open, start, status, read, prompt, close; `state.sh` is the worker-side hook that reports working, blocked or idle), `start-worker.sh` (start one worker), `start-wave.sh` (start every change worker of a wave at once, with one cap check and `--no-worktree` taken from the registry), `start-review.sh` (start the independent reviewer for one repo once its report is in), `watch.sh` (wait for the first worker to settle; also the coordinator's Stop hook), `steer.sh` (send a worker an instruction through its inbox), `WORKER-RULES.md` (the single owner of the worker protocol; copied into every plan folder), `link-repos.sh` (reads the reports for mentions of other registry repos and records each new tie as a `Linked:` line on both REPOS.md entries, so contracts the code does not show as imports reach the registry without hand edits), `finish-lookup.sh` (end of a lookup: reports present, learnings, links, metrics row, worker workspaces closed), `learn.sh` (learnings lifecycle: new bullets from reports go to `learnings/<repo>.md` as pending; the next worker in that repo verifies them in passing and reports verdicts; the harvest then removes each verified bullet, promoting true ones into that repo's `CLAUDE.local.md`, which is globally gitignored. Nothing on this path can be pushed; the script refuses to write any git-tracked file). It also pre-trusts the repo path for Claude Code and starts the worker with `worker-settings.json`: a broad allow list, the permission mode `WORKER_PERMISSION_MODE` names in `workflow.conf` (auto by default, so routine prompts such as shell loops and expansions are answered by the classifier instead of stalling; a user who wants to answer every prompt sets `default` and gets a blocked worker to steer each time), a deny list, the shared status line (model, effort, context used), and the `guard.sh` PreToolUse hook that blocks push, merge, tag, protected-branch checkout, PR creation, publish and cloud tooling in any spelling. Do not weaken either file to get a worker past a block; the block is the point. `start-worker.sh` also refuses when `WORKER_CAP` workers (workflow.conf, default 10) are already working or blocked; wait for reports rather than raising it, and raise it only for one start with `WORKER_CAP=<n>` in the environment when the user says so.

## Refusals, before anything starts

- Plan mode without the approval line: stop and say which line is missing, then ask `Approve plan <workstream>?` as land-plan does. Do not write the line yourself.
- A bucket for a repo whose `REPOS.md` entry says `Workflow: own`: do not start a worker. Tell the user that repo's part is handled through its own flow and list what the plan expects from it.
- A bucket whose task is to publish a package or cut a release: do not start a worker unless the task is only a code change; the publish step is the user's.
- Any `NOTES.md` entry left unresolved from an earlier wave: stop and show it.
- no worker backend (`backend.sh name` prints `none`): stop and tell the user; workers need herdr or tmux, chosen by `WORKER_BACKEND` in `workflow.conf`.

## Plan mode

1. Read `plans/<workstream>/README.md`: the wave list, the repos per wave, the between-waves step.
2. Start the whole wave with one command; it runs one `start-worker.sh` per repo in parallel, checks the cap once for the wave, and adds `--no-worktree` for any repo whose `REPOS.md` entry says workers use the main checkout:

   ```bash
   .claude/skills/dispatch/start-wave.sh --workspace "$PWD" --plan "$PWD/plans/<workstream>" --branch <workstream> <repo> [<repo> ...]
   ```

   Model and effort come from `workflow.conf`: `MODEL_CODE` and `EFFORT_CODE` for change work, `MODEL_LOOKUP` and `EFFORT_LOOKUP` for read-only lookups, `MODEL_REVIEW` and `EFFORT_REVIEW` for reviewers (the shipped defaults: the machine's default model everywhere, planning at xhigh in this session, coding and reviewing at high, reading at medium). To override for one worker, run `start-worker.sh` for that repo yourself with `--model` or `--effort` and say why in the README; to change the policy, edit `workflow.conf`. A repo the registry marks as main-checkout-only needs a clean checkout; the script refuses otherwise. Do not clean, stash or reset anything to make it pass; tell the user.
3. Record what the script prints (worker name, window id, pane, checkout path) in the README under a `## Dispatch` heading with the date and wave number.
4. Wait for the wave without polling. End your turn and tell the user the workers are running; the workspace's Stop hook runs `watch.sh --hook` in the background, and it wakes this session with one line (`done`, `blocked` or `stopped`, with repo and plan) when the first worker settles. When woken, act on that line and end the turn again; the hook re-arms after every turn until no worker is live. Inside a skill that must wait synchronously (a no-plan task the user is waiting on), run `watch.sh` in the foreground instead; it blocks up to six hours and prints the same line.
   - `done`: read the report. When every repo in the wave has one, the wave is complete. A `done` line for a `<workstream>-review-<repo>` folder is a reviewer finishing; note it in the README and keep waiting for the wave.
   - `blocked`: the line carries the last lines of the pane. If the pane is a question the task file or handoff already answers, answer it with `steer.sh` (see below). Otherwise show the user what the worker is asking and wait for their answer; never answer a permission prompt yourself.
   - `stopped`: the worker went idle without writing a report. Follow the recovery ladder below.
   A worker that needs a person also fires a desktop notification (the Notification hook in `worker-settings.json`), so the user sees it even when this session is idle. The user may be on the Claude app instead: put a blocked worker's question to them with AskUserQuestion, and send one PushNotification line when a wave completes or a review reports gaps.
5. A wave is complete when `reports/<repo>.md` exists for every repo in it. Check `NOTES.md` after every wave; an unresolved entry stops the next wave.
6. Start the wave's reviews at once, before anything else, so they run while the next wave codes and a contract mistake in an owner is known before its consumers build on it:

   ```bash
   .claude/skills/dispatch/start-review.sh --workspace "$PWD" --plan "$PWD/plans/<workstream>" --repo <repo>
   ```

   One per repo of the wave. Each writes `plans/<workstream>-review-<repo>/TASK.md` (paths into the plan folder, nothing pasted) and starts a headless read-only worker on the review model and effort. Do not wait for them here. If a review comes back with `gaps` in the contract while the next wave is still running, tell the user before starting anything else; a consumer coding against a wrong owner is the expensive case.
7. Between waves, do the step the README names (a published package version, regenerated types, a running branch). If it needs the user, stop and say what.
8. Start the next wave. After the last wave and its reviews are started, tell the user every report is in and `/integrate` is next. Leave the worker windows open; `integrate` and `ship-workstream` use the checkouts.

## No-plan mode

1. Take the repo and the task from the user's message. Refuse if the repo is `Workflow: own` or is not in `REPOS.md`.
2. Pick a slug (kebab-case, short). Create `plans/<slug>/` with `reports/` and this `TASK.md`:

   ```markdown
   # Task - <title>

   Repo: <repo>
   Branch: <slug>

   ## What to do

   <the user's task, verbatim, plus any clarification they gave>

   ## Acceptance criteria

   <one to five testable lines, WHEN ... THE SYSTEM SHALL ..., derived from the request; ask the user if unclear>

   ## Conventions

   Follow `WORKER-RULES.md` in this folder (branch `<slug>`, one commit, no pushing, no credential reads, inbox, report format). This repo's CLAUDE.md is authoritative for commands and commit format.

   ## Report

   When done or blocked, write `<abs path>/plans/<slug>/reports/<repo>.md` in the report format from `WORKER-RULES.md`.
   ```

3. Run `start-worker.sh` with `--no-plan --branch <slug>` (and `--no-worktree` if the registry says so).
4. Run `watch.sh` in the foreground (the user is waiting on this answer); handle `blocked` and `stopped` as in plan mode.
5. Run `learn.sh --plan <abs plan>` to harvest the report's Learnings into `learnings/<repo>.md`, then read `reports/<repo>.md` and give the user the result in chat: what changed, the commit, test results, anything left open, and any learning that was recorded. The branch is in the worktree; shipping it is a separate explicit request: `/ship-workstream <slug>` ships a no-plan folder from its `TASK.md` and report, no README or integrate step needed, and several slugs in one call cross-link their PRs. `/wrap-workstream <slug>` closes it after the merge.

## Lookup mode

1. Decide which repos the question needs from `REPOS.md` alone (the `Touch when`, `Owns`, `Exposes` and `Linked` lines; a `Linked` repo is one an earlier worker found tied to this one, so a question about the shared contract needs both). Do not open the repos. If the question names a repo, use that.
2. Pick a slug (kebab-case, prefixed `q-`, for example `q-batch-push-format`). Create `plans/<slug>/` with `reports/` and this `TASK.md`:

   ```markdown
   # Lookup - <title>

   Repos: <repo>[, <repo>]

   ## Question

   <the user's question, verbatim, plus any details they gave>

   ## Conventions

   Read only: change no file in the repository, commit nothing, install nothing. Follow `WORKER-RULES.md` in this folder for reading, inbox and report rules. Do not invent values the code does not define; say what is missing and where the user has to decide.

   ## Report

   Write `<abs path>/plans/<slug>/reports/<repo>.md` with: the answer, every file and line it rests on, decisions you had to make and why, and what you could not determine.
   ```

3. For each repo, run `start-worker.sh --read-only --branch <slug> --repo <repo>` (no worktree, no branch; the checkout is used as it is and the worker's profile denies edits and commits inside it; headless unless `--window`). Start all of them before waiting on any.
4. Run `watch.sh` in the foreground once per settle until every report is in; handle `blocked` and `stopped` as in plan mode.
5. Run `finish-lookup.sh --plan <abs plan>`. It refuses while a listed repo has no report; otherwise it harvests learnings, records any cross-repo tie the reports revealed in `REPOS.md`, writes the lookup's row to `METRICS.md` and closes the workers' herdr workspaces. Then read every `reports/<repo>.md` and answer the user in chat from them, keeping the file citations and the `Read at` branch when it is not the PR target. When the lookups disagree or a value is missing, say so rather than picking one. Tell the user every registry link the finish step added.

The lookup folder and its reports stay under `plans/` until the user deletes them; the worker workspaces do not outlive the answer.

## Steering a worker

A headless worker takes no input: if one needs an answer, relaunch it with the answer in `--prompt`. For a worker in a window, never type content into its pane. Write it with `steer.sh --plan <abs plan> --repo <repo> --message "<text>"`: the message lands in `.dispatch/inbox/<repo>/NNN.md` and the pane only gets "check your inbox". The worker reads, acts, and moves the file to `handled/`, so the exchange is on disk and a repeated doorbell is harmless. Use it for answers to a worker's question, a correction to its task, or "stop after the current task and report".

## Recovery ladder for a stuck or silent worker

Go one rung at a time and stop at the first that works. Record what you did in the plan README under `## Dispatch`.

1. Look: `backend.sh read <name> <pane> 80` (name and pane from `workers.tsv`; with tmux you can also `tmux attach -t workers`; for a headless worker this prints its output and errors so far). A worker that is still producing output is not stuck; low context or a slow test run is not a wedge.
2. Inbox: if the worker's pane shows a question that the task file, handoff, contract or WORKER-RULES already answers, answer it with `steer.sh` and wait for the next settle.
3. User: if the question is a real decision, show it to the user with the pane excerpt and wait. Do not guess.
4. Interrupt and redirect: if the worker is looping or has wandered off task, `backend.sh keys <name> <pane> esc`, then `steer.sh` with what to do instead.
5. Relaunch: if the pane is dead, the agent is `gone`, or interrupting did not help, close its window (`backend.sh close <id>`, id from `workers.tsv`) and run `start-worker.sh` again for that repo with `--prompt "Resume the tasks in <bucket>: <one line on what happened and what to do differently>"`. The worktree and branch are reused, so committed work is kept.
6. Fail: if a relaunch also stalls, write a report stub `reports/<repo>.md` yourself with `## Tasks done` "none: worker failed", the pane excerpt under `## Open questions`, and tell the user. Never delete the worktree or branch.

## After dispatch

- Worktrees live under `.worktrees/<workstream>/<repo>`. They are removed by `/wrap-workstream` after the PRs merge, never by dispatch.
- `.dispatch/workers.tsv` inside the plan folder is the record of what was started; `integrate` reads it.

## Never

- Never push, merge, tag or open a PR from this skill.
- Never write the approval line (only the user or the approval hook does), clean a dirty checkout, or answer a worker's permission prompt on the user's behalf.
- Never start a second worker for a repo that already has a live worker of the same name; `status.sh` lists them.
