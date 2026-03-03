# Repository Workflow Rules (Lean)

## Branching
- Do not develop on `main` unless explicitly requested.
- If file changes are needed, create a branch from latest `main`.
- Codex branch names must start with `codex/`.

## Delivery Flow
- Only treat as full PR delivery when user explicitly asks (for example: "完成后提PR").
- Full delivery means: branch -> change -> local verify -> commit -> push -> PR -> follow CI -> merge when appropriate.
- Do not commit unless the user explicitly requests or approves commit for this task.
- If task is analysis/question only, do not create branch or commit.

## Exceptions
- If user says stay on current branch / work on `main` / skip PR / skip waiting CI, follow that instruction for this task.

## Swift & SDK Baseline
- Use Swift 6 for all Swift targets and new code.
- Keep deployment target at `15.6` unless user requests otherwise.
- Prefer modern APIs compatible with target `15.6`; avoid deprecated APIs.

## Build Verification Gate
- After every code change, run local build verification.
- Handoff requires: zero compile errors and zero compile warnings.

## Test Execution Policy
- Default: run targeted tests related to changed module/feature.
- Run full suite when changes are broad/high-risk or impact cannot be bounded:
- shared/common code changes
- dependency/build settings/script/test infra changes
- large refactors (batch rename/signature/file moves)
- high-risk runtime behavior (concurrency/persistence/network/security)
- user explicitly requests full suite

## AI Agent Temporary Workspace
- Put all AI-generated temp files/logs/artifacts under `.ai-tmp/`.
- Use isolated subdirectories under `.ai-tmp/`.
- Do not create ad-hoc temp dirs at repo root unless explicitly requested.

## Xcode Tooling Policy (Token + Reliability First)
- Token is money: default build/test gate is shell `xcodebuild`.
- Write verbose logs to `.ai-tmp/` and report concise summaries only.
- Use Xcode MCP only for high-value IDE-context tasks:
- workspace/tab context resolution
- project graph file operations
- targeted diagnostics/tests
- preview/snippet workflows hard to reproduce in shell
- Avoid high-output calls unless necessary (full glob/full test list/full logs).
- Scope early by path/pattern/target/test identifier.
- If MCP shows instability (`Transport closed`, XPC/timeout), switch to shell fallback instead of repeated MCP retries.
- Do not block delivery on MCP instability if equivalent `xcodebuild` verification is possible.
