#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib/contract.sh
source "${BASH_SOURCE[0]%/*}/../lib/contract.sh"
# shellcheck source=scripts/lib/common.sh
source "$TOOL_ROOT/scripts/lib/common.sh"

RELAY_DIR="$ROOT_DIR/Tools/VoidDisplayRelay"
GOPROXY_VALUE="${GOPROXY:-https://proxy.golang.org|https://goproxy.cn|direct}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"

if ! [[ "$MAX_ATTEMPTS" =~ ^[0-9]+$ ]] || [ "$MAX_ATTEMPTS" -lt 1 ]; then
	echo "Invalid MAX_ATTEMPTS=${MAX_ATTEMPTS}." >&2
	exit 1
fi

cd "$RELAY_DIR"

for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
	if env GOPROXY="$GOPROXY_VALUE" go mod download; then
		exit 0
	fi

	if [ "$attempt" -eq "$MAX_ATTEMPTS" ]; then
		exit 1
	fi

	sleep "$((attempt * 10))"
done
