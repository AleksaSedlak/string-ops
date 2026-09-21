# Agent Workflow

A folder that turns Claude Code into a coordinator for your repositories. You talk to one session. It works out which repos a request touches, plans with you, sends one worker per repo to do the work in its own checkout, has a second worker review the result, and opens pull requests only when you say so. Questions get answered the same way: a read-only worker per repo, an answer with file and line references.

It is plain markdown, shell and git. Nothing runs anywhere but your machine.

## Quick start

```
git clone https://github.com/aleksasedlak/agent-workflow my-workspace
cd my-workspace
claude
```

Then, inside Claude Code:

```
/start
```

That is the only command to learn. `/start` checks your tools, registers any repositories you have dropped into the folder, writes a `CLAUDE.md` for any repo that lacks one (or creates the first repository if the folder is empty), and ends with: "Now just talk. Ask a question, or describe a change."

To bring in repositories, clone them into the folder as siblings before or after `/start`. Each stays its own git repository with its own rules.

## What it feels like

You ask a question:

> Can a push notification's deep link open the widgets screen in the mobile app?

The coordinator starts a read-only worker inside the mobile app repo, waits for its report, and answers with the exact route names and the file and line each claim rests on. It never reads the code itself, so it stays small and several questions can run at once.

You describe a change:

> Add a "snooze" action to alert notifications, on the API and in the app.

The coordinator names the repos it touches and who owns the contract between them, and waits for your yes. It plans, and waits for your yes. It writes the plan as task files, starts one worker per repo in git worktrees, the API first, the app once the endpoint exists. Each worker commits on a branch named for the workstream and ends by writing a report. A fresh worker reviews each repo against the contract. You get one summary, and wait for your yes. Then, and only then, it pushes and opens one pull request per repo.

You want something small done without ceremony:

> No planning, just bump the timeout in the ingest service to 30 seconds.

One worker, one repo, one report, done.

## How it works

- **The coordinator never touches code.** It routes from a registry (`REPOS.md`, one entry per repo: what it owns, exposes, consumes, and when to touch it) and a vocabulary (`ROUTING.md`). Everything inside a repo is read by a worker.
- **Workers are ordinary Claude Code sessions** started in a terminal window you can watch (tmux or herdr), one per repo, in a git worktree so they never collide. A permission profile and a guard hook stop them from pushing, merging, tagging, opening pull requests, touching protected branches, running deploy tooling or reading credential files, however the command is spelled.
- **Files are the only channel.** A plan folder holds the contract, the task files, and one report per worker. Steering a worker means dropping a note in its inbox. Nothing lives only in a chat window, so closing the coordinator loses nothing; a new session picks up from disk.
- **Three gates.** Route, plan, integrate. Each ends with a summary and waits for you. Shipping needs a fourth yes.
- **Waiting costs nothing.** The coordinator ends its turn while workers run and is woken by a hook when one finishes, gets stuck, or asks something.
- **It learns as it goes.** Workers report gotchas; the next worker in that repo verifies them; verified ones are kept in that repo's local notes, capped so they stay a list of instructions. When a report names a repo the registry did not link, the link is recorded. Every workstream leaves a row in `METRICS.md`.

The longer version, with every stage, file and rule, is in [docs/how-it-works.md](docs/how-it-works.md).

## Requirements

- macOS or Linux
- [Claude Code](https://code.claude.com)
- tmux, or [herdr](https://github.com/herdr-dev/herdr): the terminal the workers run in (either one; tmux comes from your package manager)
- git, [jq](https://jqlang.github.io/jq), and the [GitHub CLI](https://cli.github.com) for pull requests

`/start` checks all of them and tells you what is missing.

## Where it stands

This is a first version and it says so. It grew inside one company's workspace of seventeen repositories, where the lookup path has run for real and the change path has run on test repositories end to end. What that means for you:

- **Expect rough edges on your first change workstream.** Plan, dispatch, review and ship have been exercised on fixtures, not yet on a stranger's repositories. When something refuses to run, the coordinator is told to stop and say what was refused rather than work around it, so you will see it.
- **tmux is new.** Workers run in tmux windows or in herdr, chosen in `workflow.conf`. herdr has carried every real run so far; the tmux backend has passed the same tests but has not lived through a real workstream yet.
- **Proven on Node, configured for the rest.** Workers are pre-approved for the build, test and dependency commands of Node, Python, Go, Rust, Ruby, Java, .NET, PHP, Elixir and Swift, and installed dependencies are copied into worktrees whichever folder the stack keeps them in. Only Node repositories have run through the flow so far.
- **Starting from nothing is new.** `/start` can create a first repository and hand it to the flow, and that path has had less use than the drop-your-repos-in path.

`tests/check.sh` proves the mechanics on throwaway repositories in a few seconds, no worker windows needed. `tests/live.sh` runs one real worker in whichever backend you have.

## Roadmap

1. One real workstream on a stranger's repositories, and the fixes it finds.
2. Per-worker token usage in the metrics rows.

## If you want the wheel

`/start` and plain language are enough. The stages are also commands, for when you want to drive one step by hand:

| Command | Does |
|---|---|
| `/route` | Names the repos a request touches and who owns the contract. Gate 1. |
| `/land-plan` | Writes an approved plan as task files under `plans/<workstream>/`. Gate 2. |
| `/dispatch` | Starts the workers, in waves. Also runs lookups and no-planning tasks. |
| `/integrate` | Reads the reports, checks each branch against the contract, runs the reviewer. Gate 3. |
| `/ship-workstream` | Pushes and opens one pull request per repo, in wave order. |
| `/wrap-workstream` | After the merges: metrics row, worktrees removed, plan folder deleted. |
| `/status` | What is open, who is working, what is waiting. |
| `/add-repo`, `/refresh-repos` | Register a new repo; find registry entries that fell behind. |
| `/upgrade` | Pull a newer version of this workflow. Your registry, plans and metrics are never touched. |

## Upgrading

```
/upgrade
```

The framework is what this repository contains. Everything `/start` writes and everything the flow produces (`REPOS.md`, `ROUTING.md`, `workflow.conf`, `METRICS.md`, `plans/`, `learnings/`, your repositories) is yours and is ignored by git here, so an upgrade is a merge that cannot collide with it. Want your registry versioned? Remove its line from `.gitignore` in your clone.

## Files

```
CLAUDE.md          how the coordinating session behaves
REPOS.md           your registry (written by /start and /add-repo)
ROUTING.md         your vocabulary: words in a request, repos they mean
workflow.conf      protected branches, worker cap, effort levels
METRICS.md         one row per workstream, one note per change to the flow
plans/             one folder per workstream or lookup while it runs
learnings/         pending gotchas per repo, awaiting verification
.claude/skills/    the commands and the scripts behind them
templates/         what /start copies from
tests/             check.sh (fast, no windows) and live.sh (one real worker)
```

## License

MIT.
