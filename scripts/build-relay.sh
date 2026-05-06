#!/bin/zsh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RELAY_DIR="$REPO_ROOT/Tools/VoidDisplayRelay"
TARGET_DIR="${TARGET_BUILD_DIR:-$REPO_ROOT/.build/debug}"
case "$TARGET_DIR" in
  /*) ;;
  *) TARGET_DIR="$REPO_ROOT/$TARGET_DIR" ;;
esac
OUTPUT_DIR="$TARGET_DIR/${UNLOCALIZED_RESOURCES_FOLDER_PATH:-}"
OUTPUT_PATH="$OUTPUT_DIR/voiddisplay-relay"
GOPROXY_VALUE="${GOPROXY:-direct}"

resolve_target_arch() {
  local arch="${CURRENT_ARCH:-}"
  if [[ -z "$arch" || "$arch" == "undefined_arch" ]]; then
    if [[ -n "${ARCHS:-}" ]]; then
      local -a arch_values
      arch_values=(${=ARCHS})
      if (( ${#arch_values[@]} > 0 )); then
        arch="${arch_values[1]}"
      fi
    fi
  fi

  if [[ -z "$arch" || "$arch" == "undefined_arch" ]]; then
    arch="$(uname -m)"
  fi

  print -r -- "$arch"
}

relay_arch_for_target_arch() {
  local target_arch="$1"
  case "$target_arch" in
    arm64|arm64e)
      print -r -- "arm64"
      ;;
    x86_64)
      print -r -- "x86_64"
      ;;
    *)
      echo "error: unsupported relay target architecture: $target_arch" >&2
      exit 1
      ;;
  esac
}

goarch_for_relay_arch() {
  local relay_arch="$1"
  case "$relay_arch" in
    arm64)
      print -r -- "arm64"
      ;;
    x86_64)
      print -r -- "amd64"
      ;;
    *)
      echo "error: unsupported Go relay architecture: $relay_arch" >&2
      exit 1
      ;;
  esac
}

validate_relay_binary() {
  local expected_arch="$1"
  if [[ ! -f "$OUTPUT_PATH" ]]; then
    echo "error: relay binary was not produced: $OUTPUT_PATH" >&2
    exit 1
  fi
  if [[ ! -x "$OUTPUT_PATH" ]]; then
    echo "error: relay binary is not executable: $OUTPUT_PATH" >&2
    exit 1
  fi
  if ! command -v lipo >/dev/null 2>&1; then
    echo "error: lipo executable not found; cannot validate relay architecture." >&2
    exit 1
  fi

  local actual_archs
  actual_archs="$(lipo -archs "$OUTPUT_PATH")"
  if [[ "$actual_archs" != "$expected_arch" ]]; then
    echo "error: relay architecture mismatch. Expected $expected_arch, got $actual_archs." >&2
    exit 1
  fi
}

if [[ -z "${GO_BIN:-}" ]]; then
  for candidate in "$(command -v go || true)" /opt/homebrew/bin/go /usr/local/bin/go; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
      GO_BIN="$candidate"
      break
    fi
  done
fi

if [[ -z "${GO_BIN:-}" ]]; then
  echo "error: go executable not found. Install Go or set GO_BIN." >&2
  exit 1
fi

TARGET_ARCH="$(resolve_target_arch)"
RELAY_ARCH="$(relay_arch_for_target_arch "$TARGET_ARCH")"
GOARCH_VALUE="$(goarch_for_relay_arch "$RELAY_ARCH")"

mkdir -p "$OUTPUT_DIR"
cd "$RELAY_DIR"

env GOPROXY="$GOPROXY_VALUE" "$GO_BIN" test ./...
env GOPROXY="$GOPROXY_VALUE" GOOS=darwin GOARCH="$GOARCH_VALUE" "$GO_BIN" build -trimpath -o "$OUTPUT_PATH" ./cmd/voiddisplay-relay
chmod +x "$OUTPUT_PATH"
validate_relay_binary "$RELAY_ARCH"
