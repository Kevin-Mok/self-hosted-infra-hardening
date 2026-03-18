# ExecPlan: Commit Dirty Worktree

## Goal

Commit the current dirty worktree as two coherent conventional commits:

1. Gitea hardening guidance and incident tooling.
2. 2026-03-18 Gitea spam-induced latency incident writeup.

## Steps

- [completed] Inspect the dirty worktree and define commit boundaries.
- [completed] Stage and verify the first commit, including partial staging for `README.md`.
- [completed] Commit the first change group with a conventional commit message.
- [completed] Stage and verify the second commit.
- [completed] Commit the second change group with a conventional commit message.
- [completed] Confirm the worktree is clean and record the result.

## Review

- Created `docs(gitea): add hardening guidance and incident tooling` as commit `04ae5d4`.
- Created `docs(gitea): add 2026-03-18 spam latency incident report` as commit `af14fa5`.
- Used non-interactive partial staging for `README.md` to keep the March 18 incident link out of the first commit.
- Verified the scripts with `bash -n` and checked staged diffs with `git diff --check`.
