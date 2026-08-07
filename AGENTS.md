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
- For release delivery, report main CI, the Release workflow, and public asset readback as separate evidence. Completion requires terminal success for the requested workflow, the release tag at the target commit, every advertised architecture downloaded and verified, and any requested branch cleanup.
- During runner waits, report phase transitions and distinguish external queue or build time from local work. Reuse completed gates while tracked source remains unchanged.

## Exceptions
- If user says stay on current branch / work on `main` / skip PR / skip waiting CI, follow that instruction for this task.

## Skill Routing
- Use the matching installed Waza skill when available. Repository rules remain binding as the project-specific source of truth.

## Swift & SDK Baseline
- Use Swift 6 for all Swift targets and new code.
- Keep deployment target at `15.6` unless user requests otherwise.
- Prefer modern APIs compatible with target `15.6`; avoid deprecated APIs.

## Compatibility and Complexity Guardrail
- Default to the current supported interfaces and behavior.
- Prefer a clean root-cause change that does not increase code complexity or size.
- Do not add temporary fixes, glue code, transitional adapters, one-off shims, workaround layers, fallback branches, or duplicate paths unless a user requirement, external caller, migration window, or release plan requires them.
- Preserve legacy interfaces or behavior only when required. Document the caller, reason, removal condition, and validation impact in the handoff.
- Consolidate equivalent validation at one convergence layer and remove duplicate branches or checks within the affected scope after verifying callers.

## Verification Policy
- Local verification and remote CI are separate evidence surfaces. Report their results independently and never infer one from the other.
- Use repository-owned scripts as the shared gate implementation. Local commands choose host-specific scope and destination; workflows own remote runners, change classification, matrices, artifacts, and required checks.

### Local Verification
- After every code change, run a local build and determine whether related tests must be updated or added. Complete required test changes before handoff.
- Handoff requires zero compile errors and zero compile warnings from every required local gate.
- For a small, bounded change, run the related targeted tests and a host-architecture Debug build:
  - SwiftPM tests: `scripts/ci/unit.sh --filter '<test-filter>'`.
  - Xcode build: `scripts/ci/xcode.sh --action build --configuration Debug --destination "platform=macOS,arch=$(uname -m)"`.
  - Targeted UI test when needed: `scripts/ci/ui_smoke.sh --only-testing '<test-identifier>' --destination "platform=macOS,arch=$(uname -m)"`.
- For broad or high-risk non-UI changes, run `scripts/dev/validate.sh --skip-ui-smoke`.
- For UI changes that require smoke coverage, run `scripts/dev/validate.sh --ui-selector '<test-identifier>'` or the unfiltered `scripts/dev/validate.sh` when its baseline selector covers the change.
- While UI code or UI tests are still changing, run only the affected selector. After tracked source stops changing, run the complete UI target once as the final local gate.
- If the complete UI target exposes one failing selector, repair and repeat that selector first; rerun the complete target only after the targeted failure is green.
- Run `scripts/ci/full_regression.sh --destination "platform=macOS,arch=$(uname -m)"` only when the local machine supports its release targets and the change is broad, release-sensitive, or explicitly requires the full suite.
- If related verification has already completed after the latest code change, and no repo-tracked file has changed since that verification, a later commit-only instruction must reuse the existing fresh verification result instead of rerunning the same tests.
- For small, explicit, low-risk changes with tightly bounded impact, do not run the full `HomeSmokeTests` suite by default. Prefer build-only verification or a narrower targeted test that covers the changed control or flow.
- Full-suite candidates include shared code, dependency or build settings, scripts or test infrastructure, large refactors, concurrency, persistence, network, security, release behavior, and user-requested full verification.
- If the local environment cannot execute a required gate because of architecture, OS, Xcode, signing, or privacy-automation setup, record the missing evidence explicitly. Do not report that gate as passed.
- Permission-sensitive real-app acceptance must use `scripts/dev/build_signed_runtime.sh` and launch the exact `app_path` recorded in `signed-runtime-summary.json`. An Xcode Personal Team `Apple Development` identity is sufficient for this local-only gate; do not use the resulting app in CI, Release, or public distribution.
- If that development identity is unavailable, record the signed acceptance gate as an environment setup failure. Do not substitute an unsigned or ad hoc build, and do not infer privacy-permission behavior from ordinary signing-disabled validation.

