# Workspace

Every repository in this folder is a sibling folder with its own git history, its own CLAUDE.md and its own rules, and those are authoritative for work inside it. This folder only routes, plans and coordinates. It never edits repo code itself.

## If you were started inside a child repo

Only that repo's CLAUDE.md, its `.claude/` rules and your task files apply. Ignore the rest of this file. Never push and never open a pull request from a worker session.

## First time here

If `REPOS.md` does not exist, or `workflow.conf` is missing, the workspace is not set up. Say so and run `/start`; do nothing else first.

## How to read a request

Read `REPOS.md` before routing anything. It lists every repo, what it owns, exposes and consumes, when to touch it, and which repos never get a worker. `ROUTING.md` maps the words people use to the repos they usually mean. A folder with no entry in `REPOS.md` is named to the user before anything else.

Decide the mode from what the user says; they do not need to name a command:

- **A question**, anything that needs reading inside a repo, however small: one read-only worker per repo through `/dispatch` lookup mode. Lookups run headless (no window, no boot, an answer in the model's own time), so ask freely; this session never opens repo code itself, so it stays small and several lookups can run at once. Answer directly only when nothing inside a repo is needed.
- **"No planning, just do X in <repo>"**: one worker in that repo with the task in its prompt (`/dispatch` no-plan mode). Wait for its report, return the result. Shipping it is a separate explicit request (`/ship-workstream <slug>`), and `/wrap-workstream <slug>` closes it after the merge.
- **A change request**: the gated flow below.

## The change flow, with three gates

1. Route (`/route`): match the request against `ROUTING.md` and `REPOS.md`, confirm inside the candidate repos through lookup workers, name the repos touched, the contract owner and why. Gate 1: wait for the user.
2. Plan: no edits. Planning runs on model `MODEL_PLAN` at effort `EFFORT_PLAN` from `workflow.conf`; ask the user to switch with `/model` and `/effort` before this step if the session is not there (`default` means the model this session started with), and back afterwards. Gate 2: wait for the user, then `/land-plan` writes `plans/<workstream>/`.
3. Dispatch (`/dispatch`): one worker per repo, a wave at a time, all repos of a wave started together; contract owners first, consumers after wave 1 has real endpoints and types. When a wave's reports are in, its reviewers start at once and run while the next wave codes. Repos marked `Workflow: own` in `REPOS.md` are human-gated steps, not workers. Workers commit on the workstream branch and end by writing `plans/<workstream>/reports/<repo>.md`. Files are the only channel.
4. Integrate (`/integrate`): read `NOTES.md` and the reports, run the mechanical checks per branch, collect the reviewers' verdicts (start any that are missing), give one summary. Gate 3: wait for the user.
5. Ship (`/ship-workstream`): push the workstream branches and open one pull request per repo against its PR target, in wave order. Nothing else ever pushes.
6. Wrap (`/wrap-workstream`) once the pull requests are merged: metrics row, worktrees removed, plan folder deleted.

If the session-start note says the registry check is overdue, say so before anything else and offer `/refresh-repos`. If it lists live workers or open plans, continue from there; a restart changes nothing.

## Rules for every stage

- Protected branches (`PROTECTED_BRANCHES` in `workflow.conf`) are never committed to or pushed to. All work happens on a branch named for the workstream and reaches the PR target only through a pull request.
- Skills and plan templates state no repo rules. Commit, verification and PR-target details come from each repo's CLAUDE.md and `REPOS.md`.
- Credentials on disk are never read. Env files, `.npmrc`, `.secrets/` and key files are off limits in every repo; ask instead.
- Nothing committed anywhere references the assistant, the model or its vendor, and nothing contains emojis or em dashes.
- If a skill refuses to run or a step is blocked, stop and tell the user what was refused. Never substitute subagents, direct reads or any other path for the workflow; the workers, reports, learnings and metrics depend on it running as written.
- Any change to a skill, script or rule here is noted with `.claude/skills/wrap-workstream/metrics.sh --note "<change>"` in the same turn.
