---
name: add-repo
description: Register a repository that was dropped into the workspace - screen it with a read-only worker, draft its REPOS.md entry, confirm with me, append it. Use when I say add this repo, register the new repo, screen <folder>, or a workspace folder has no REPOS.md entry.
---

# Add a repo to REPOS.md

Run from the workspace root. Input: a folder name. Output: one confirmed entry appended to `REPOS.md`, plus updated `Consumed by` lines in the entries it depends on. This session reads nothing inside the repo; a worker does.

## 1. Preflight

- Confirm `<folder>/.git` exists. If not, stop: the workspace registers git repositories only.
- Confirm `REPOS.md` has no `## <folder>` entry already. If it has, stop and point at `/refresh-repos`.
- Read the remote (`git -C <folder> remote get-url origin`) and the default branch (`gh repo view --json defaultBranchRef -q .defaultBranchRef.name` when a remote exists, else the current branch). PR target defaults to `staging` when `origin/staging` exists, otherwise the default branch.
- If the folder has no `CLAUDE.md` (root or `.claude/CLAUDE.md`), stop and ask the user to run `/init` inside it first, or write one from `templates/child-CLAUDE.md` with the commands they give you.

## 2. Screen through a worker

Start one read-only worker with `/dispatch` lookup mode, slug `q-screen-<folder>`, whose `TASK.md` question is the block below, verbatim, with the folder name filled in. Several folders can be screened at once; start every worker before waiting on any.

```
Screen this repository for the workspace registry and write the entry below, every claim citing a file.
Read only. Never read any file with `env` in its name apart from `*.env.example`, nor `.npmrc`, `.secrets/`, key files or anything that looks like a credential; if a fact lives only there, write "not determined".

Sources, in order: README and docs headings; CLAUDE.md; the package manifest (name, runtime, scripts, package manager from the tracked lockfile); entry points and routing (HTTP paths, queue or topic triggers, exported functions, with the file that defines each); outbound dependencies (HTTP clients and base URLs, topic and queue names, internal packages, database clients, third-party SDKs, and the names of environment variables the code reads, which tell you what it points at); deployment config (CI files, Dockerfile, infrastructure folders) with mechanism, target, trigger, and where env and secrets come from, writing "set outside the repo" rather than guessing.

Write the entry in exactly this shape as your Answer:

## <folder>
- Path: <folder> · Stack: <language, framework, runtime, package manager, test runner>. Remote: `<owner/name>`
- Branches: default <branch> · PR target <branch>
- Does: <one line>
- Owns: <what this repo is the source of truth for, with files>
- Consumes: <APIs, topics, packages, stores it depends on, with the file that defines each>
- Exposes: <APIs, topics, packages it provides, with the file that defines the shape>
- Consumed by: <"not determined from inside this repo">
- Touch when: <the kinds of requests that should route here, in the words a request would use>
- Deploys to: <mechanism, target, trigger, env and secret source; "not determined" where unknown>
- Screened at: <short hash> (<today>, on <branch>)

Under Not determined, list every line you could not fill and why. Under Evidence, the file and line for each claim.
```

## 3. Confirm

When the report is in, read it and cross-check the draft against `REPOS.md`: which existing entries expose what this repo consumes, and which consume what it exposes (topic names, package names and URLs are the usual joins). Fill `Consumed by` from that. Mark `Workflow: own` only when the repo ships its own agent workflow that conflicts with the worker rules (agents allowed to push or open pull requests on their own, an issue-driven flow of its own).

Show the draft and the open questions. Wait for the user's answer and apply their corrections before writing anything.

## 4. Write

- Insert the entry into `REPOS.md` in alphabetical order by folder name.
- For every existing entry named in the new entry's `Consumes`, add this repo to that entry's `Consumed by` line with the citing file. For every existing entry that consumes what this repo exposes, add it to the new entry's `Consumed by` line.
- Run `.claude/skills/dispatch/finish-lookup.sh --plan <abs plan>` for the screening lookup.
- Print the new line count of `REPOS.md`. Above roughly 450 lines, say that a split into one file per repo plus an index is due.

Rules for the entry: do not restate repo rules (commands, commit format, verification); the entry says what the repo is and how it connects. No em dashes, no emojis.

## Output

```
Registered <folder> in REPOS.md (<N> lines total).
Consumed-by updated in: <entries or none>
Open questions: <list or none>
```
