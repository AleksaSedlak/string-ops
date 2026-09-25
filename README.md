# String Ops

<p align="center"><img src="docs/banner.jpg" alt="String Ops: pull the right strings. You orchestrate, they make it real." width="100%"></p>

**One Claude Code session that runs all your repositories.** You talk to it. It sends a worker into each repo that a request touches, has a second worker review the result, and opens the pull requests only when you say so. Plain markdown, shell and git. Nothing runs anywhere but your machine.

## Quick start

```
git clone https://github.com/aleksasedlak/string-ops my-workspace
cd my-workspace
claude
```

Inside Claude Code, run `/start`. That is the only command to learn. It:

1. Checks your tools and tells you what is missing.
2. Creates your config and registry files with sensible defaults, and shows you the config once.
3. Screens each repository in the folder with a read-only worker, drafts its registry entry and, if it has no `CLAUDE.md`, drafts one; you confirm each.
4. Writes the first vocabulary rows and ends with: *"Now just talk. Ask a question, or describe a change."*

Five minutes for a handful of repos, most of it spent reading the drafts.

## Bringing in your repositories

This folder is a clone of the framework. Your repositories live inside it as sibling folders, each one its own git repository with its own history, branches and rules. Git ignores them here, so an upgrade of the framework never touches them.

**You already have repositories.** Clone them into the folder, before or after `/start`:

```
git clone git@github.com:<owner>/api.git
git clone git@github.com:<owner>/mobile-app.git
```

`/start` screens each one with a read-only worker and writes a registry entry: what the repo owns, what it exposes, what it consumes, and when a request should touch it. A repo without a `CLAUDE.md` gets one drafted from what the worker found, and you confirm it before it is written. Drop in more later and say "add this repo".

**You are starting from nothing.** Run `/start` in the empty folder. It asks for a name, one sentence on what the project does, and a stack (or "you choose"), then creates the first repository with a README, a `CLAUDE.md` and a first commit. Your first request is then simply *"build the first version"*, and it goes through the normal flow.

Either way, the registry is what the coordinator routes from. Two files hold it: `REPOS.md`, one entry per repo, and `ROUTING.md`, the words people use and the repos they usually mean. Both are yours to edit.

## Three ways to talk to it

| You say | What happens | Reach for it when |
|---|---|---|
| **A question** <br> *"Where is the retry logic for uploads?"* | A read-only worker per repo. An answer with file and line references. Nothing changes. | You need to know something about the code. |
| **A change** <br> *"Add a snooze action to alert notifications, on the API and in the app."* | The full flow: route, plan, build, review, pull requests. You approve at three points. | More than one repo, a contract between repos, or anything you would want a second reader on. |
| **"No planning, just ..."** <br> *"No planning, just bump the request timeout in the API to 30 seconds."* | One worker, one branch, one report. No plan, no reviewer. Say "ship it" for the pull request. | A one-file fix you could hand a colleague without a design. |

> [!TIP]
> If you can name the file, say "no planning". If you have to name two repos, do not. The phrase is the switch; without it a request takes the full flow.

## The full flow, from your side

1. **Route.** The coordinator names the repos it will touch and who owns the contract between them. You say yes.
2. **Plan.** It asks a few grouped questions, proposes a plan, and writes it to `plans/<name>/`. You approve by editing one line in that folder's README to `approved <date>`.
3. **Build.** One worker per repo, in waves: contract owners first, consumers once the endpoints exist. The moment a wave finishes, a fresh worker reviews it while the next wave codes.
4. **Integrate.** You get one summary: what each repo did, what the reviewers found, what blocks. You say yes.
5. **Ship.** Say *"ship &lt;name&gt;"*. Nothing is pushed on any other words. One pull request per repo, cross-linked, in merge order.
6. **Wrap.** After the merges, say *"wrap &lt;name&gt;"*. Worktrees removed, folder deleted, one metrics row left behind.

> [!NOTE]
> Saying "approved" or "looks good" in chat never starts a build and never pushes. The approval is the edit in step 2; the push is the word "ship" in step 5. This is deliberate.

