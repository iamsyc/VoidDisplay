#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

SCHEME="${SCHEME:-VoidDisplay}"
PROJECT_PATH="${PROJECT_PATH:-$ROOT_DIR/VoidDisplay.xcodeproj}"
DESTINATION="${DESTINATION:-platform=macOS}"
ARTIFACT_ROOT="${ARTIFACT_ROOT:-$ROOT_DIR/.ai-tmp/codex-tmp/regression-results}"

TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="$ARTIFACT_ROOT/$TS"
mkdir -p "$OUT_DIR"

TEST_RESULT="$OUT_DIR/full-project-regression.xcresult"
TEST_LOG="$OUT_DIR/full-project-regression.log"
DEBUG_LOG="$OUT_DIR/build-debug.log"
RELEASE_LOG="$OUT_DIR/build-release.log"

info() { printf '[INFO] %s\n' "$*"; }
error() { printf '[ERROR] %s\n' "$*" >&2; }

extract_metric() {
  local key="$1"
  local fallback="$2"
  local line value
  line="$(printf '%s\n' "$SUMMARY" | rg "\"$key\"" | tail -n 1)" || true
  if [[ -z "$line" ]]; then
    printf '%s' "$fallback"
    return 0
  fi
  value="$(printf '%s\n' "$line" | awk -F': ' '{print $2}' | tr -d ',\"')"
  if [[ -z "$value" ]]; then
    printf '%s' "$fallback"
  else
    printf '%s' "$value"
  fi
}

info "Workspace: $ROOT_DIR"
info "Artifacts: $OUT_DIR"

info "Step 1/4: Full test regression (including UI tests)"
set +e
xcodebuild test \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -destination "$DESTINATION" \
  -resultBundlePath "$TEST_RESULT" >"$TEST_LOG" 2>&1
TEST_STATUS=$?
set -e

if [[ ! -d "$TEST_RESULT" ]]; then
  error "Missing xcresult bundle: $TEST_RESULT"
  exit 1
fi

SUMMARY="$(xcrun xcresulttool get test-results summary --path "$TEST_RESULT")"
TOTAL="$(extract_metric totalTestCount 0)"
PASSED="$(extract_metric passedTests 0)"
FAILED="$(extract_metric failedTests 0)"
SKIPPED="$(extract_metric skippedTests 0)"
RESULT="$(extract_metric result unknown)"

printf '\n=== Test Summary ===\n'
printf 'result: %s\n' "$RESULT"
printf 'totalTestCount: %s\n' "$TOTAL"
printf 'passedTests: %s\n' "$PASSED"
printf 'failedTests: %s\n' "$FAILED"
printf 'skippedTests: %s\n' "$SKIPPED"
printf 'xcresult: %s\n' "$TEST_RESULT"
printf 'log: %s\n' "$TEST_LOG"

if [[ "$TOTAL" == "0" ]]; then
  error "Invalid run: totalTestCount == 0 (fake green)."
  exit 1
fi

if [[ $TEST_STATUS -ne 0 || "$FAILED" != "0" ]]; then
  error "Test regression failed. Last log lines:"
  tail -n 120 "$TEST_LOG" || true
  printf '\n=== Failure Summary ===\n'
  printf '%s\n' "$SUMMARY" | rg -n '"failureText"|"testIdentifierString"|"testName"'
  exit 1
fi

info "Step 2/4: Debug build"
xcodebuild build \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -destination "$DESTINATION" >"$DEBUG_LOG" 2>&1

info "Step 3/4: Release build"
xcodebuild build \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination "$DESTINATION" >"$RELEASE_LOG" 2>&1

WARN_DEBUG="$(rg -n 'warning:' "$DEBUG_LOG" || true)"
WARN_RELEASE="$(rg -n 'warning:' "$RELEASE_LOG" || true)"

printf '\n=== Build Summary ===\n'
printf 'debug log: %s\n' "$DEBUG_LOG"
printf 'release log: %s\n' "$RELEASE_LOG"

if [[ -n "$WARN_DEBUG" || -n "$WARN_RELEASE" ]]; then
  error "Build warnings detected."
  if [[ -n "$WARN_DEBUG" ]]; then
    printf '\n--- Debug warnings ---\n%s\n' "$WARN_DEBUG"
  fi
  if [[ -n "$WARN_RELEASE" ]]; then
    printf '\n--- Release warnings ---\n%s\n' "$WARN_RELEASE"
  fi
  exit 1
fi

info "Step 4/4: Gate passed (tests + builds + zero warnings)"
printf '\nPASS: full regression gate succeeded.\n'
