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
- Do not create a commit unless the user has explicitly requested or approved committing for the current task.

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

## Swift & SDK Baseline

- Use Swift 6 language mode for all Swift targets and new code by default.
- Keep the project development/deployment target at `15.6` unless the user explicitly requests a different version for a specific task.
- Prefer the latest Swift syntax and the newest SDK capabilities available for target `15.6`; avoid legacy/deprecated APIs when modern equivalents are available.

## Build Verification Gate

- After every code change, run a local build verification before delivery.
- Do not deliver code if there is any compile error or any compile warning.
- Treat warning-free builds as a hard requirement for handoff.

## AI Agent Temporary Workspace

- All AI agent-generated temporary files, debug scripts, caches, logs, and build artifacts must be placed under `.ai-tmp/`.
- Use subdirectories under `.ai-tmp/` for isolation, for example: `.ai-tmp/codex-tmp/`, `.ai-tmp/.spm-cache/`, `.ai-tmp/.spm-clone/`.
- Do not create ad-hoc temporary directories at repository root (for example: `.tmp-*`, `.spm-cache`, `.spm-clone`, `dist`, `.codex-tmp`) unless the user explicitly requests it.
- Any file outside `.ai-tmp/` should be treated as potentially version-controlled by default.
