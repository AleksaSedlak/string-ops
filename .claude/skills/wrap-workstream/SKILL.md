---
name: wrap-workstream
description: Close out a completed workstream (landed with /land-plan) or a shipped no-plan task. Verifies every task shipped, drafts a release note from the actual commits, writes the metrics row, removes the worktree, then deletes the plan folder. Use AFTER the pull requests have merged and the work is fully released - this is the inverse of /land-plan and of dispatch no-plan mode.
---

# Wrap Workstream

You are closing out a folder under `plans/`: a workstream landed with `/land-plan` (has `README.md`), or a no-plan task started by `/dispatch` (has `TASK.md` with `Repo:` and `Branch:` lines and no README). The work has shipped; the folder was scaffolding for the agents who executed it and is now stale. Your job is to verify completion, summarize what shipped, and remove the scaffolding.

## When this skill fires

The user invokes `/wrap-workstream` AFTER:
- Every task file in the workstream folder has been executed and the workstream branch has merged (one branch per repo in workspace mode).
- The release is going out, or has gone out.

Do NOT use this skill while the workstream is still in flight. If any task is unstarted, stop and tell the user which ones - they're not ready to wrap.

## Where it reads

Folders live in `plans/<slug>/` at the workspace root; each touched repo is a sibling folder, and `reports/<repo>.md` files are the primary completion signal. Lookup folders (`TASK.md` starting with `# Lookup`) are not wrapped; the user deletes those when they like.

## Phase 1 - Identify and verify

### Q1. Which workstream to wrap?

List the subdirectories of `plans/`. Candidates are `land-plan`-shaped workstreams (`README.md` + `ARCHITECTURE.md` + numbered task files) and no-plan tasks (`TASK.md` with a `## Shipped` block). If exactly one candidate has a `## Shipped` block, propose it. Otherwise ask via AskUserQuestion.

### Q2. Verify every task landed

**No-plan task.** Read `TASK.md` for the repo and branch and `reports/<repo>.md` for the commits. Every hash under `## Commits` must exist (`git -C <repo> cat-file -t <hash>`) and be reachable from the repo's PR target after the merge (`git -C <repo> branch -r --contains <hash>` names `origin/<PR target>`). A missing report, a hash that is not on the target, or no `## Shipped` block in `TASK.md` means it has not shipped: stop and say so. When it checks out, skip to Q3.

**Planned workstream.** For each `task-N-<slug>.md` (and `--DRAFT.md` / `--GATED.md` variants) in every repo bucket:

1. Read the file's "Files to touch" section.
2. Run `git -C <repo> log --oneline --all -- <cited-file>` and confirm a recent commit touches it.
3. If a task references files with no recent commits, flag it.

For each repo bucket:

1. Read `reports/<repo>.md`. A missing report means the worker never finished; flag every task in that bucket as Missing.
2. For each task the report lists as done, confirm the listed commit exists in that repo (`git -C <repo> cat-file -t <hash>`) and is reachable from the repo's PR target branch after the merge (`git -C <repo> branch -r --contains <hash>`).
3. For tasks the report does not list, fall back to the repo-mode file check inside that repo.
4. Read `NOTES.md`; any unresolved entry is a flag.

Then summarize:

```
Workstream: <slug>
Tasks: <N total>
- Landed: <count>
- Unclear: <count> (list)
- Missing: <count> (list)
```

If any task is **Missing**, STOP. Tell the user which task(s) haven't shipped and that wrapping now would lose the planning context. Do not delete anything.

If any task is **Unclear** (cited files exist but no recent commit), ask the user whether each was intentionally dropped, merged into another task, or genuinely missing. Confirm before proceeding.

### Q3. Confirm release scope

Ask the user:
- "Has this shipped to production, or is it about to?"
- "Want me to include a release note draft in the output?"

If they decline the release note, skip Phase 2.

## Phase 2 - Draft a release note (optional)

