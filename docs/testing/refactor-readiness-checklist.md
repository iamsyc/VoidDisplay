# Refactor Readiness Checklist

## Required Gate

1. `scripts/test/unit_gate.sh` passes locally.
2. `scripts/test/coverage_guard.sh` passes against `docs/testing/coverage-baseline.json`.
3. CI `Unit Tests` workflow is green.

## Informational Gate

1. CI `UI Smoke Tests` is non-blocking.
2. If UI smoke fails, inspect `ui-smoke-summary` artifact first.
3. Classify failures as one of:
   - `runner_bootstrap_failure`
   - `environment_unstable`
   - `assertion_failure`
   - `unknown_failure`

## Refactor PR Requirements

1. Every refactor PR references updated test coverage in touched areas.
2. If behavior changes intentionally, tests are updated in the same PR.
3. For any new regression fixed, add or update a deterministic unit test.
