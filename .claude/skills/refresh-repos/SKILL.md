---
name: refresh-repos
description: Re-screen repos whose default branch moved since their REPOS.md "Screened at" hash and update only the lines that changed. Use when I say refresh the registry, update REPOS.md, is the registry current, or after pulling new work into the repos.
---

# Refresh the registry

Run from the workspace root. Output: line edits to `REPOS.md` for repos that moved, confirmed with the user, and a bumped `Screened at` line for every repo checked. Nothing is checked out or modified in any repo.

## 1. Find what moved

```bash
.claude/skills/refresh-repos/check.sh            # all repos, fetches origin
.claude/skills/refresh-repos/check.sh <repo>    # one repo
.claude/skills/refresh-repos/check.sh --no-fetch # offline
```

For each entry it compares the recorded hash with `origin/<PR target>` from the entry's `Branches` line (the default branch when no PR target is recorded), because that is where new work lands first and where workers branch from. It prints `unchanged`, or `moved` with the count of changed files and the subset that backs the entry: manifests, README and CLAUDE.md, controllers and routes, DTOs and types, schemas, notification and pubsub helpers, deploy config. It also lists folders without an entry and entries without a folder.

Show the user the summary before doing anything else: which repos moved, how many backing files changed in each, and any registry gaps.

## 2. Decide per moved repo

- **No backing files changed**: only the `Screened at` line changes. Do it in step 4 without a worker.
- **Backing files changed**: the content has to be read, and this session does not read repo code. Start one read-only lookup worker per such repo (`/dispatch` lookup mode, `start-worker.sh --read-only`) with this `TASK.md`, all at once, then wait for the reports:

  ```markdown
  # Lookup - registry refresh for <repo>

  Repos: <repo>

  ## Question

  The workspace registry entry for this repo, quoted below, was written at commit <old>. The PR target branch `<default>` is now at <new>. These files that back the entry changed between the two:

  <list from check.sh>

  Read those files at the new commit with `git show origin/<target>:<path>` (do not rely on the working tree, which may be on another branch) and, where useful, `git diff <old> <new> -- <path>`. For every line of the entry that is no longer true, give the corrected line. For anything new the entry should mention (a new endpoint, topic, dependency, deploy step, consumer), give the line to add. Say "no change" for lines that still hold. Do not restate lines that are fine.

  ## Entry as it stands

  <the full entry, verbatim>

  ## Conventions

  - Read only. Change no file, commit nothing, install nothing.
  - Never read env files, `.npmrc`, `.secrets/` or key files.
  - Cite the file and line behind every proposed change. Keep the entry's format and voice; no em dashes, no emojis.

  ## Report

  Write `<abs path>/plans/<slug>/reports/<repo>.md` with two sections: `## Proposed line edits` (old line, new line, evidence) and `## Not determined`.
  ```

  Slug: `q-refresh-<date>-<repo>`, one plan folder per repo (the start script expects one `TASK.md` per folder).

## 3. Confirm

Show the user, per repo, the proposed edits from the reports as old line and new line pairs, plus anything the worker could not determine. Wait. Apply only what the user accepts; apply nothing to repos the user rejects.

## 4. Write

- Apply the accepted line edits to the repo's entry in `REPOS.md`.
- For every repo that moved (edited or not) set `Screened at: <new short hash> (<today>, on origin/<PR target>)`. Leave unchanged repos alone.
- If a moved repo's entry has a `Consumed by` or `Consumes` change, update the matching line in the other entry too.
- The check script stamps `.claude/registry-checked` with today's date on a full run; a session-start hook reminds the user when that stamp is older than seven days.
- Print the new line count of `REPOS.md`; above roughly 450 lines, say the split into `repos/<name>.md` plus an index is due.

## Output

```
Refreshed REPOS.md (<N> lines).
Unchanged: <repos>
Moved, hash bumped only: <repos>
Moved, entry edited: <repo>: <n> lines; ...
Registry gaps: <folders without entries, entries without folders, or none>
Not determined: <items from the reports, or none>
```

## Never

- Never check out, pull, merge, stash or otherwise change a repo's working tree; `git fetch` is the only git command that touches anything, and it only updates remote refs.
- Never edit an entry from memory or from the diff stat alone; a content change goes through a lookup worker and the user's confirmation.
