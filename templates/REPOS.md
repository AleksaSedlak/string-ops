# Repos

Registry of every repository in this workspace. The coordinating session reads this before routing any request. One entry per folder; a folder without an entry is not touched until `/add-repo` has screened it.

Conventions:

- `Branches` names the default branch and the branch pull requests target. Protected branches (see `workflow.conf`) are never committed to or pushed to directly.
- `Workflow: own` marks a repo that is never given a worker; the workspace hands off to that repo's own flow and treats it as a human-gated step in cross-repo plans.
- `Workers use the main checkout, not a worktree` on a `Branches` line means the repo cannot be worked on from a git worktree (native builds, installed pods); workers use the checkout as it is.
- `Linked: <repo> (<why>; noted <date> from <plan>)` records a tie a worker reported that the code does not show as an import or call. Written by `link-repos.sh` from worker reports, never by hand; routing treats it like `Consumed by`.
- `Screened at` is the commit the entry describes, with the date and branch. `/refresh-repos` compares it with the PR target branch and flags entries that fell behind.

<!-- entries follow; /add-repo appends them in this shape:

## <folder>
- Path: <folder> · Stack: <language, framework, runtime, package manager, test runner>. Remote: `<owner/name>`
- Branches: default <branch> · PR target <branch>
- Does: <one sentence>
- Owns: <what only this repo decides: contracts, schemas, files>
- Consumes: <what it reads or calls elsewhere, with the file that does it>
- Exposes: <endpoints, topics, packages, types others depend on, with files>
- Consumed by: <repos and external callers>
- Touch when: <the kinds of requests that land here>
- Deploys to: <mechanism, target, trigger; "set outside the repo" when unknown>
- Screened at: <short hash> (<date>, on <branch>)
-->
