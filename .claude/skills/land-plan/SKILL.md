---
name: land-plan
description: Convert an approved plan into plans/<workstream>/ at the workspace root - one task-file bucket per repo, a CONTRACT.md, an ARCHITECTURE.md with the rationale, a README index and a reports/ folder for the workers. Use AFTER the user has approved a plan and wants it landed as executable tasks.
---

# Land Plan as Task Files

You are landing an approved plan as a structured set of task files.

## When this skill fires

The user invokes `/land-plan` AFTER:
- A planning conversation has concluded (either in-context or via a plan file at `~/.claude/plans/`).
- The user has approved the plan and wants it landed as actionable, agent-ready task files.

Do NOT use this skill for active planning - that's plan mode. Use this skill only to **persist** an approved plan. Whether a plan is landed at all is the user's call, not this skill's.

## Where it writes

Always the workspace: output goes to `plans/<workstream>/`, one bucket folder per repo. Nothing is ever written into a child repo. Run it from the workspace root, where `REPOS.md` lives.

## Phase 1 - Establish scope (AskUserQuestion-driven)

Before writing any file, lock the following with the user via AskUserQuestion. Don't proceed until each is confirmed.

### Q1. Workstream slug (folder name)

Propose a slug derived from the plan's topic (e.g. `onboarding`, `org-creation`, `billing-migration`). Confirm with the user. In workspace mode this slug is also the branch name every worker uses, so keep it short and git-safe.

### Q1b. Repos touched and contract owner

From the routing gate and `REPOS.md`, confirm:
- Which repos are touched.
- Which one owns the contract (the repo whose endpoints, payloads or event shapes the others code against).
- Which touched repos are human-gated waves rather than worker waves: entries marked `Workflow: own` in `REPOS.md`, and package releases (a shared package must be published before consumers can install it).
- Waves: wave 0 for human-gated repos if any, wave 1 for contract owners, wave 2 for consumers. Confirm the order.
- If a consumer generates types from a running producer, confirm what happens between waves: boot the wave-1 branch and regenerate, or code against `CONTRACT.md` and regenerate at integrate time.

### Q2. Task breakdown

List the tasks you see in the plan with proposed slugs and buckets. Confirm:
- **Count** - how many discrete tasks
- **Slugs** - kebab-case, short, descriptive
- **Buckets** - one bucket per touched repo, named exactly as the folder, always.

### Q3. Status of each task

For each task, decide:
- **Ready** - fully decided, can execute now
- **DRAFT** - needs a design or product decision before implementation. Capture the exact prompt to surface to the future agent.
- **GATED** - needs explicit confirmation before kickoff (external blast radius, one-way migration, deletion-shaped operation). Capture the exact prompt + the blast radius description.

### Q4. Architecture decisions worth preserving

List the 5-15 key design choices from the plan that have rejected alternatives worth documenting. These become `ARCHITECTURE.md` sections. For each, capture:
- The decision
- The alternative(s) considered and rejected
- Why each alternative was rejected
- The consequence of the choice

If the plan is light on rejected-alternatives commentary, ask the user for them - these are the most valuable part of `ARCHITECTURE.md` for future agents.

### Q5. Backwards compatibility

Ask what must keep working for existing clients, and whether anything is allowed to break. The answer goes on the README status line. Do not assume "non-negotiable"; ask.

### Q6. Invisible decisions

Ask: "Which decisions in this plan are invisible in code? Where would a future maintainer look at a file and think 'I should add X' without realizing X was deliberately omitted?" These become code-comment breadcrumbs in Phase 4.

### Q7. Contract

Confirm the contents of `CONTRACT.md`: endpoints, payloads, event shapes, error cases, and generated-type expectations. Task files link to it instead of restating it.

## Phase 2 - Create the folder structure

After Phase 1 is locked, create the files in this order. Use the Write tool for each.

### Final layout

```
plans/<workstream>/
├── README.md            # index, waves, status, approval line
├── ARCHITECTURE.md      # decisions with rejected alternatives
├── CONTRACT.md          # endpoints, payloads, event shapes, error cases
├── AGENT-HANDOFF.md     # workstream protocol for workers, no repo rules
├── WORKER-RULES.md      # copied in by dispatch: the single owner of the worker protocol
├── NOTES.md             # where workers record contract problems (starts empty)
├── reports/             # one <repo>.md per worker, written by the worker (starts empty)
└── <repo>/task-N-<slug>[--DRAFT|--GATED].md
```

