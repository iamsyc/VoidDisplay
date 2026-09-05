#!/usr/bin/env bash
set -euo pipefail

# Real native acceptance, intentionally separate from automated unit/UI tests.
# Creates temporary displays without changing saved app configuration.
# shellcheck source=scripts/lib/contract.sh
source "${BASH_SOURCE[0]%/*}/../lib/contract.sh"
# shellcheck source=scripts/lib/common.sh
source "$TOOL_ROOT/scripts/lib/common.sh"
# shellcheck source=scripts/lib/artifacts.sh
source "$TOOL_ROOT/scripts/lib/artifacts.sh"

SUMMARY="${1:?Usage: verify_display_host.sh signed-runtime-summary.json [output-directory]}"
OUT_DIR="${2:-$(make_artifact_dir display-host-acceptance)}"
mkdir -p "$OUT_DIR"
require_command jq xcrun codesign
APP_PATH="$(jq -er 'select(.status == "passed") | .app_path' "$SUMMARY")"
HOST_PATH="$APP_PATH/Contents/MacOS/VoidDisplayHost"
[[ -x "$HOST_PATH" ]] || die "Signed display host is missing: $HOST_PATH"
codesign --verify --deep --strict "$APP_PATH"
host_signature="$(codesign -dv --verbose=4 "$HOST_PATH" 2>&1)"
rg -q '^Authority=Apple Development:' <<<"$host_signature" ||
	die "Native acceptance requires an Apple Development signed host."

cat >"$OUT_DIR/InspectDisplays.swift" <<'SWIFT'
import CoreGraphics
import Foundation
var count: UInt32 = 0
CGGetOnlineDisplayList(0, nil, &count)
var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
CGGetOnlineDisplayList(count, &ids, &count)
let result = ids.prefix(Int(count)).map { id -> [String: Any] in
    var data: [String: Any] = ["displayID": id, "serial": CGDisplaySerialNumber(id), "isMain": CGDisplayIsMain(id) != 0]
    if let mode = CGDisplayCopyDisplayMode(id) {
        data.merge(["width": mode.width, "height": mode.height, "pixelWidth": mode.pixelWidth,
                    "pixelHeight": mode.pixelHeight, "refreshRate": mode.refreshRate]) { _, value in value }
    }
    return data
}
print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
SWIFT
xcrun swiftc -swift-version 6 "$OUT_DIR/InspectDisplays.swift" -o "$OUT_DIR/inspect-displays"
xcrun python3 - "$HOST_PATH" "$OUT_DIR" <<'PY'
import json, pathlib, selectors, subprocess, sys, time
host, out = sys.argv[1], pathlib.Path(sys.argv[2])
def inspect():
    return sorted(json.loads(subprocess.check_output([str(out / 'inspect-displays')], text=True)), key=lambda d: d['displayID'])
def line_with_timeout(process):
    with selectors.DefaultSelector() as selector:
        selector.register(process.stdout, selectors.EVENT_READ)
        assert selector.select(5), 'Host readiness timed out'
        return json.loads(process.stdout.readline())
def wait_for_baseline():
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        if inspect() == baseline:
            return
        time.sleep(.1)
    raise AssertionError('Temporary display remained online or original displays changed')
def request(hidpi=False, hz=60, large=False):
    return dict(name='VoidDisplay native acceptance', serialNumber=4000932,
                physicalSize=[531, 299] if large else [310, 174],
                maximumPixelDimensions=dict(width=3840 if hidpi else 1920, height=2160 if hidpi else 1080),
                modes=[dict(width=1920, height=1080, refreshRate=hz, isHiDPI=hidpi)])
def check_ready(ready, hidpi, hz):
    display_id = ready['ready']['displayID']
    displays = inspect()
    actual = next(d for d in displays if d['displayID'] == display_id)
    assert (actual['width'], actual['height']) == (1920, 1080), actual
    assert (actual['pixelWidth'], actual['pixelHeight']) == ((3840, 2160) if hidpi else (1920, 1080)), actual
    assert round(actual['refreshRate']) == round(hz), actual
    assert [d for d in displays if d['displayID'] != display_id] == baseline
    return actual
baseline = inspect()
assert not any(d['serial'] == 4000932 for d in baseline), 'Acceptance serial is already in use'
results = []
children = []
try:
    for hidpi, hz, large, shutdown in [(False, 60, False, 'eof'), (True, 60, False, 'eof'),
                                      (False, 60, False, 'eof'), (False, 59.94, False, 'eof'),
                                      (False, 120, True, 'terminate')]:
        child = subprocess.Popen([host], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        children.append(child)
        child.stdin.write(json.dumps(request(hidpi, hz, large)) + '\n')
        child.stdin.flush()
        actual = check_ready(line_with_timeout(child), hidpi, hz)
        start = time.monotonic()
        if shutdown == 'terminate':
            child.terminate()
        child.stdin.close()
        child.wait(timeout=5)
        if shutdown == 'eof':
            assert child.returncode == 0, child.returncode
        wait_for_baseline()
        results.append(dict(hidpi=hidpi, hz=hz, shutdown=shutdown, child_exit=child.returncode, actual=actual,
                            cleanup_seconds=round(time.monotonic()-start, 3)))
    # The intermediate parent exits without shutting down its child explicitly.
    parent_code = '''import json, subprocess, sys
child = subprocess.Popen([sys.argv[1]], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
child.stdin.write(sys.stdin.readline()); child.stdin.flush()
print(child.stdout.readline(), end='', flush=True)
sys.stdin.readline()
'''
    parent = subprocess.Popen([sys.executable, '-c', parent_code, host], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    children.append(parent)
    parent.stdin.write(json.dumps(request()) + '\n'); parent.stdin.flush()
    actual = check_ready(line_with_timeout(parent), False, 60)
    start = time.monotonic()
    parent.stdin.close(); parent.wait(timeout=5)
    wait_for_baseline()
    results.append(dict(shutdown='parent_exit', actual=actual, cleanup_seconds=round(time.monotonic()-start, 3)))
finally:
    for child in children:
        if child.poll() is None:
            child.terminate()
            child.wait(timeout=5)
    (out / 'native-acceptance.json').write_text(json.dumps(dict(baseline=baseline, scenarios=results, final=inspect()), indent=2))
print(f'Native display host acceptance: {len(results)}/6 passed; original displays unchanged.')
PY
