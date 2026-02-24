# CI Workflows

## Overview

The repository CI now uses a single orchestrator workflow (`CI`) with reusable sub-workflows:

- `.github/workflows/ci.yml`
- `.github/workflows/_reusable-unit-tests.yml`
- `.github/workflows/_reusable-ui-smoke-tests.yml`

The `CI` workflow runs unit tests and UI smoke tests, writes a summary, and exposes a dedicated gate job (`ci-gate`) for branch protection.

## Branch Protection Gate

Branch protection for `main` should require only:

- `ci-gate`

Gate semantics:

- `unit-tests` is required and drives `ci-gate`
- `ui-smoke-tests` is informational (non-blocking)

## Manual UI Smoke Run

Use `.github/workflows/ui-smoke-dispatch.yml` (`UI Smoke Dispatch`) for manual debugging runs.

Supported inputs:

- `only_testing` (default: `VoidDisplayUITests/HomeSmokeTests/testHomeNavigationSmoke_baseline`)
- `max_attempts` (default: `2`)

This manual workflow preserves real pass/fail behavior for UI smoke diagnostics.
