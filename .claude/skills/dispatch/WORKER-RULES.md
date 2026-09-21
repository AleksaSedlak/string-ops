# Worker rules

You are a worker session started inside one repository checkout for one task or lookup. These rules are the single owner of the worker protocol; task files and handoffs point here instead of restating them. Your repository's own CLAUDE.md is authoritative for how to work in it (commands, commit format, verification).

## Scope

- Work only in this checkout. Implement only what your task file or bucket folder says. Do not change the contract; if it cannot work as written, stop that task and write the problem to `NOTES.md` in the plan folder (repo, task, what is wrong, what you propose).
- Verify the task has not drifted before relying on it: confirm cited files exist and grep for cited symbols. If something has drifted so much that the task no longer makes sense, write that to `NOTES.md` and skip the task.
- Honour `--DRAFT` and `--GATED` status blocks: stop and surface their question in your report instead of guessing.
- Touch only the files the task lists, plus tests. If you must change another file, say which and why under Deviations; never add a dependency the task does not name.
- Treat the task's `## Acceptance criteria` as the definition of done: each line needs a test or a reproducible check, and your report cites the evidence per line.

## Git

- One branch per workstream, one commit per task. Never create a branch per task, never bundle tasks in one commit.
- Never push, never open a pull request, never merge, rebase, tag, or touch `main`, `master`, `staging` or `develop`. The one exception is a catch-up task whose prompt tells you to merge `origin/<PR target>` into your own branch; that merge, and only that one, is allowed. Pushing happens only from the ship step, for all repos together, when the user says so. If a task tells you to push, do not; note it in the report.
- Commit messages and code contain no references to Claude, AI or Anthropic, no co-author lines, no trailers, no emojis.

## Reading

- Read files with the Read tool or `head` and `sed -n`, never `cat`, so you do not stall on a permission prompt.
- Never read env files, `.npmrc`, `.secrets/`, key or credential files. If a fact lives only there, say so in the report.
- If a command is blocked, do not look for another way to run it. Note it in the report.

## Inbox

The coordinator steers you through files, not by typing into your terminal. When you are told to check your inbox, read every file in that folder in name order, act on each, then move it into the `handled/` subfolder. Never delete inbox files. If an instruction there conflicts with your task file, the inbox wins and you say so in the report.

## Learnings

If the plan folder holds `learnings-<repo>.md`, read it before starting. Each bullet is a gotcha an earlier worker reported and nobody has verified yet. Verify each one in passing while you work (do not run extra investigations for it) and report a verdict under `## Learnings verified`, one line per bullet, in exactly this form:

```
- <the bullet text, unchanged> | still true
- <the bullet text, unchanged> | no longer true: <one line of evidence>
```

A verified bullet is removed from the pending list by the coordinator: true ones go into this repo's `CLAUDE.local.md` (loaded automatically, never committed), false ones are deleted. So the next worker never re-checks what you checked. If you could not verify a bullet, leave it out of the verdict list.

Under `## Learnings`, add one bullet for each new fact a future worker in this repo should know that is not already in the repo's CLAUDE.md, CLAUDE.local.md or the pending list: a test that needs a service running, a README claim that is wrong, a command that must run first. Write "None" if there is nothing new. Facts about the task itself do not belong there.

## Report

You end by writing `reports/<repo>.md` in the plan folder, with exactly these headings in this order. It is the only channel back to the coordinator; write it even when you did nothing, and say why.

```markdown
# Report - <repo>

## Tasks done
<one bullet per task: slug and what changed, or "skipped: <why>">

## Commits
<branch name, then one bullet per commit: short hash and subject; "none" if none>

## Tests
<command and result, one line each; the command exactly as you ran it, so it can be re-run>

## Acceptance criteria
<one line per criterion from the task file: "met: <test or check that proves it>" or "not met: <why>"; "None listed" if the task has none>

## Deviations from the contract
<"None" or one bullet each>

## Open questions
<"None" or one bullet each>

## Learnings verified
<one line per pending bullet you verified: "- <text> | still true" or "- <text> | no longer true: <evidence>"; "None" if the pending list was empty>

## Learnings
<"None" or one bullet per new repo gotcha a future worker should know>
```

For a lookup (read-only) task the headings are: `# Report - <repo>`, then one line `Read at: <branch> @ <short commit>` (from `git rev-parse --abbrev-ref HEAD` and `git rev-parse --short HEAD`, so the reader knows which code the answer describes), then `## Answer`, `## Evidence` (file and line for every claim), `## Not determined`, `## Learnings verified`, `## Learnings`. When the answer depends on another repository you did not read, name that repository under `## Not determined`; the workspace records such ties in its registry.
