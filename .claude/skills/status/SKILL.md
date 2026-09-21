---
name: status
description: One digest of everything in flight in this workspace - plans, workers, reports, notes, PRs. Use when I ask where things are, what is running, what is waiting on me, status, or where did I leave off.
---

# Status

Run `.claude/skills/status/status.sh` (add `--all` to include finished plans) and present its output as a short digest. The script is the only reader; do not open plan folders, reports or repos to embellish it.

Order the digest by what needs the user: blocked workers and pending NOTES entries first, then plans waiting on a gate (approval, integrate, ship), then running workers, then finished items in one line. For each item say the one next action (approve, answer, integrate, ship, wrap, nothing).

If a worker shows `gone` while its report is missing, say the worker died before reporting and point at the recovery ladder in the dispatch skill. If the script prints nothing under a heading, say "none" rather than guessing.
