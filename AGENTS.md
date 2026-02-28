# Repository Workflow Rules

This repository uses a PR-first workflow by default.

## Branching

- Do not develop directly on `main` unless the user explicitly requests it.
- Before making code, workflow, asset, or documentation changes, create a new branch from the latest `main`.
- Branch names created by Codex should use the `codex/` prefix.

## Delivery Flow

- After completing changes, commit them on the working branch.
- Push the branch to `origin`.
- Open a pull request targeting `main`.
- Monitor PR checks and report the status clearly to the user.
- Merge through the PR after required checks pass, unless the user explicitly asks to merge without waiting.

## Pull Request Expectations

- Treat "完成这个需求" or similar implementation requests as meaning:
  1. create branch
  2. make changes
  3. validate locally when practical
  4. commit
  5. push
  6. open PR
  7. follow CI
  8. merge to `main` when appropriate

- If the user only asks a question or asks for analysis, do not create a branch unless a repository change is needed.

## Exceptions

- If the user explicitly says to stay on the current branch, work on `main`, skip PR, or skip waiting for CI, follow that instruction for the current task.
- If no repository files need to change, do not create a branch just for discussion or investigation.