`AGENT-HANDOFF.md` lives **inside** the workstream folder. Each workstream owns its own copy - keeps the folder self-contained (one read, no navigation up), allows per-workstream protocol, and `/wrap-workstream` retires it cleanly with the rest of the folder.

## Phase 3 - Templates

Use these templates verbatim, filling placeholders. Keep voice consistent with existing docs in the repo (terse, opinionated, no marketing language, no emojis, no em dashes).

### Task file template (Ready)

```markdown
# <Bucket> Task <N> - <Title>

> **Status:** Ready
> **Parent plan:** [<relative-path-to-workstream-README>]
> **Depends on:** <other tasks or "nothing">
> **Blocks:** <other tasks or "nothing">

## Context

<2-4 paragraphs: why this exists, with file:line references where useful>

## Scope

**In:**
- <bullet>
- <bullet>

**Out:**
- <bullet>
- <bullet>

## Files to touch

- [`<path>`](<relative-link>) - what changes
- [`<path>`](<relative-link>) - what changes

## Interface contract

<Endpoint shape, DTO, behavior - wherever relevant. Use markdown tables and code fences. link the relevant section of CONTRACT.md instead of restating it.>

## Acceptance criteria

<3 to 8 lines a reviewer can tick, each one testable. Use the forms:>
- WHEN <condition> THE SYSTEM SHALL <observable behaviour>
- THE SYSTEM SHALL CONTINUE TO <existing behaviour that must not break>

## Test plan

### Unit tests

- <bullet>

### E2E tests

- <bullet>

### Verification

Follow this repo's CLAUDE.md for what to run before committing.

## Backwards compatibility

<one paragraph: what stays the same; how old clients keep working>

## Rollback

<one paragraph: how to undo if this ships and goes wrong>

## Out-of-scope follow-ups

- <bullet - link to follow-up tasks if known>

## Notes for the implementer

- <gotcha>
- <gotcha>
```

`Depends on` and `Blocks` may name tasks in other repos; write them as `<repo>/task-N-<slug>`. The `Files to touch` list cites paths as `<repo>/<path>` from the workspace root, in backticks without links, because the task file lives outside the repo.

### DRAFT variant

Prepend the following block immediately after the `# Title` and before `> **Status:**`:

```markdown
> **STATUS: DRAFT - needs <decision-type> before any implementation.**
>
> **Before starting this task, prompt the user with:**
> > "<exact question to surface - verbatim, in quotes>"
>
> Do not write code until the user provides direction.

```

Change `> **Status:**` line to `> **Status:** DRAFT - see block above`.

### GATED variant

Prepend the following block in the same position:

```markdown
> **STATUS: GATED - do not start without explicit confirmation from the user.**
>
> **Before starting this task, prompt the user with:**
> > "<exact question + blast radius description - verbatim>"
>
> Do not write code until the user explicitly approves kickoff.

```

Change `> **Status:**` line to `> **Status:** GATED - see block above`.

For both DRAFT and GATED tasks, add a pre-kickoff checklist near the top (after Context, before Scope) listing what the implementer should verify before writing code.

### ARCHITECTURE.md template

```markdown
# Architecture & Rationale - <Workstream Title>

Why the design looks the way it does. Each section captures a decision and the alternative(s) considered and rejected. **Read this before touching any task** if you weren't part of the original planning - it'll save you from re-litigating settled trade-offs.

The "what" lives in [`README.md`](./README.md). This file is the "why."

---

## 1. <Decision title>

**Decision.** <what we chose, one paragraph>

**Alternatives considered.**

- **<alt name>.** <one-paragraph description + why rejected>
- **<alt name>.** <one-paragraph description + why rejected>

**Consequence.** <one paragraph: what this means going forward>

---

## 2. <next decision>

<same structure>

---

## Cross-references

- Plan README: [`README.md`](./README.md)
- Agent handoff protocol: [`./AGENT-HANDOFF.md`](./AGENT-HANDOFF.md)
- Sibling workstreams: <list other workstreams in the same folder>

If you're picking up a task and find yourself wanting to change something documented here, **stop and ask the user first** - these decisions were made deliberately and the alternatives were considered.
```

### CONTRACT.md template

```markdown
# Contract - <Workstream Title>

Owned by `<contract-owner repo>`. Consumers code against this file, not against the owner's working tree. Changes to this file go through the user; a worker that cannot implement it as written stops and writes the problem to [`NOTES.md`](./NOTES.md).

## Endpoints

| Method | Path | Request | Response | Errors |
|---|---|---|---|---|
| ... | ... | ... | ... | ... |

## Payloads and types

<code fences with the exact shapes; name the file in the owner repo that will define each>

## Events and topics

| Topic | Publisher | Subscriber | Payload |
|---|---|---|---|

## Generated types

<which consumer regenerates from which producer, and when: between waves or at integrate time>

## Error cases

<status codes, retry semantics, idempotency>
```

