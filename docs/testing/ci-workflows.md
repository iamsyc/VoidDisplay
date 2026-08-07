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

Xcode selection prefers the Xcode `26.6.0` installation and requires `xcodebuild` version prefix `26.6` with Swift `6.3` by default. Set `EXPECTED_XCODE_VERSION_PREFIX` and `EXPECTED_SWIFT_VERSION_PREFIX` only for an intentional temporary override.

Local command selection and environment-failure handling are documented in [Testing Strategy](./testing-strategy.md). This document covers workflow-side orchestration and release evidence.

## Branch Protection Gate

Branch protection for `main` should require only:

- `ci-gate`

Gate behavior:

- Every PR runs static checks, SwiftPM tests, browser JavaScript tests, Go tests, and an Xcode Debug build.
- UI-relevant PRs and PRs with unknown paths run two balanced UI smoke shards on separate runners. Selectors within each shard execute serially and share one DerivedData directory.
- Release-relevant PRs targeting `main` run arm64 release smoke. Main push, nightly, and release workflows cover x86_64 release smoke.
- PRs that change dependency manifests run Dependency Review and block high or critical dependency vulnerabilities.

PR CI executes scripts from the checked-out PR head. Script and workflow integrity is enforced by code review plus `script-static-checks`; `ci-gate` remains the single required branch protection check. PR CI checkouts do not persist credentials, and bootstrap steps do not expose `GITHUB_TOKEN` to checked-out repository scripts.

## Static Gate

`scripts/ci/static.sh` delegates to shell, workflow, and project checks. The current gate covers:

- Shell syntax, formatting, lint, helper-source paths, and the `ROOT_DIR` / `TOOL_ROOT` execution contract.
- `actionlint`, runner-label policy, 40-character action SHA pins, checkout credential isolation, PR token isolation, UI artifact synchronization, and release gate timeout budgeting.
- Xcode project layout, relay build-phase inputs, unsigned local test builds, and SwiftPM/Xcode diagnostic scanner fixtures.
- Bootstrap profile, change-classification, and release project-path fixtures.
- Swift format and lint, release-helper type checking, browser JavaScript syntax, product source-file size limits, and the UI-test keyboard-input prohibition.

All external action references must use a full 40-character commit SHA. Keep a tag comment after the SHA for maintainability, for example:

```yaml
uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6
```

## Release Verification

Release builds are ad hoc signed only. They are not Developer ID signed, notarized, stapled, or certified by Apple.

Release workflow first resolves the target SHA without checking out target code, then verifies that SHA has a successful `ci-gate` through inline GitHub API logic. Missing, pending, failed, cancelled, or inaccessible gate state stops the release and writes a JSON summary. After the gate passes, release jobs use JSON summaries and outputs to decide whether build and publish jobs should run.

### Trusted Tool And Target Roots

Release jobs use two checkouts:

- `TOOL_ROOT` is the workflow commit at `github.sha`. Release scripts, bootstrap configuration, and the DMG template come from this checkout.
- `ROOT_DIR` is the resolved release target under `release-target`. Product source, project metadata, and the app build come from this checkout.

Every workflow script runs from `TOOL_ROOT` and receives both roots explicitly. A project-managed tool that uses repository configuration must be resolved against `TOOL_ROOT` before `xcodebuild` starts, then passed into Xcode as an absolute path. When mise is available, release smoke resolves Go with `mise -C "$TOOL_ROOT" which go` and passes `GO_BIN` into the `Build Relay` phase. This prevents tool shims from searching the release target for configuration that the Xcode script sandbox cannot read.

Checkpoint resume and Xcode test-product reuse require `ROOT_DIR` and `TOOL_ROOT` to resolve to the same checkout, so the source fingerprint covers the scripts that produced the evidence. Split roots remain limited to release scripts, which do not reuse those artifacts.

### DMG Template Maintenance

`scripts/release/assets/VoidDisplay-template.dmg` is the source of truth for the Finder layout. `create_dmg.sh` converts the template to a writable image, resizes it, validates its contents, replaces the empty app placeholder, and compresses the result.

The template must contain:

- Volume name `VoidDisplay`.
- `.DS_Store` with the Finder layout.
- `.background/background.png`.
- An `Applications` symlink whose target is `/Applications`.
- An empty `VoidDisplay.app` directory used as the app placeholder.

The release path does not generate the background or Finder layout. Change the template only as an explicit maintenance task. Work on a copy under `.ai-tmp/`, preserve the required entries, replace the versioned template after reviewing the mounted layout, then run `scripts/ci/static.sh` and a host-architecture release build plus `scripts/release/verify.sh`. Main CI and the Release workflow provide the final dual-architecture evidence.

