---
name: upgrade
description: Pull the newest version of the workflow into this workspace without touching the registry, plans or metrics. Use when I say upgrade, update the workflow, or pull the latest framework.
---

# Upgrade

Run `.claude/skills/upgrade/upgrade.sh --dry-run` first and show the user the commits and files that would come in. Then, if they say go, run it without `--dry-run`.

Afterwards, tell the user in plain words what changed for them: read the commit messages that came in and group them as new commands, changed behaviour, and fixes. Do not paste the diff. If `tests/check.sh` failed, show its last lines and stop; do not try to fix framework files here.

Instance files are outside the framework and cannot be affected: `REPOS.md`, `ROUTING.md`, `workflow.conf`, `METRICS.md`, `plans/`, `learnings/` and every repository folder. Say so when the user asks whether the upgrade is safe.

If the script refuses because framework files have local edits, list them and ask whether to commit them (they become the user's own changes, merged on top) or discard them.
