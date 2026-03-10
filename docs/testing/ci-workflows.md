# CI Workflows

## Overview

The repository CI uses a single orchestrator workflow (`CI`) with reusable sub-workflows:

- `.github/workflows/ci.yml`
- `.github/workflows/_reusable-unit-tests.yml`
- `.github/workflows/_reusable-ui-smoke-tests.yml`

The `CI` workflow runs unit tests and UI smoke tests, writes a summary, and exposes a dedicated gate job (`ci-gate`) for branch protection.
All pull requests trigger the `CI` workflow. Whether heavier checks actually run is decided by an early change-classification step so non-code PRs can still satisfy branch protection.
UI smoke is executed as a 3-case matrix:

- `baseline`
- `permissionDenied`
- `rebuildFailed`

The repository does not use GitHub merge queue. `merge_group` is intentionally out of scope for this workflow design.

Default Xcode selection is centralized in `.github/actions/xcode-select` and prefers:

- `/Applications/Xcode_26.2.app/Contents/Developer`
- fallback: `/Applications/Xcode.app/Contents/Developer`

## Branch Protection Gate

Branch protection for `main` should require only:

- `ci-gate`

Gate semantics:

- For `pull_request` targeting `main` with code-relevant changes: `unit-tests`, `ui-smoke-tests` (matrix aggregate), and `release-build-check` must all succeed
- For `pull_request` with non-code changes only: heavy checks are skipped and `ci-gate` succeeds through the non-code fast-path
- For code-relevant `pull_request` not targeting `main`: only `unit-tests` runs and drives `ci-gate`
- For code-relevant `push` to `main`: only `unit-tests` runs and drives `ci-gate`

UI smoke failure behavior:

- `assertion_failure` and `unknown_failure` fail immediately
- `runner_bootstrap_failure` and `environment_unstable` can retry up to `max_attempts`
- If retries are exhausted, status is kept as `ui_status=unstable`; when enforcement is on, job result is failure

Release build check behavior:

- `release-build-check` runs only on PRs targeting `main` with code-relevant changes
- It performs an unsigned `Release` build for `arm64`
- It does not package DMG and does not publish artifacts

Unit coverage guard behavior:

- `unit-tests` only runs `VoidDisplayTests`
- Coverage gating is based on behavior-layer tracked files plus their weighted aggregate coverage
- Repository-wide `VoidDisplay.app` line coverage is reported for trend visibility
- Repository-wide `VoidDisplay.app` line coverage is not a blocking threshold in the unit-only workflow
- Large SwiftUI view files are excluded from the unit coverage hard gate unless they expose directly testable behavior logic

## Change Classification

The `classify-changes` job decides whether a PR is `code` or `non_code`.
It exists so non-code PRs still produce a successful `ci-gate` result under branch protection.

Code-relevant paths:

- `VoidDisplay/**`
- `VoidDisplayTests/**`
- `VoidDisplayUITests/**`
- `VoidDisplay.xcodeproj/**`
- `scripts/**`
- `.github/workflows/**`
- `.github/actions/**`
- `docs/testing/coverage-baseline.json`

Default non-code examples:

- `AGENTS.md`
- `Readme.md`
- `docs/**` except `docs/testing/coverage-baseline.json`
- `LICENSE`
- `LICENSE_CGVirtualDisplay`

For non-code pull requests:

- `unit-tests` is skipped
- `ui-smoke-tests` is skipped
- `release-build-check` is skipped
- `ci-gate` passes so the PR remains mergeable under branch protection

Why `pull_request` has no `paths` filter:

- Branch protection requires `ci-gate` on every PR
- If `pull_request.paths` filtered out documentation-only PRs, the workflow would never start and `ci-gate` would remain missing
- `push` still uses `paths` filtering because it does not participate in PR branch protection

## Manual UI Smoke Run

Use `.github/workflows/ui-smoke-dispatch.yml` (`UI Smoke Dispatch`) for manual debugging runs.

Supported inputs:

- `only_testing` (default: `VoidDisplayUITests/HomeSmokeTests/testHomeNavigationSmoke_baseline`)
- `max_attempts` (default: `2`)

This manual workflow is the intended entry point for ad hoc UI smoke diagnostics outside the `main` merge path.