### NOTES.md template

```markdown
# Notes - <Workstream Title>

Workers: if the contract cannot be implemented as written, or a task file has drifted from the code, write the problem here (repo, task, what is wrong, what you propose) and stop that task. Do not improvise around it. The integrate step reads this file first.

<empty until a worker writes here>
```

### README.md template

```markdown
# <Workstream Title>

> **Status:** landed <date>, awaiting approval<, with N `--DRAFT` and M `--GATED` tasks if any>. (Dispatch refuses to start until this line reads `approved <date>`, written by the user.)
> **Scope:** <the list of repos, contract owner first>
> **Backwards compatibility:** <the Q5 answer, one line>
> **First time picking this up?** Read [`ARCHITECTURE.md`](./ARCHITECTURE.md) before touching any task (captures the *why* behind the design), and [`./AGENT-HANDOFF.md`](./AGENT-HANDOFF.md) for the handoff protocol.

## Why this exists

<2-4 paragraphs distilled from the plan's Context section. Avoid jargon. State the problem and the intended outcome.>

## Tasks

<If using buckets, one table per bucket. one table per repo, in wave order.>

### <Bucket or repo>

| # | File | One-liner | Status |
|---|------|-----------|--------|
| 1 | [path/task-1.md](path/task-1.md) | Description | Ready |
| 2 | [path/task-2.md](path/task-2.md) | Description | **DRAFT - needs <gate>** |

<If flat, single table.>

## What's settled (architecture summary)

These decisions inform every task file. Re-open only with reason. (Full rationale lives in `ARCHITECTURE.md`.)

- **<Decision>.** <one-line summary>
- **<Decision>.** <one-line summary>

## What's out of scope (for now)

- **<topic>** - <one line on why>

## Rollout order (recommended)

<as waves:>

- **Wave 0 (human gate, if any):** <repo>: <what must be merged, published or released before wave 1 can proceed, and who does it>
- **Wave 1 (contract owners):** <repos>
- **Between waves:** <what wave 2 needs from wave 1 that is not in CONTRACT.md: a published package version, regenerated types, a running branch; or "nothing">
- **Wave 2 (consumers):** <repos>

## Cross-references

- Design rationale: [`./ARCHITECTURE.md`](./ARCHITECTURE.md)
- Agent handoff protocol: [`./AGENT-HANDOFF.md`](./AGENT-HANDOFF.md)
- <Contract: [`./CONTRACT.md`](./CONTRACT.md); Notes: [`./NOTES.md`](./NOTES.md); Reports: `./reports/`>
- Sibling workstreams: <list>
- Parent planning conversation: `~/.claude/plans/<plan-filename>.md`
```

### AGENT-HANDOFF.md template (written fresh inside every workstream folder)

```markdown
# Agent Handoff Protocol - <Workstream Title>

How to pick up a task from this folder with a fresh session.

This document is for the **human** kicking off the agent, and for the dispatch step that starts workers>. The agent itself follows the task file it's handed.

---

## Handing off a task

**One sentence is enough.** Give the agent the absolute path to the task fileor to its repo's bucket folder> and tell it to execute. Example:

> "Execute the task at `<absolute-path>/<workstream>/<bucket>/task-N-<slug>.md`. Verify file paths and line numbers in the task haven't drifted before relying on them."

That's it. The task file is self-contained (Context, Scope, Files, Interface contract, Test plan, BC/rollback). Don't over-brief - the file does the work.

---

## What the agent should do before writing code

1. **Read [`ARCHITECTURE.md`](./ARCHITECTURE.md)** if it exists. Captures the *why* behind the design so the agent doesn't accidentally "improve" something we considered and rejected.

2. **Verify the task hasn't drifted.** Task files reference specific file paths and line numbers in the codebase. Code moves. The agent should:
   - Confirm the cited files exist.
   - Grep for the referenced symbols / line ranges before relying on the line numbers.
   - If something has drifted significantly, report back rather than blindly editing.

3. **Honor the `STATUS` block at the top of `--DRAFT.md` and `--GATED.md` files.** These contain an explicit prompt the agent must surface to the user before doing any work. The agent should ask, wait for the user's answer, and only then proceed.

4. **Follow `WORKER-RULES.md` in this folder.** It is the single owner of the worker protocol: one branch per workstream and one commit per task, never pushing or touching protected branches, no credential reads, the inbox, attribution, and the exact report format. Base branch, PR target, commit format and verification steps come from this repo's CLAUDE.md; nothing here restates them.



5. **Implement only this repo's bucket.** Do not change [`CONTRACT.md`](./CONTRACT.md). If it cannot work as written, stop the task and write the problem to [`NOTES.md`](./NOTES.md).

6. **End by writing `reports/<repo>.md`** in the format WORKER-RULES.md gives. This file is the only channel back to the coordinating session.

---

## File-name conventions

| Suffix | Meaning | Agent behavior |
|--------|---------|----------------|
| (none) | Ready to execute | Read the file and proceed. |
| `--DRAFT.md` | Needs design/product decision | Surface the STATUS-block prompt; wait for the user; only then proceed. |
| `--GATED.md` | External blast radius | Surface the STATUS-block prompt; require explicit approval; only then proceed. |

Inside every task file, the structure is consistent: Context, Scope, Files to touch, Interface contract, Acceptance criteria, Test plan, BC/Rollback, Out-of-scope, Notes.

---

## Cross-references

- Task index: [`README.md`](./README.md)
- Design rationale: [`ARCHITECTURE.md`](./ARCHITECTURE.md)
<- Contract: [`CONTRACT.md`](./CONTRACT.md); Notes: [`NOTES.md`](./NOTES.md)>
```

