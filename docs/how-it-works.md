# How it works

The README says what String Ops is. This page says what happens under the hood, stage by stage, and which file does it. Read it when something surprises you, or when you want to change the flow.

**Contents**

- [The shape of it](#the-shape-of-it)
- [Three kinds of request](#three-kinds-of-request)
- [The change flow, step by step](#the-change-flow-step-by-step)
- [What keeps workers safe](#what-keeps-workers-safe)
- [Where workers run](#where-workers-run)
- [What accumulates over time](#what-accumulates-over-time)
- [Settings](#settings)
- [Session start](#session-start)
- [Tests](#tests)
- [Changing the flow](#changing-the-flow)
- [Script reference](#script-reference)

## The shape of it

One coordinating Claude Code session runs at the workspace root. It never opens code inside a repository. Everything it knows about your repos comes from two files:

| File | What it holds |
|---|---|
| `REPOS.md` | The registry: one entry per repo with what it owns, exposes, consumes, and when a request should touch it |
| `ROUTING.md` | The vocabulary: the words people use, and the repos those words usually mean |

Every read and every change inside a repository is done by a **worker**: a separate Claude Code session started inside that repo's checkout, with a permission profile that limits what it can do.

- **Change workers** run in a terminal window you can watch (a herdr workspace, or a tmux window).
- **Read-only workers**, for questions and reviews, run headless: a background process with no window, because an answer does not need watching and a window costs more time than the answer.

Agents talk through files only. A plan folder under `plans/` holds what a worker needs (task files, contract, rules) and what it produces (a report). Steering a running worker means writing a note into its inbox folder and telling it "check your inbox". Nothing important lives in a chat window.

## Three kinds of request

| You say | What happens |
|---|---|
| **A question** | The coordinator picks the repos from the registry, writes `plans/q-<slug>/TASK.md`, and starts one read-only worker per repo. Each writes a report: the answer, a `Read at` line naming the branch and commit it read, evidence with file and line for every claim, what it could not determine, and any gotchas it noticed. The coordinator answers from the reports and keeps the citations. A finish script files the learnings, records any cross-repo tie the reports revealed, writes a metrics row and closes the workers. The reports stay. |
| **"No planning, just do X in &lt;repo&gt;"** | One worker, with the task in its prompt and a `TASK.md` that carries acceptance criteria. It commits on a branch named for the task and writes a report. No gates, no reviewer. On request, `/ship-workstream <slug>` ships it from that report with the same preflight as a workstream, and `/wrap-workstream <slug>` closes it after the merge. Several slugs in one ship call get cross-linked pull requests. |
| **A change** | The gated flow below. |

## The change flow, step by step

### 1. Route

The vocabulary gives a shortlist of areas and repos. The registry entries confirm it through their `Touch when`, `Owns`, `Exposes`, `Consumes`, `Consumed by` and `Linked` lines. When the registry is not enough, lookup workers confirm inside the candidate repos.

Output: the repos touched, the contract owner, the consumers, and why. **Gate 1: you say yes.**

### 2. Plan

Planning happens in the coordinator at a higher effort level, with no edits, and with exploration done by lookup workers, which are cheap enough to ask often. **Gate 2: you say yes.**

Then `/land-plan` writes `plans/<workstream>/`:

| File | Purpose |
|---|---|
| `README.md` | The wave order, the task index, and the approval line |
| `CONTRACT.md` | Endpoints, payloads, events, error cases: what consumers code against |
| `ARCHITECTURE.md` | The decisions, with the alternatives that were rejected and why |
| `NOTES.md` | Empty at first; workers write contract problems here |
| `<repo>/task-N-<slug>.md` | One folder per repo, numbered task files, each with `Files to touch` and `Acceptance criteria` |

You approve by changing the README status line to `approved <date>`. Nothing starts before that.

### 3. Dispatch

A wave script starts every repo of a wave at once. For each repo it:

1. Checks the worker cap.
2. Creates a git worktree under `.worktrees/<workstream>/<repo>` on the workstream branch, or uses the main checkout when the registry says the repo cannot be worked on from a worktree.
3. Copies in untracked rule files and installed dependencies (`node_modules`, `.venv`, `vendor`, `target`, whichever exist).
4. Renders the worker profile, pre-trusts the folder for Claude Code, opens a window through the backend, starts the worker with its prompt, and records it in `.dispatch/workers.tsv`.

Waves go contract owners first, consumers once wave 1 has real endpoints and types. Repos marked `Workflow: own` in the registry are human-gated steps, not workers.

> [!NOTE]
> The moment a wave's reports are in, one independent reviewer per repo starts. Wave 1 is reviewed while wave 2 codes, so a wrong contract is caught before consumers build on it.

### 4. Wait

The coordinator ends its turn. A hook watches the live workers and wakes the session with one line when the first one settles: `done`, `blocked` or `stopped`, with repo and plan.

- A **blocked** worker gets its answer through the inbox.
- A **stopped** worker goes up the recovery ladder: look at its pane, steer, ask you, interrupt and redirect, relaunch, and as a last resort fail it with a stub report.

### 5. Integrate

Notes first: an entry in `NOTES.md` is unresolved until you say otherwise. Then the reports. Then, per repo, the mechanical checks only:

- Commits on the right branch, ahead of the target.
- No attribution to the assistant in commit messages.
- Clean tree.
- Tests re-run through a verification script, if you ask.
- Changed files compared with the task files' `Files to touch`.

The judgement (contract respected, acceptance criteria met and proven) comes from the reviewers dispatch started: fresh read-only workers on the review model and effort. Integrate starts any that are missing and carries their verdicts into one summary. The coordinator opens no diffs itself, so it stays sharp through ship. **Gate 3: you say yes.**

### 6. Ship

A preflight per repo, all deterministic:

| Check | Passes when |
|---|---|
| Branch | On the workstream branch, never a protected one |
| Tree | Nothing uncommitted |
| Commits | Ahead of the current target |
| Attribution | No assistant, AI or co-author text, no emoji, in any commit message |
| Secrets | Nothing in the added lines (gitleaks when installed, a pattern scan otherwise) |
| Merge | Merges cleanly into the current target, checked with a dry merge that writes nothing |

A merge conflict starts a catch-up worker, the only worker ever allowed to run a merge, and integration runs again. Then push, and one pull request per repo, in wave order, bodies cross-linked. A no-plan task ships the same way from its `TASK.md` and report. The coordinator never merges.

### 7. Wrap

After the merges, for a workstream or a shipped no-plan task. Every commit in the reports must be reachable from the target branch. Then the metrics row is written, worktrees removed, worker windows closed, the folder deleted. The row is the only thing that survives.

## What keeps workers safe

Two layers, both in `.claude/skills/dispatch/`:

**The permission profile** (`worker-settings.json`) every worker starts with:

- A broad allow list for reading, building and testing.
- A deny list for pushing, publishing, deploying and reading credential files.
- The permission mode from `WORKER_PERMISSION_MODE`: `auto` by default, so routine prompts are answered by Claude Code's classifier and the worker keeps working; `acceptEdits` or `default` if you want to answer more yourself, at the price of blocked workers to steer.
- Read-only workers get an extra deny on editing and committing.

**The guard** (`guard.sh`) sees every shell command before it runs and blocks, in any spelling:

- `git push`, merge, rebase, tag, cherry-pick.
- Checking out a protected branch, deleting branches, hard resets, worktree and remote changes.
- Pull request mutations, package publishing, cloud and deploy tooling.
- Reading credential files through the shell: env files, `.npmrc`, `.secrets/`, key files. `.env.example` stays readable. Claude Code's own deny rules cover the Read tool; this covers `cat` and friends.

Plainly read-only commands go through without a prompt. A read-only utility given a writing argument (`find -delete`, `find -exec`, `sort -o`, `sed -i`, a `w` command) does not.

**The protocol** (`WORKER-RULES.md`) is the single owner of how a worker behaves: scope, git, reading, inbox, report format. It is copied into every plan folder and the worker reads it first. Task files and the worker's prompt point at it instead of restating it.

## Where workers run

One script, `backend.sh`, is the only place that knows how a worker is opened, prompted, read and closed. Three backends:

| Backend | How it knows a worker's state | Notes |
|---|---|---|
| **herdr** | Its agent API reports working, blocked or idle | Our pick for change workers |
| **tmux** | The worker reports its own state through hooks that write a state file; the backend reads that plus whether the window still runs Claude Code | Every worker is a window in one session; `tmux attach -t workers` shows them |
| **headless** | Its process and exit code | A background `claude -p`. Output in a run folder under the plan's `.dispatch/`. If it ends without writing a report, its final answer becomes the report |

`WORKER_BACKEND` picks the window backend for change workers; `auto` takes herdr when installed and tmux otherwise. `LOOKUP_BACKEND` sends read-only workers headless (the default) or into the window backend. Live-worker scans skip plans stamped finished and workers whose report is newer than their start, so old lookups cost nothing.

## What accumulates over time

**The registry** (`REPOS.md`). Written by `/add-repo` from a screening worker's report. The same worker drafts a `CLAUDE.md` for a repo that has none; the coordinator writes it once you confirm, untracked. `/refresh-repos` updates entries when a repo's target branch has moved past the commit it was screened at, and a session-start reminder fires when that check is more than seven days old. When a worker report names a repo the entry does not, a `Linked` line is added to both.

**Learnings** (`learnings/<repo>.md`). The `Learnings` section of every report is harvested as pending bullets. The next worker in that repo verifies them in passing and reports a verdict. Verified-true bullets move into that repo's `CLAUDE.local.md`, which is kept out of git through the repo's own exclude file so it cannot be committed from any worktree on any machine; at most `LEARNINGS_CAP` bullets are kept, oldest dropped. False ones are dropped. Each bullet is checked once, by one worker.

**Metrics** (`METRICS.md`). One row per workstream, no-plan task or lookup: repos, workers, harness and model, effort, time from dispatch to last report, relaunches, blocked events, review gaps, verification results, unplanned files, pull requests and their outcomes. Below the table, one dated note per change to the flow itself, so a number can be read next to what changed before it.

## Settings

Everything lives in `workflow.conf`, written by `/start`, read by every script:

| Setting | Default | What it does |
|---|---|---|
| `PROTECTED_BRANCHES` | `main master staging develop` | Never committed to or pushed to directly |
| `WORKER_CAP` | `10` | Most workers live at once |
| `LEARNINGS_CAP` | `15` | Most verified learnings kept per repo |
| `MODEL_PLAN`, `MODEL_CODE`, `MODEL_LOOKUP`, `MODEL_REVIEW` | `default` | Model per role. `default` runs whatever Claude Code starts with on this machine; set an alias or id to pin one |
| `EFFORT_PLAN`, `EFFORT_CODE`, `EFFORT_LOOKUP`, `EFFORT_REVIEW` | `xhigh`, `high`, `medium`, `high` | Reasoning effort per role |
| `WORKER_PERMISSION_MODE` | `auto` | How workers answer permission prompts: `auto`, `acceptEdits` or `default` |
| `WORKER_BACKEND` | `auto` | Where change workers run: `herdr`, `tmux` or `auto` |
| `LOOKUP_BACKEND` | `headless` | Where read-only workers run: `headless` or `window` |
| `TMUX_SESSION` | `workers` | The tmux session that holds worker windows |

Every window the framework opens shows the same status line: model, reasoning effort and context used, so what a session is running on is never a guess. The coordinator gets it from the workspace settings, workers from their profile. Both ship with a clone.

## Session start

Two hooks run when a session opens at the root. One prints the status digest (open plans, missing reports, live workers, worktrees) or one quiet line. The other says when the registry check is overdue. A restarted coordinator continues from that digest.

## Tests

| Script | What it does |
|---|---|
| `tests/make-fixtures.sh` | Builds a throwaway workspace: two small Node repos, bare remotes, a landed plan |
| `tests/check.sh` | Runs every script against it in seconds, no windows and no network: syntax, the guard's block and allow paths, dry-run dispatch of a worker, a wave and a reviewer, link detection, learnings including promotion, live-worker scans, metrics, scope check, ship preflight including the attribution and merge checks, the status digest, the status line |
| `tests/live.sh` | Starts one real read-only worker on the fixture, headless by default, and finishes the lookup |

## Changing the flow

Skills state no repo rules; those come from each repository's own `CLAUDE.md`. Every change to a skill, script or rule gets a dated note in `METRICS.md` in the same turn, so the metrics stay readable. `tests/check.sh` should pass before the change is committed.

## Script reference

All under `.claude/skills/`. Each has a header comment that says what it does; read that before reimplementing anything inline.

| Script | Does |
|---|---|
| `lib.sh` | Loads `workflow.conf` and holds the portable helpers, so the same scripts run on macOS and Linux |
| `statusline.sh` | The status line: model, effort, context |
| `dispatch/backend.sh` | Opens, starts, watches, reads, prompts and closes workers, for herdr, tmux and headless |
| `dispatch/start-worker.sh` | Starts one worker: preflight, cap, checkout, profile, window, record |
| `dispatch/start-wave.sh` | Starts every repo of a wave in parallel, one cap check |
| `dispatch/start-review.sh` | Starts the independent reviewer for one repo once its report is in |
| `dispatch/watch.sh` | Waits for the first live worker to settle; also the coordinator's Stop hook |
| `dispatch/steer.sh` | Puts a message in a worker's inbox and rings its window |
| `dispatch/guard.sh` | The command guard, run before every shell command a worker issues |
| `dispatch/state.sh`, `dispatch/notify.sh` | Worker-side hooks: report state, ping the desktop when a person is needed |
| `dispatch/learn.sh` | The learnings lifecycle |
| `dispatch/link-repos.sh` | Records cross-repo ties from reports in the registry |
| `dispatch/finish-lookup.sh` | Ends a lookup: learnings, links, metrics row, workers closed |
| `integrate/scope-check.sh` | Changed files versus the task files' `Files to touch` |
| `integrate/verify.sh` | Re-runs a worker's test command, log kept out of the coordinator's context |
| `ship-workstream/preflight.sh` | The ship checks above, one PASS or FAIL line each |
| `wrap-workstream/metrics.sh` | Writes the metrics row and the change notes |
| `status/status.sh`, `status/on-start.sh` | The status digest and the session-start hook |
| `refresh-repos/check.sh`, `refresh-repos/remind.sh` | Finds registry entries that fell behind; the overdue reminder |
| `start/start.sh` | Tool check, instance files, repo listing, first-repo scaffold |
| `upgrade/upgrade.sh` | Pulls a newer framework version without touching instance files |