### Remote CI Verification
- `.github/workflows/ci.yml` and the reusable workflows it invokes are the source of truth for workflow-side change classification, runner images, job matrices, artifacts, and CI gate coverage.
- Repository rulesets and the live PR check suite determine which checks are externally required.
- CI should call the same repository scripts where practical while supplying remote-only environment setup and orchestration in workflows.
- Do not copy CI-only runner assumptions into local commands or weaken CI to match one developer machine.
- For full PR delivery, follow every required remote check to a terminal result and report failures, skips, cancellations, and environment failures separately.
- Nightly, CodeQL, release, and manually dispatched workflows are additional remote evidence only when the task or delivery policy requires them.

## Test Permission Prompt Isolation
- Automated tests must not introduce product or app code paths that trigger avoidable macOS privacy prompts such as screen recording, microphone, camera, keyboard input, input method, or similar authorization dialogs.
- Any product code path that may request app privacy permissions must switch to a test-specific provider, mock, stub, or equivalent isolation layer under test environments.
- Test code must not rely on a human responding to app-driven privacy prompts, input method prompts, or avoidable local authorization dialogs to complete.
- macOS authorization required by the test harness itself, such as Automation, Accessibility, Input Monitoring, or related administrator approval for UI automation, is environment setup. UI tests may run when this setup is available.
- If a UI test fails, stalls, or times out because test harness authorization is missing or delayed, classify it as an environment setup failure and report it separately from product code or test code failures.
- Reject any test change that can block local or CI execution by introducing new avoidable privacy authorization prompts.

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
- Write plan steps from the agent's perspective and express timing through execution order, wait states, verification gates, and external blockers.
- Resolve ambiguity from repository context when safe. Ask only when different interpretations materially change scope, risk, external writes, or resulting behavior, and state the decisive ambiguity concisely.

## Execution Mode Recommendation
- Add one concise execution-mode recommendation only after a non-implementation response when it gives the user a useful choice for the next turn.
- Omit it during implementation, completion handoff, verification, commits, and discussions about process, prompts, or repository policy.

## Code Review Output Policy
- When review finds an issue, identify the root cause and recommend a clean, bounded root-cause fix.
- Include a structural refactor assessment only when it materially affects fix scope, benefits, risks, or validation.
- Include a minimal alternative when the user requests it or when its tradeoff is necessary for a decision.

## Multilingual Content
- Multilingual support requirement applies only to product software code and app-facing content in this repository.
- Repository policy and workflow documents are out of scope for this rule, including `AGENTS.md` and similar docs.
- Logs, diagnostics, and similar runtime output are exempt from multilingual requirements.
- After changing code that affects app-facing text/content, explicitly verify whether localization resources need updates, and complete required localization updates before handoff.
- If `Localizable.xcstrings` is modified by Xcode as a side effect of your code changes, treat it as required change output from the same task and include it in the same commit, even when you did not edit it manually.

## Xcode Tooling Policy (Token + Reliability First)
- Default to the repository scripts that wrap `xcodebuild`; use raw `xcodebuild` only for targeted diagnostics or capabilities the wrappers do not expose.
- Write verbose logs to `.ai-tmp/` and report concise summaries only.
- When available, use Xcode MCP only for high-value IDE-context tasks:
  - workspace/tab context resolution
  - project graph file operations
  - targeted diagnostics/tests
  - preview/snippet workflows hard to reproduce in shell
- Avoid high-output calls unless necessary (full glob/full test list/full logs).
- Scope early by path/pattern/target/test identifier.
- If MCP shows instability (`Transport closed`, XPC/timeout), switch to shell fallback instead of repeated MCP retries.
- Do not block delivery on MCP instability if equivalent repository-script verification is possible.