## Phase 4 - Code-comment breadcrumbs (skill output)

For each task where the *absence* of behavior is the surprising choice (no synthesis, removed feature, intentional gap), add to the task's "Notes for the implementer" section:

> **Leave a code comment** in `<file>` at the relevant location: `// Deliberately no <X>: <one-line reason>.` This keeps the next maintainer from "improving" the missing behavior away.

The comment carries the reason itself. Code never points at `docs/` or `plans/` paths; those folders are retired when the workstream wraps. Use the Q6 answers from Phase 1.

## Phase 5 - Finalize

- Verify every internal cross-reference resolves (read the generated files and grep for relative paths that don't exist).
- Verify every code path cited in task files exists: for each touched repo, one read-only lookup worker per repo checks the citations (this session does not open repo code).
- Print a tree of what was created (e.g. `find <folder>/<workstream> -type f | sort`).

## Rules

- **Never write the docs without explicit task split confirmed in Phase 1.** Don't guess the buckets, don't infer task boundaries from the plan alone - confirm.
- **Never invent decisions for ARCHITECTURE.md.** Only capture what was actually settled in the plan. If a decision is missing rejected-alternatives, ask the user before writing the section.
- **State no repo rules.** No commands, commit formats, branch bases or verification steps in any generated file. Point at the repo's CLAUDE.md instead.
- **Nothing is written into child repos.**
- **Don't include emojis or em dashes** in any generated file.
- **Don't reference Claude / AI / Anthropic** in any generated content.
- **Don't pad task files** with sections you don't have content for. If a task has no Out-of-scope follow-ups, drop the section. Better terse than padded.
- **Path references** in task files are `<repo>/<path>` in backticks from the workspace root.
- **STATUS lines** go immediately after the title on the second line, before any other metadata bullet.
- **One concern, one task.** If a task seems to bundle two concerns, split it during Phase 1 confirmation.
- **Acceptance criteria are testable.** Each line names an observable behaviour; "works correctly" is not a criterion. Ask the user for the criteria in Phase 1 if the plan does not state them.

## Anti-patterns to avoid

- Writing ARCHITECTURE.md sections that only state the decision (no alternatives, no consequence). The whole point is preserving the *why* - sections without alternatives are worse than nothing because they imply there were no alternatives.
- Generating task files that reference files or symbols that don't actually exist in the codebase. Verify before writing.
- Padding the rollout-order list with every task in order. The list should reflect actual dependencies and gating, not be a re-numbering exercise.
- Auto-checking off "DRAFT" tasks as "Ready" because they look complete. The DRAFT/GATED status is product-driven, not document-completeness-driven. Confirm with the user before downgrading.
- Restating CONTRACT.md inside task files. Link the section.

## Output to the user (after Phase 5)

Print a concise summary:

```
Landed plan at <docs|plans>/<workstream>/

Created: <N files>
Tasks: <breakdown by status>
- Ready: <count>
- DRAFT: <count>
- GATED: <count>

Open threads (will need follow-up):
- <thread 1>
- <thread 2>

Next steps:
1. Change the README status line to `approved <date>`, then run /dispatch <workstream>.
2. One branch named for the workstream, one commit per task.
```
