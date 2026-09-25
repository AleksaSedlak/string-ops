# Contributing

Thanks for wanting to improve String Ops. The flow is fork, branch, pull request. Only the maintainer merges to `main`.

## How to contribute

1. Fork the repository and clone your fork.
2. Create a branch named for the change: `git checkout -b fix-guard-sort-flag`.
3. Make the change. Keep it to one concern per pull request.
4. Run the tests: `tests/check.sh`. Every check must pass. If you touched anything a worker runs, also run `tests/live.sh` once and say so in the pull request.
5. Push the branch to your fork and open a pull request against `main`. The template asks what changed, why, and how you verified it.

The maintainer reviews every pull request and merges what makes sense. Expect questions; a change to the flow needs a reason a future reader can follow.

## Rules for every change

- **No repo rules in skills or templates.** Commit formats, verification commands and branch targets come from each user's repositories, never from this framework.
- **Nothing company-specific.** No product names, repo names, topic names or infrastructure assumptions. This is forked by people with very different setups.
- **No assistant attribution.** Commit messages, code and docs contain no references to Claude, AI or Anthropic, no co-author lines, no trailers.
- **No emojis, no em dashes.** Use a plain dash.
- **Portable shell.** Scripts run on macOS (bash 3.2, BSD tools) and Linux (GNU tools). Helpers that paper over the difference live in `.claude/skills/lib.sh`.
- **Safety never loosens.** A change to `guard.sh`, `worker-settings.json` or a permission rule needs a test in `tests/check.sh` that proves the dangerous case is still blocked.
- **Docs move with the code.** If behaviour changes, `README.md` or `docs/how-it-works.md` changes in the same pull request.

## Reporting a problem

Open an issue with what you did, what you expected, what happened, and the output of `tests/check.sh` if it is relevant. If a worker misbehaved, include the last lines of its window or its report.