Generate a short, copy-pasteable release note from the actual git history, not from the task files. Task files captured *intent*; commits captured *reality*. Reality wins.

```bash
git log --oneline <branch-base>..<workstream-branch-or-merge-commit>
```

run it once per touched repo and group the note by repo, contract owner first.

If the user can't pin down the base branch, ask. Common patterns: the repo's PR target branch, or the commit the workstream branch forked from.

Draft format (keep tight - one or two paragraphs of summary, then a Highlights list, then public-endpoint changes if any, then a one-line verification status). Match the project's existing release-note voice if there's a prior example in the repo (search for `RELEASE` or `CHANGELOG`).

Surface to the user inline, not as a written file, unless they ask to save it.

## Phase 3 - Delete the docs

After verification (Phase 1) and the release note (Phase 2, if requested), confirm the deletion with the user - one line is enough: "About to `rm -rf <folder>/<workstream>/`. Proceed?"

Only after explicit yes:

`rm -rf <folder>/<workstream>/`. The folder is self-contained, so a single recursive remove retires the whole workstream. No need to touch anything else.

Before asking, run `.claude/skills/wrap-workstream/metrics.sh --plan <abs plan>`; it appends the folder's row to `METRICS.md` (kind `plan` or `task`; the PR outcome is read from the `## Shipped` block in README.md or TASK.md) (repos, workers, harness and model, effort, dispatch-to-report time, relaunches, blocked events, review gaps, verification results, unplanned files, PRs and their merged, closed and review-round counts from GitHub) and prints it. The row is the only record that survives the delete. Then: `plans/` is not under version control; the delete is final. Say so in the confirmation line. Then retire the worker checkouts: for each repo listed in `.dispatch/workers.tsv` whose checkout is under `.worktrees/<slug>/` (a no-plan task has exactly one), run `git -C <repo> worktree remove .worktrees/<slug>/<repo>` (add `--force` only if the user confirms the leftover files are disposable), then `git -C <repo> worktree prune`. Leave the workstream branches in place; they are merged and the user may delete them on GitHub. Close the worker windows dispatch opened (`.claude/skills/dispatch/backend.sh close <id>`, ids in `workers.tsv`) if they are still open.

## Phase 4 - Report

Print a concise summary:

```
Wrapped <workstream>.

Removed:
- <folder>/<workstream>/ (<N> files)
- <.worktrees/<workstream>/ (<M> checkouts), worker windows <ids>>

Metrics row: <the row appended to METRICS.md>
Release note: <surfaced inline above | skipped per request>
Commit: <sha | "untracked - nothing to commit">

Memory: <if anything from the workstream is worth a `feedback` or `project` memory, propose it; otherwise omit this line>
```

## Rules

- **Never delete docs without Phase 1 verification.** Missing task: stop. Unclear task: ask. A no-plan task whose commits are not on the PR target: stop.
- **Never delete data** from production stores. This skill operates on local files only.
- **Don't fabricate the release note.** Pull from `git log`, not the task files. Task files describe what we *planned*; commits describe what we *did*.
- **Don't reference Claude / AI / Anthropic** in any generated content (release note, commit message, anything else).
- **No emojis, no em dashes** in any generated content.
- **Match repo voice.** If there's a `CHANGELOG.md` or prior release-note style, mirror it. Don't impose a new format.
- **Wrap is irreversible-ish.** The docs can be recovered from git if they were committed; otherwise they're gone. Always confirm with the user before `rm -rf`.

## Anti-patterns to avoid

- Wrapping while tasks are still open ("looks done to me") - verify each one with `git log` or the worker report.
- Padding the release note with task-file prose. Release notes go to people who don't care about the migration's internal phases; they care about user-visible behavior.
- Auto-committing the deletion without surfacing the commit message for approval.
- Treating "no recent commit on a cited file" as definitive proof a task didn't ship. Tasks sometimes change files the planner didn't anticipate. When in doubt, ask the user.
