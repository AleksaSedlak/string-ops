---
name: ship-workstream
description: Push the workstream branches and open one pull request per repo, cross-linked, in wave order. Use only when I explicitly say ship <workstream> or push and open the PRs.
disable-model-invocation: true
---

# Ship a workstream

Run from the workspace root. This is the only place in the workflow that pushes. It runs only on an explicit instruction in the same message ("ship <workstream>", "push and open the PRs"). A summary, an approval of the integration, or "looks good" is not that instruction; ask for it.

Two kinds of folder can ship. A **planned workstream** has `README.md` from `/land-plan` and went through `/integrate`. A **no-plan task** has `TASK.md` and no README, written by `/dispatch` no-plan mode; its `Repo:` and `Branch:` lines name the one repo and the branch, and its report is the integration. Several no-plan slugs may be named in one call; they ship in the order given with cross-linked pull requests. A folder with neither file, or a lookup (`TASK.md` starting with `# Lookup`), is not shippable.

## Preflight, all repos before any push

1. Per kind. Planned: `plans/<workstream>/README.md` has an `## Integration <date>` block, and the latest one contains the exact text `Ready for ship-workstream: yes`. Anything else, including `no, because ...`, stops here: run `/integrate` first. No-plan: `reports/<repo>.md` exists, its `## Commits` section lists at least one commit, and its `## Open questions` section is empty or says none; otherwise stop and show what is missing. No integration block is needed.
2. `NOTES.md`, when the folder has one, has no unresolved entry.
3. For each repo (planned: every repo bucket; no-plan: the `Repo:` line), from `plans/<slug>/.dispatch/workers.tsv` (tab-separated: started-at, repo, agent name, runner, window id, pane id, checkout path, effort, harness, model) get the checkout path, and from `REPOS.md` the `PR target`. A repo with no row uses `.worktrees/<slug>/<repo>` if it exists, else the main checkout; say which. Then run the deterministic preflight:

   ```bash
   .claude/skills/ship-workstream/preflight.sh --checkout <abs checkout> --target <PR target> --branch <workstream>
   ```

   It prints one PASS or FAIL line per check: on the workstream branch (never `main`, `master`, `staging`, `develop`); clean tree; commits ahead of `origin/<target>`; no Claude, AI, Anthropic, co-author or trailer text and no emoji in the commit messages; no secrets in the branch's added lines (`gitleaks` when installed, a pattern scan otherwise); and a dry merge into the current `origin/<target>` with `git merge-tree`, which writes nothing.
4. `gh repo view` from the checkout resolves; `gh auth status` is fine.
5. If any line is FAIL in any repo, stop and report; push nothing. Two failures have a defined next step:
   - `merge: conflicts`: the target moved under the worker. Do not resolve it here and do not ask the worker to rebase. Run `start-worker.sh --catch-up --repo <repo> --branch <workstream> --plan <abs plan>`: it reuses the worktree and starts a worker allowed exactly one merge, of `origin/<target>` into the branch, which resolves the conflicts, runs the repo's verification and re-reports under `## Catch-up`. Then run `/integrate` again for that repo (its diff changed) and come back to ship.
   - `secrets`: show the user the first hit. Nothing ships until the commit is rewritten by a worker or the user says the hit is a false positive; record that decision in the plan README.

## Push and open PRs, in wave order

For each repo, waves in order, contract owners first:

```bash
git -C <checkout> push -u origin <workstream>
gh pr create --repo <owner/name> --base <target> --head <workstream> \
  --title "<workstream>: <one line from the plan README>" \
  --body-file <tmpfile>
```

The body, written to a temp file first. For a planned workstream:

```markdown
## Workstream: <slug>

<the "Why this exists" paragraph from the plan README, shortened to a few lines; if the README has none, one sentence from its title and scope line>

## This repo

<the task table for this repo, one line per task, from the README>

## Related pull requests

Merge in this order:

1. <repo>: <PR url or "next">
2. <repo>: <PR url or "next">

## Contract

<link to nothing; paste the relevant lines of CONTRACT.md for this repo, since reviewers cannot see the plan folder>
```

For a no-plan task, the title is the text after `# Task - ` in `TASK.md`, and the body is:

```markdown
## Task: <slug>

<the "What to do" section of TASK.md, shortened to a few lines>

## This repo

<one line per acceptance criterion from TASK.md: met or partially met, with the evidence sentence from the report's Acceptance criteria section>

## Verification

<the report's Tests lines, verbatim>

## Related pull requests

<only when more than one slug was named in this call: the other PRs in the order given, or "next">
```

Open the PRs in wave order (no-plan: the order given) so each later body can carry the earlier URLs. After the last PR, edit every earlier PR body (`gh pr edit <n> --body-file`) so all of them list all the URLs.

No labels, no reviewers, no auto-merge, no draft flag unless the user asked. Never merge. Never touch `main`, `master`, `staging` or `develop` in any way.

## Record and stop

Append to `plans/<workstream>/README.md`, or for a no-plan task to `plans/<slug>/TASK.md` (the folder keeps its kind; status and metrics read the block from either file):

```
## Shipped <date>

- <repo>: <PR url> (base <target>)
- ...
Merge order: <list>
```

Print the same block. Then stop. Merging is the user's, in the order given. `/wrap-workstream` runs after the merges.

## Never

- Never push a branch the preflight did not pass.
- Never push with `--force`, never delete or rename remote branches, never push tags.
- Never run this for a repo marked `Workflow: own` in `REPOS.md`; that repo ships through its own flow and its PR is listed in the body as "handled in <repo> via its own workflow".
- Never continue past a failed push or PR creation; report and stop so the user can see the partial state.