The current release workflow publishes this asset set per architecture:

- `VoidDisplay-vX.Y.Z-arm64.dmg`
- `VoidDisplay-vX.Y.Z-arm64.dmg.sha256`
- `VoidDisplay-vX.Y.Z-arm64.dmg.spdx.json`
- `VoidDisplay-vX.Y.Z-arm64.dmg.summary.json`
- `VoidDisplay-vX.Y.Z-arm64.verify-summary.json`
- `VoidDisplay-vX.Y.Z-intel64.dmg`
- `VoidDisplay-vX.Y.Z-intel64.dmg.sha256`
- `VoidDisplay-vX.Y.Z-intel64.dmg.spdx.json`
- `VoidDisplay-vX.Y.Z-intel64.dmg.summary.json`
- `VoidDisplay-vX.Y.Z-intel64.verify-summary.json`

This artifact set applies to releases produced by the current workflow. The `v2.1.0` release predates SBOM and attestation publishing and contains only the DMG and SHA256 checksum for each architecture.

Verify a `v2.1.0` checksum from the directory containing both downloaded files:

```sh
shasum -a 256 -c VoidDisplay-v2.1.0-arm64.dmg.sha256
```

For releases containing the full asset set, download the published files and run both architecture checks:

```sh
release_dir=".ai-tmp/release-readback/vX.Y.Z"
mkdir -p "$release_dir"
gh release download vX.Y.Z --dir "$release_dir"

scripts/release/verify.sh \
  --assets-dir "$release_dir" \
  --tag vX.Y.Z \
  --label arm64 \
  --arch arm64 \
  --repository iamsyc/VoidDisplay \
  --require-attestation true

scripts/release/verify.sh \
  --assets-dir "$release_dir" \
  --tag vX.Y.Z \
  --label intel64 \
  --arch x86_64 \
  --repository iamsyc/VoidDisplay \
  --require-attestation true
```

`verify.sh` checks checksum, DMG mountability, bundle id, version, architecture, ad hoc codesign, SBOM JSON, and GitHub attestation when requested.

### Stable Release Completion

Before reporting a stable release as complete:

1. Confirm the target commit has a successful `ci-gate`.
2. Wait for the Release workflow to finish successfully, including both architecture builds and `publish-github-release`.
3. Confirm the public release is neither a draft nor a prerelease, and resolve the release tag to the target commit.
4. Confirm the public asset list contains the DMG, checksum, SPDX SBOM, build summary, and verification summary for arm64 and Intel.
5. Download the public assets into a fresh directory and run both verification commands above with attestations required.
6. Confirm the source PR is merged. When cleanup was requested, remove the local and remote topic branches.
7. Confirm the local worktree is clean and `git rev-list --left-right --count main...origin/main` reports `0 0`.

Report local verification, main CI, the Release workflow, and public asset readback separately. GitHub-hosted runners build and publish the release packages. Local release builds provide diagnostics or reproduction evidence and are not uploaded.

## Nightly

`nightly.yml` runs four independent lanes: core regression without UI, Xcode Debug preflight, or release packaging; full serial `VoidDisplayUITests`; coverage; and dual-architecture release dry run. The core lane calls `scripts/ci/full_regression.sh --skip-ui-tests --skip-xcode-preflight --skip-release-smoke`; the UI lane's `build-for-testing` owns the Debug app compilation, and the release lane owns arm64 and Intel Release builds. Coverage runs the SwiftPM suite with instrumentation and skips the JavaScript and Go suites already owned by core regression. The UI lane reuses the same DerivedData with `test-without-building`. It covers the complete UI target, including suites outside `HomeSmokeTests`, and retains one sequential full-suite signal for order and shared-state regressions.

PR UI smoke uses two runner shards. The navigation-preview shard covers home navigation and both preview recovery flows. The display-list shard covers the display list surface and narrow-window actions. Each reusable workflow call accepts a JSON selector list and passes every selector to one `xcodebuild` invocation. The UI tests remain serial inside each GUI session while each shard compiles once. The two artifacts are `ui-smoke-navigation-preview` and `ui-smoke-display-list`.

All Nightly lanes start independently. The workflow summary reports core regression and the full UI suite separately, and every artifact is retained for 7 days.

`scripts/ci/full_regression.sh` also calls `scripts/ci/stability.sh`. The stability gate repeats the Swift capture-demand and relay-client churn tests, then runs every relay Go package with the race detector and the same bounded iteration count. Use `--iterations 1...100` or `STABILITY_ITERATIONS` to select the run length; the default is 20.

The current testing layers and local scope rules are documented in [Testing Strategy](./testing-strategy.md).
