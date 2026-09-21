---
name: integrate
description: Collect the workers' results for a workstream and check them against the contract. Use when I say the workers are done, integrate <workstream>, or check the reports.
---

# Integrate a workstream

Run from the workspace root. Input: a workstream slug with `plans/<workstream>/`. Output: one summary of what every worker did, checked against `CONTRACT.md`, with a merge order. Then stop. This is Gate 3; nothing is pushed or merged here.

Read-only apart from the summary you append to the plan README. Never read env files, `.npmrc`, `.secrets/` or key files.

## 1. Notes first

Read `plans/<workstream>/NOTES.md`. If it has any entry below the standing instruction paragraph, stop and show it to the user with the worker's proposed resolutions. Do not continue until the user has said what to do; an unresolved contract problem makes the rest of the check meaningless. If the user resolves it by editing a task file, that repo needs re-dispatch before integrate runs again. A report that says a problem was written to `NOTES.md` while the file has no entry counts as unresolved too: quote the report and stop.

## 2. Reports

For every repo bucket in the plan README, read `reports/<repo>.md`. A missing report means the worker did not finish; list it and stop after this section. A report whose "Tasks done" says a task was skipped is a finding, not an error; carry it into the summary.

Run `.claude/skills/dispatch/learn.sh --plan <abs plan>` once all reports are present; it files each report's Learnings into `learnings/<repo>.md` and prints what was new. Then run `.claude/skills/dispatch/link-repos.sh --plan <abs plan>`; it records every other registry repo a report names, and the entry does not yet, as a `Linked:` line on both entries. Mention the new learnings and links in the summary.

Read `plans/<workstream>/.dispatch/workers.tsv` for the checkout path of each worker. Columns, tab-separated: started-at, repo, agent name, runner (`herdr` or `tmux`), window id, pane id, checkout path, effort, harness, model, branch and commit the worker started on. A repo with a report but no row was started by hand; use `.worktrees/<workstream>/<repo>` if it exists, else the main checkout, and say so.

## 3. Per repo checks

In each repo's checkout, on the workstream branch:

- Commits: every hash the report lists exists (`git cat-file -t <hash>`), is on the workstream branch, and is ahead of the base (`git log --oneline <base>..<branch>`; the base is `origin/<PR target>` from `REPOS.md`). One commit per task is the rule; more is a finding, not a failure.
- Attribution: `git log <base>..<branch> --format=%B` contains no `Claude`, `AI`, `Anthropic`, `Co-Authored-By`, `Generated-by` or any other trailer, and no emoji. Any hit is a blocking finding.
- Tree: `git status --porcelain` is empty. Untracked or modified files mean the worker left something out of its commit.
- Contract: for each item in `CONTRACT.md` that this repo owns or consumes (endpoints, payloads, topics, types), find it in the diff (`git diff <base>..<branch>`). Grep for the route, DTO name, field or topic. Missing or different is a deviation; record the file and what differs.
- Tests: the report's Tests section names the command and result. Then ask the user, once for the whole workstream, whether to re-run the verification independently (AskUserQuestion: yes for all repos, only some, or trust the reports). It is the user's decision because runs can be slow or need services. For each repo the user picks, run exactly the command the report names:

  ```bash
  .claude/skills/integrate/verify.sh --checkout <abs checkout> --plan <abs plan> --repo <repo> --command "<command from the report>"
  ```

  It keeps the full log in `.dispatch/verify-<repo>.log` and prints only the verdict and the last lines. A FAIL where the report claimed a pass is blocking; say so with the log path.
- Scope: compare what changed with what was planned:

  ```bash
  .claude/skills/integrate/scope-check.sh --checkout <abs checkout> --base origin/<target> --tasks plans/<workstream>/<repo>
  ```

  Every `UNPLANNED` file is a finding unless the report explains it under Deviations; a manifest or lockfile among them is blocking until the user accepts it.
- Acceptance criteria: each task file has `## Acceptance criteria` lines; the report has an `## Acceptance criteria` section with evidence per line. A line without evidence, or with evidence the reviewer contradicts, is a finding.
- Between-wave artefacts: if the README's "Between waves" step named something (a published package version, regenerated types), confirm the consumer's diff uses it (a bumped version in the manifest, regenerated files changed).

Use one subagent per repo when the diffs are large; otherwise check directly.

## 3b. Independent review, one fresh reader per repo

The worker that wrote a diff never grades it. For every repo with commits, start one read-only lookup worker at effort `high` (judgement, not just reading) whose only inputs are the diff, the task files for that bucket, `CONTRACT.md` and the worker's report. Create `plans/<workstream>-review-<repo>/` with `reports/` and this `TASK.md`, then `start-worker.sh --read-only --effort high --repo <repo> --branch <workstream>-review-<repo> --plan <abs path>`; start all reviewers before waiting; wait with `watch.sh`.

```markdown
# Lookup - review of <repo> for workstream <slug>

Repos: <repo>

## Question

Review the branch `<workstream>` against its task files, their acceptance criteria and the contract. Read the diff with `git diff origin/<target>..<workstream>` and files with `git show <workstream>:<path>`; the branch lives in a worktree, so do not rely on the working tree. Report only gaps that affect correctness or a stated requirement: an acceptance criteria line not met, or met without a test proving it; a listed edge case without a test; a change to a file no task lists (say which); a departure from CONTRACT.md; a test that asserts less than the task asks. Do not report style, naming or preferences. For each gap: file and line, which requirement it breaks, and what the fix is. If you find none, say so plainly.

## Inputs

<paste each task file of the bucket in full>

<paste the relevant CONTRACT.md sections>

<paste the worker's report>

## Conventions

Read only: change no file, commit nothing, install nothing. Follow `WORKER-RULES.md` in this folder for reading and report rules.

## Report

Write `<abs path>/reports/<repo>.md` with `## Verdict` (`ready` or `gaps`), `## Gaps` (one bullet each, or "None"), `## Not determined`, `## Learnings verified`, `## Learnings`.
```

Carry every gap into the summary under "Review gaps". A gap that breaks a requirement or the contract blocks; a gap the reviewer marked as a missing test is a finding the user decides on. Run `learn.sh` on the review folder too.

## 4. Cross-repo checks

- Every `Depends on` and `Blocks` line across task files is satisfied by a done task, or the dependent task is reported as skipped.
- Producer and consumer agree: the shape the owner's diff exposes matches what each consumer's diff calls. Payload field names, types, route paths, topic names.

## 5. Summary and stop

Append this block to `plans/<workstream>/README.md` under a `## Integration <date>` heading and print it:

```
Workstream: <slug>
Repos: <n> reported, <m> missing

Per repo:
- <repo>: <commits> commit(s) on <branch>, tests <result>, contract <ok | deviations: ...>, attribution <clean | HITS>
- ...

Deviations from CONTRACT.md:
- <repo>: <what differs, file>

Review gaps (independent reader):
- <repo>: <gap, file:line, requirement it breaks> | blocking or finding

Verification re-run: <not requested | repo: PASS/FAIL, log path>
Scope: <repo: n unplanned file(s): list | clean>

Skipped tasks and open questions from the reports:
- <repo>/<task>: <why>

Merge order: <repos in wave order, with anything that must be published or released in between>

Blocking: <none | list>. Ready for ship-workstream: <yes | no, because ...>
```

Then wait. Gate 3 is the user's answer to this summary. Never push, merge, or edit code here; if a deviation needs a code change, the fix is a re-dispatch of that repo with a corrected task, not an edit from this session.
