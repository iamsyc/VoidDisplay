#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
XCSTRINGS="$ROOT_DIR/FreelyDisplay/Resources/Localizable.xcstrings"
OUT_FILE="$ROOT_DIR/docs/localization-audit-latest.md"

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required but not installed." >&2
  exit 1
fi

if [[ ! -f "$XCSTRINGS" ]]; then
  echo "Missing Localizable.xcstrings: $XCSTRINGS" >&2
  exit 1
fi

MISSING_ZH=$(
  jq -r '
    .strings
    | to_entries[]
    | select(.key != "")
    | select((.value.localizations["zh-Hans"] // null) == null)
    | .key
  ' "$XCSTRINGS" | sort -u
)

STALE_KEYS=$(
  jq -r '
    .strings
    | to_entries[]
    | select(.value.extractionState? == "stale")
    | .key
  ' "$XCSTRINGS" | sort -u
)

UI_REGEX='Text\("[^"]+"\)|Button\("[^"]+"|Label\("[^"]+"|navigationTitle\("[^"]+"|ContentUnavailableView\("[^"]+"|alert\("[^"]+"|help\("[^"]+"'
if command -v rg >/dev/null 2>&1; then
  HARD_CODED=$(
    rg -n --glob '*.swift' "$UI_REGEX" "$ROOT_DIR/FreelyDisplay" \
      | sed "s|$ROOT_DIR/||"
  )
else
  HARD_CODED=$(
    grep -RInE --include='*.swift' "$UI_REGEX" "$ROOT_DIR/FreelyDisplay" \
      | sed "s|$ROOT_DIR/||"
  )
fi

MISSING_COUNT=$(printf "%s\n" "$MISSING_ZH" | sed '/^$/d' | wc -l | tr -d ' ')
STALE_COUNT=$(printf "%s\n" "$STALE_KEYS" | sed '/^$/d' | wc -l | tr -d ' ')
HARD_CODED_COUNT=$(printf "%s\n" "$HARD_CODED" | sed '/^$/d' | wc -l | tr -d ' ')

NOW=$(date '+%Y-%m-%d %H:%M:%S %z')

{
  echo "# Localization Audit Report"
  echo
  echo "- Generated at: $NOW"
  echo "- Missing zh-Hans keys: $MISSING_COUNT"
  echo "- Stale extraction keys: $STALE_COUNT"
  echo "- Potential hard-coded UI strings (regex-based): $HARD_CODED_COUNT"
  echo

  echo "## Missing zh-Hans Keys"
  if [[ -n "$(printf "%s" "$MISSING_ZH" | sed '/^$/d')" ]]; then
    echo '```text'
    printf "%s\n" "$MISSING_ZH"
    echo '```'
  else
    echo "None."
  fi
  echo

  echo "## Stale Keys"
  if [[ -n "$(printf "%s" "$STALE_KEYS" | sed '/^$/d')" ]]; then
    echo '```text'
    printf "%s\n" "$STALE_KEYS"
    echo '```'
  else
    echo "None."
  fi
  echo

  echo "## Potential Hard-Coded UI Strings"
  echo "Note: this section is regex-based and may include false positives."
  if [[ -n "$(printf "%s" "$HARD_CODED" | sed '/^$/d')" ]]; then
    echo '```text'
    printf "%s\n" "$HARD_CODED"
    echo '```'
  else
    echo "None."
  fi
} > "$OUT_FILE"

echo "Localization audit written to: $OUT_FILE"