## While it runs

- **Waiting is free.** The coordinator ends its turn while workers work and is woken when one finishes, gets stuck, or asks something. A question takes about a minute; the first change worker opens a window in herdr you can watch. Silence is normal.
- **Stuck workers come to you.** The coordinator shows you the question and waits. Answer the coordinator, never a worker's window; your reply reaches the worker through its inbox.
- **Ask "status" any time.** What is open, who is working, what is waiting on you.
- **Closing the terminal loses nothing.** Everything lives in files. A new session picks up from disk.

## What keeps it safe

- Workers cannot push, merge, tag, open pull requests, touch protected branches, run deploy tools or read credential files, however the command is spelled. A permission profile and a guard hook enforce it.
- Before any push: right branch, clean tree, no leaked secrets, no AI attribution in commit messages, merges cleanly into the target.
- The coordinator never reads or edits code itself. It routes from a registry and a vocabulary; workers do the rest.
- Every window shows the model, the effort and the context in use. All of it is set per role in one config file.

## Requirements

- macOS or Linux, [Claude Code](https://code.claude.com), git, [jq](https://jqlang.github.io/jq)
- [herdr](https://github.com/herdr-dev/herdr), our pick for the windows your change workers run in: every worker in its own pane, at a glance. [tmux](https://github.com/tmux/tmux/wiki) works just as well if you already live there. Questions and reviews run headless and need neither.
- The [GitHub CLI](https://cli.github.com), for pull requests

`/start` checks all of them and tells you what is missing.

## Today and next

**Today** it runs on your desktop, macOS or Linux, where the worker windows live. When something refuses to run, the coordinator stops and says what was refused rather than working around it.

**Next:**

- **From your phone or the web.** Drive the coordinator from the Claude app, with the workers on a machine of yours.
- **Any coding agent as a worker.** Today workers are Claude Code sessions. One script opens, prompts and reads a worker window, so other agents can run in the same windows under the same rules.

## If you want the wheel

`/start` and plain language are enough. Each stage is also a command:

| Command | Does |
|---|---|
| `/route` | Names the repos a request touches and the contract owner. Gate 1. |
| `/land-plan` | Writes an approved plan as task files. Gate 2. |
| `/dispatch` | Starts the workers in waves. Also runs questions and no-planning tasks. |
| `/integrate` | Mechanical checks per branch plus the reviewers' verdicts, in one summary. Gate 3. |
| `/ship-workstream` | Pushes and opens the pull requests. Works for no-planning tasks too. |
| `/wrap-workstream` | After the merges: metrics row, worktrees removed, folder deleted. |
| `/status` | What is open, who is working, what is waiting. |
| `/add-repo`, `/refresh-repos` | Register a new repo; find registry entries that fell behind. |
| `/upgrade` | Pull a newer version of this workflow. Your registry, plans and metrics are never touched. |

The stage-by-stage account, with every file and script, is in [docs/how-it-works.md](docs/how-it-works.md).

## Upgrading

Run `/upgrade`. The framework is what this repository contains. Everything `/start` writes and everything the flow produces (`REPOS.md`, `ROUTING.md`, `workflow.conf`, `METRICS.md`, `plans/`, `learnings/`, your repositories) is yours and ignored by git here, so an upgrade is a merge that cannot collide with it.

<details>
<summary>Files in this folder</summary>

```
CLAUDE.md          how the coordinating session behaves
REPOS.md           your registry (written by /start and /add-repo)
ROUTING.md         your vocabulary: words in a request, repos they mean
workflow.conf      protected branches, worker cap, where workers run, model and effort per role
METRICS.md         one row per workstream, one note per change to the flow
plans/             one folder per workstream or lookup while it runs
learnings/         pending gotchas per repo, awaiting verification
.claude/skills/    the commands and the scripts behind them
templates/         what /start copies from
tests/             check.sh (fast, no windows) and live.sh (one real worker)
```

</details>

## License

MIT.
