# CI Workflows

## Overview

VoidDisplay uses one branch protection check: `ci-gate`.

The workflow set is:

- `.github/workflows/ci.yml`
- `.github/workflows/_reusable-unit-tests.yml`
- `.github/workflows/_reusable-ui-smoke-tests.yml`
- `.github/workflows/nightly.yml`
- `.github/workflows/release.yml`
- `.github/workflows/codeql.yml`
- `.github/workflows/ui-smoke-dispatch.yml`

The repository uses GitHub Free compatible capabilities only: standard macOS hosted runners, Dependabot, Dependency Review, CodeQL, release artifacts, and artifact attestations. Larger runners, self-hosted runners, paid scanning services, Developer ID signing, notarization, and stapling are out of scope.

Xcode selection prefers the Xcode `26.5.0` installation and requires `xcodebuild` version prefix `26.5` with Swift `6.x` by default. Set `EXPECTED_XCODE_VERSION_PREFIX` only for an intentional temporary override.

## Branch Protection Gate

Branch protection for `main` should require only:

- `ci-gate`

Gate behavior:

- Non-code PRs pass through the fast path.
- Code-relevant PRs run static checks, SwiftPM unit tests, Go unit tests, and Xcode Debug build.
- UI-relevant PRs run the UI smoke matrix.
- Code-relevant PRs targeting `main` also run arm64 release smoke. Main push, nightly, and release workflows cover x86_64 release smoke.
- Code PRs run Dependency Review and block high or critical dependency vulnerabilities.

PR CI executes scripts from the checked-out PR head. Script and workflow integrity is enforced by code review plus `script-static-checks`; `ci-gate` remains the single required branch protection check. PR CI checkouts do not persist credentials, and bootstrap steps do not expose `GITHUB_TOKEN` to checked-out repository scripts.

## Local Entrypoints

Install tools:

```sh
scripts/dev/bootstrap.sh
scripts/dev/doctor.sh
```

Common gates:

```sh
scripts/dev/validate.sh
scripts/ci/static.sh
scripts/ci/unit.sh
scripts/ci/xcode.sh --action build --configuration Debug
scripts/ci/xcode.sh --action test --configuration Debug \
  --only-testing VoidDisplayUITests/HomeSmokeTests/testHomeNavigationSmoke_baseline
scripts/ci/ui_smoke.sh \
  --only-testing VoidDisplayUITests/HomeSmokeTests/testHomeNavigationSmoke_baseline
scripts/ci/release_smoke.sh --arch arm64 --label arm64
scripts/ci/full_regression.sh --out-dir .ai-tmp/full-regression
scripts/ci/coverage.sh --out-dir .ai-tmp/coverage
```

`scripts/dev/validate.sh` is the local validation entrypoint for normal development. It runs static checks, SwiftPM unit tests, Go unit tests, Xcode Debug build, and the default UI smoke test through the same scripts CI uses. It defaults the Xcode destination from the host architecture; pass `--destination` to override it, or `--skip-ui-smoke` only when local macOS UI automation authorization is unavailable and report that as an environment limitation.

The shared Xcode `VoidDisplay` scheme is the app build/run and UI test scheme. Cmd-U does not run SwiftPM tests from `Tests/`; use `scripts/dev/validate.sh` or `scripts/ci/unit.sh` for unit coverage.

`scripts/ci/xcode.sh --action test` requires `--only-testing` or `--test-plan`.

## Static Gate

`scripts/ci/static.sh` runs:

- `actionlint`
- paid runner label check
- 40-character action SHA pin check
- `shellcheck`
- `shfmt -d`
- `bash -n`
- `zsh -n`
- `swiftformat --lint`
- `swiftlint lint`
- SwiftPM/Xcode log scanner fixtures
- Swift script typecheck for release helper scripts

All external action references must use a full 40-character commit SHA. Keep a tag comment after the SHA for maintainability, for example:

```yaml
uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6
```

## Release Verification

Release builds are ad hoc signed only. They are not Developer ID signed, notarized, stapled, or certified by Apple.

Release workflow first resolves the target SHA without checking out target code, then verifies that SHA has a successful `ci-gate`. After that gate passes, release jobs execute scripts from the checked-out target commit and use JSON summaries and outputs to decide whether build and publish jobs should run.

Before build or publish jobs run, the release workflow verifies the target commit has a successful `ci-gate` check with inline GitHub API logic that does not execute target checkout scripts. Missing, pending, failed, cancelled, or inaccessible gate state stops the release and writes a JSON summary.

Release assets per architecture:

- `VoidDisplay-vX.Y.Z-arm64.dmg`
- `VoidDisplay-vX.Y.Z-arm64.dmg.sha256`
- `VoidDisplay-vX.Y.Z-arm64.dmg.spdx.json`
- `VoidDisplay-vX.Y.Z-arm64.dmg.summary.json`
- `VoidDisplay-vX.Y.Z-arm64.dmg.verify-summary.json`
- `VoidDisplay-vX.Y.Z-intel64.dmg`
- `VoidDisplay-vX.Y.Z-intel64.dmg.sha256`
- `VoidDisplay-vX.Y.Z-intel64.dmg.spdx.json`
- `VoidDisplay-vX.Y.Z-intel64.dmg.summary.json`
- `VoidDisplay-vX.Y.Z-intel64.dmg.verify-summary.json`

Verify a downloaded asset set:

```sh
scripts/release/verify.sh \
  --assets-dir release-assets \
  --tag vX.Y.Z \
  --label arm64 \
  --arch arm64 \
  --repository iamsyc/VoidDisplay \
  --require-attestation true
```

`verify.sh` checks checksum, DMG mountability, bundle id, version, architecture, ad hoc codesign, SBOM JSON, and GitHub attestation when requested.

## Nightly

`nightly.yml` calls `scripts/ci/full_regression.sh`, `scripts/ci/coverage.sh`, expanded UI smoke, and dual-architecture release dry run. It writes workflow summary output and retains artifacts for 7 days.
