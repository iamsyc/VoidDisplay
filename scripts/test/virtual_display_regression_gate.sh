#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UNIT_GATE="$ROOT_DIR/scripts/test/unit_gate.sh"
ARTIFACT_ROOT="${ARTIFACT_ROOT:-$ROOT_DIR/.ai-tmp/virtual-display-regression}"
MAX_RETRIES="${MAX_RETRIES:-2}"

run_suite() {
    local suite="$1"
    local log_path="$ARTIFACT_ROOT/${suite}.log"
    local attempt=1
    while true; do
        echo
        echo "==> Running $suite (attempt $attempt/$MAX_RETRIES)"
        if "$UNIT_GATE" \
            --filter "$suite" \
            --log-path "$log_path"; then
            return 0
        fi

        if (( attempt >= MAX_RETRIES )); then
            echo "Suite failed after $attempt attempt(s): $suite" >&2
            return 1
        fi

        echo "Retrying suite after failure: $suite" >&2
        attempt=$((attempt + 1))
    done
}

mkdir -p "$ARTIFACT_ROOT"

run_suite "VirtualDisplayTopologyRecoveryTests"
run_suite "DisplayTeardownCoordinatorOfflineWaitTests"
run_suite "VirtualDisplayControllerTests"

echo
echo "Virtual display regression gate passed."
