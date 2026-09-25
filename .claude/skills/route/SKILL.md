---
name: route
description: Work out which repos a request touches and who owns the contract. Use when I describe something I want built or changed and have not named the repos, or say route this, which repos does this touch, where does this live.
---

# Route a request

Run from the workspace root. Input: a request in plain language. Output: the repos touched, the contract owner, the consumers, and why. Then stop. This is Gate 1; nothing is planned or edited here.

If the request says "no planning", do not run this skill. Answer directly or hand the named repo to `/dispatch` in no-plan mode.

## 1. Registry check

- List the top-level folders that contain `.git`. Compare against the `## <folder>` headings in `REPOS.md`. Name any folder with no entry and any entry with no folder before doing anything else; a missing entry means the routing below may be wrong.
- Read `REPOS.md` in full with the Read tool (it is too large for shell output). It is the routing source in this workspace; ignore the per-repo `.claude/ROUTING.md` files.

## 2. First-line filter by area

Read `ROUTING.md` at the workspace root: one row per area with the words a request uses and the repos those words usually mean. Map the request to one or more areas, then to their repos. This is a shortlist, not the answer. When the request uses words no row covers, say so and go straight to the registry; when a routing turns out wrong, the fix is a row in `ROUTING.md`, which the user edits or `/start` regenerates.

## 3. Match against the registry

For each shortlisted repo, and for any repo the request names outright, read its entry and test the request against `Touch when` and `Owns`. Then follow the joins:

- If the change alters something in `Exposes`, every repo in `Consumed by` is a candidate consumer.
- If the change needs something from `Consumes`, the repo that `Owns` it is a candidate owner.
- Every repo on a `Linked` line is a candidate too: an earlier worker found it tied to this one through something the code does not show as an import or call (a payload shape, a topic consumed by name).
- A schema or shared-package change adds the repo that owns the package and every repo that pins it (their `Consumes` lines name it).
- An event or topic change adds the repo that owns the topic and every publisher and subscriber listed on it.

## 4. Confirm inside the repos

This session never opens repo code. Confirm inside the candidates through one read-only lookup worker per repo (`/dispatch` lookup mode; they run headless and in parallel, so this costs about one worker's time). Ask each worker for evidence, not opinion: the files the registry cites (route or controller files for endpoints, type or DTO files for payloads, the event helper for topic names, the manifest for pinned versions), a grep for the concrete nouns in the request (a field name, a route, a topic, a screen), and, when the owner already has a similar concept (an existing flag, field or action string), a trace of that name through the owner and into each consumer. The trace is what proves who is touched. When the registry alone answers the question with a cited file, say so and skip the workers.

Never read env files, `.npmrc`, `.secrets/` or key files. If a fact lives only there, say so.

Drop a candidate when the evidence says the request does not touch it. Add a repo when a grep finds the noun somewhere the registry did not predict, and say that the registry missed it.

## 5. Decide the contract owner

The contract owner is the repo whose endpoints, payloads or event shapes the others will code against. Usually the backend or the service that owns the topic; for schema changes it is the repo that owns the schema package, and the wave order starts there. Note anything that changes the wave shape:

- A repo marked `Workflow: own` is never dispatched a worker; the plan will hand its part to that repo's own flow as a human-gated wave.
- A shared package release is a wave 0 with a human gate; consumers cannot install what is not published.
- A consumer that generates types from a running producer (a client app from an API it calls) needs a between-waves step.
- Anything that must happen "once" or be remembered across runs needs persisted state; say where it would live and, if that is a schema change, add the schema repo as wave 0. If the choice is not obvious, list it as an open question.

## 6. Report and stop

Print exactly this and wait:

```
Request: <one line restatement>

Repos touched:
- <repo> (owner): <why, with the file or line that proves it>
- <repo> (consumer): <why, with evidence>
- <repo> (human-gated): <why>

Not touched, considered: <repo>: <why not>

Contract: <what the owner exposes that consumers code against, one or two lines>
Waves: <0: ..., 1: ..., 2: ...>
Registry gaps: <folders without entries, entries that missed a match, or "none">
Open questions: <what only you can answer, or "none">
```

Do not plan, do not edit, do not enter plan mode. Gate 1 is the user's answer to this report.
