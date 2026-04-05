# Repository Workflow Rules (Lean)

## Branching
- Do not develop on `main` unless explicitly requested.
- For code changes, if the user does not specify a base branch, create a `codex/*` branch from the current branch.
- Codex branch names must start with `codex/`.

## Delivery Flow
- Only treat as full PR delivery when user explicitly asks (for example: "完成后提PR").
- Full delivery means: branch -> change -> local verify -> commit -> push -> PR -> follow CI -> merge when appropriate.
- If the user asks to keep `main` linear, rebase or otherwise update the working branch onto the latest `main` before opening or merging the PR, and use a merge method that adds a single linear commit on `main` without creating a merge commit. Prefer `squash merge` when the repository supports it; otherwise use `rebase merge`.
- Do not commit unless the user explicitly requests or approves commit for this task.
- If task is analysis/question only, do not create branch or commit.

## Exceptions
- If user says stay on current branch / work on `main` / skip PR / skip waiting CI, follow that instruction for this task.

## Swift & SDK Baseline
- Use Swift 6 for all Swift targets and new code.
- Keep deployment target at `15.6` unless user requests otherwise.
- Prefer modern APIs compatible with target `15.6`; avoid deprecated APIs.

## Compatibility Scope
- Default to the current supported interfaces and behavior.
- Do not preserve legacy interfaces, legacy behavior, compatibility layers, fallback branches, or duplicate paths unless user requirements, external callers, migration windows, or release plans explicitly require them.
- If legacy compatibility is retained, document the reason, removal condition, and validation impact in the handoff.

## Build Verification Gate
- After every code change, run local build verification.
- Handoff requires: zero compile errors and zero compile warnings.

## Test Execution Policy
- After every code change, explicitly check whether related tests need to be updated or added, and complete required test updates before handoff.
- Default: run targeted tests related to changed module/feature.
- If related verification has already completed after the latest code change, and no repo-tracked file has changed since that verification, a later commit-only instruction must reuse the existing fresh verification result instead of rerunning the same tests.
- For small, explicit, low-risk changes with tightly bounded impact, do not run the full `HomeSmokeTests` suite by default. Prefer build-only verification or a narrower targeted test that covers the changed control or flow.
- Run full suite when changes are broad/high-risk or impact cannot be bounded:
- shared/common code changes
- dependency/build settings/script/test infra changes
- large refactors (batch rename/signature/file moves)
- high-risk runtime behavior (concurrency/persistence/network/security)
- user explicitly requests full suite

## Test Permission Prompt Isolation
- Automated tests must not trigger app-driven macOS privacy prompts such as screen recording, microphone, or camera authorization dialogs.
- Test runs must remain non-interactive and must not depend on a human waiting for app permission prompts during execution.
- Any code path that may request app privacy permissions must switch to a test-specific provider, mock, stub, or equivalent isolation layer under test environments.
- macOS authorization required by the test harness itself, such as Automation, Accessibility, Input Monitoring, or related administrator approval for UI automation, is environment setup and should be handled separately from app permission flows.
- Reject any test change that can block local or CI execution by introducing new app-driven privacy authorization prompts.

## UI Test Port Injection
- Preferred port key is `SharingPortPreferenceKeys.preferredPort` (`sharing.preferredPort`).
- For UI tests, inject with launch arguments: `-sharing.preferredPort <port>`.
- Do not write port value through hard-coded suite names in UI tests.

## AI Agent Temporary Workspace
- Put all AI-generated temp files/logs/artifacts under `.ai-tmp/`.
- Use isolated subdirectories under `.ai-tmp/`.
- Do not create ad-hoc temp dirs at repo root unless explicitly requested.

## AI Agent Plan Framing
- When the user asks for a plan, treat it as an execution plan for the AI agent unless the user explicitly assigns a human executor.
- Write plan steps from the agent's perspective.
- Do not frame the plan around human task management, personal schedules, or manual execution expectations unless the user explicitly asks for that format.
- If timing is needed, describe agent-relevant sequencing or wait states, such as build time, network latency, review gates, or external blocking conditions.
- If the user goal or instruction is ambiguous, do not guess. Ask for clarification promptly before continuing.
- Clarification questions must include all reasonable current interpretations from the agent, so the user can confirm or correct them directly.

## Execution Mode Recommendation
- Provide an execution mode recommendation before starting implementation work on an actionable request whenever there is a meaningful choice between immediate execution and plan-first handling.
- Do not provide this recommendation in completion handoff, commit summaries, verification summaries, or meta discussions about process, prompts, or repository policy.
- For analysis-only or question-only requests, do not provide this recommendation while the turn remains analysis-only.
- If the turn changes from analysis, diagnosis, review, or explanation into proposed implementation, code modification, or execution of fixes, re-evaluate and provide an execution mode recommendation before the first implementation step unless the user has already explicitly chosen a mode.
- For code review requests with actionable findings, append exactly one execution mode recommendation after the findings summary.
- Treat an explicit mode choice as a direct statement about the mode itself, for example `直接执行`, `现在改`, `先实现`, `开启计划模式`, `先给计划`, or another equally explicit instruction about execution style.
- Do not treat short confirmations such as `要`, `继续`, `看看`, `查一下`, `修吧`, or agreement with a diagnosis as an explicit mode choice. These confirm the task and still require the agent to decide whether an execution mode recommendation is needed.
- Once implementation has started in the current turn, stop emitting execution mode recommendations for that turn.
- Starting implementation means making code or config edits, creating a branch for the task, running modification-oriented commands, or presenting a concrete change plan that the agent is about to execute immediately.
- Use `建议：直接执行` only when implementation has not started, scope is clear, affected area is bounded, validation path is clear, and there is no material decision gate.
- Use `建议：开启计划模式` only when implementation has not started and the task is ambiguous, cross-module, high-risk, multi-stage, blocked by unknowns, or depends on user choice between materially different options.
- Keep the recommendation to one sentence and state the concrete reason.

## Code Review Output Policy
- When review finds an issue, identify the root cause and provide a root-cause fix plan by default.
- Always include a structural refactor assessment: whether it is needed, expected benefits, risks, and validation impact.
- Provide a minimal fix option only when the user explicitly asks for it.

## Complexity and Size Guardrail
- Default goal: solve problems without increasing code complexity and code size.
- If that is not feasible, lower complexity first.
- Reject temporary fixes, glue code, and patch-style handling. Solve the root problem with a clean structural change.
- Do not add transitional adapters, one-off shims, or workaround layers unless the user explicitly requires them for a defined migration window.
- Do not preserve backward compatibility by default. Only keep it when explicitly required, and document the caller, removal condition, and validation impact in the handoff.
- Prefer deleting duplicate branches and duplicate checks.
- Keep equivalent validation at one convergence layer. Avoid multi-layer duplicate defense.
- When adding defensive branches, prioritize deleting equivalent legacy branches in the same module.

## Multilingual Content
- Multilingual support requirement applies only to product software code and app-facing content in this repository.
- Repository policy and workflow documents are out of scope for this rule, including `AGENTS.md` and similar docs.
- Logs, diagnostics, and similar runtime output are exempt from multilingual requirements.
- After changing code that affects app-facing text/content, explicitly verify whether localization resources need updates, and complete required localization updates before handoff.
- If `Localizable.xcstrings` is modified by Xcode as a side effect of your code changes, treat it as required change output from the same task and include it in the same commit, even when you did not edit it manually.

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
