# CI Workflows

## Overview

The repository CI uses a single orchestrator workflow (`CI`) with reusable sub-workflows:

- `.github/workflows/ci.yml`
- `.github/workflows/_reusable-unit-tests.yml`
- `.github/workflows/_reusable-ui-smoke-tests.yml`

The `CI` workflow runs unit tests and UI smoke tests, writes a summary, and exposes a dedicated gate job (`ci-gate`) for branch protection.
UI smoke is executed as a 3-case matrix:

- `baseline`
- `permissionDenied`
- `rebuildFailed`

Default Xcode selection in reusable workflows prefers:

- `/Applications/Xcode_26.2.app/Contents/Developer`
- fallback: `/Applications/Xcode.app/Contents/Developer`

## Branch Protection Gate

Branch protection for `main` should require only:

- `ci-gate`

Gate semantics:

- For `pull_request` targeting `main`: `unit-tests` and `ui-smoke-tests` (matrix aggregate) must both succeed
- For other events (`pull_request` not targeting `main`, `push`, `merge_group`): only `unit-tests` drives `ci-gate`; `ui-smoke-tests` is informational

UI smoke failure behavior:

- `assertion_failure` and `unknown_failure` fail immediately
- `runner_bootstrap_failure` and `environment_unstable` can retry up to `max_attempts`
- If retries are exhausted, status is kept as `ui_status=unstable`; when enforcement is on, job result is failure

## Manual UI Smoke Run

Use `.github/workflows/ui-smoke-dispatch.yml` (`UI Smoke Dispatch`) for manual debugging runs.

Supported inputs:

- `only_testing` (default: `VoidDisplayUITests/HomeSmokeTests/testHomeNavigationSmoke_baseline`)
- `max_attempts` (default: `2`)

This manual workflow preserves real pass/fail behavior for UI smoke diagnostics.
