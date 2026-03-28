#!/usr/bin/env bash
set -euo pipefail

XCRESULT_PATH=""
LABEL="Test run"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --xcresult)
      XCRESULT_PATH="$2"
      shift 2
      ;;
    --label)
      LABEL="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$XCRESULT_PATH" ]]; then
  echo "Missing required --xcresult argument." >&2
  exit 1
fi

if [[ ! -d "$XCRESULT_PATH" ]]; then
  echo "$LABEL invalid: missing xcresult bundle at $XCRESULT_PATH" >&2
  exit 1
fi

SUMMARY="$(xcrun xcresulttool get test-results summary --path "$XCRESULT_PATH")"

extract_metric() {
  local key="$1"
  local fallback="$2"
  local line value
  if command -v rg >/dev/null 2>&1; then
    line="$(printf '%s\n' "$SUMMARY" | rg "\"$key\"" | tail -n 1)" || true
  else
    line="$(printf '%s\n' "$SUMMARY" | grep "\"$key\"" | tail -n 1)" || true
  fi
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

TOTAL_TESTS="$(extract_metric totalTestCount 0)"
FAILED_TESTS="$(extract_metric failedTests 0)"
RESULT_STATUS="$(extract_metric result unknown)"

echo "$LABEL summary: result=$RESULT_STATUS totalTestCount=$TOTAL_TESTS failedTests=$FAILED_TESTS"

if [[ "$TOTAL_TESTS" == "0" ]]; then
  echo "$LABEL invalid: totalTestCount == 0 (possible selector mismatch)." >&2
  exit 1
fi
