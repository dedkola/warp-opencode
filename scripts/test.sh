#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MODE="xctest"
case "${1:-}" in
  "") ;;
  --portable) MODE="portable" ;;
  -h|--help)
    echo "Usage: scripts/test.sh [--portable]"
    echo "Default: normal XCTest via swift test (requires full Xcode)."
    echo "--portable: run the same test bodies with a small assertion adapter using Command Line Tools."
    echo "Fetches the verified pinned cloudflared helper unless WARP_GO_CLOUDFLARED_PATH is supplied."
    exit 0 ;;
  *) echo "Unknown argument: $1" >&2; exit 1 ;;
esac
if [[ $# -gt 1 ]]; then echo "Unexpected extra arguments." >&2; exit 1; fi

if [[ -z "${WARP_GO_CLOUDFLARED_PATH:-}" ]]; then
  WARP_GO_CLOUDFLARED_PATH="$("$ROOT/scripts/fetch-cloudflared.sh")"
  export WARP_GO_CLOUDFLARED_PATH
elif [[ ! -x "$WARP_GO_CLOUDFLARED_PATH" ]]; then
  echo "WARP_GO_CLOUDFLARED_PATH must point to an executable cloudflared helper." >&2
  exit 1
fi
if [[ "$MODE" == "xctest" ]]; then exec swift test; fi

CLT_ROOT="/Library/Developer/CommandLineTools"
SWIFTC="$CLT_ROOT/usr/bin/swiftc"
SDK="$CLT_ROOT/SDKs/MacOSX.sdk"
if [[ ! -x "$SWIFTC" || ! -d "$SDK" ]]; then
  echo "Portable checks require Apple's installed Command Line Tools at $CLT_ROOT." >&2
  exit 1
fi
OUTPUT="$ROOT/.build/portable-checks"
mkdir -p "$OUTPUT"

# This intentionally supports only the simple signatures used by this suite.
# Fail rather than silently omitting a newly added, unsupported test method.
python3 - "$ROOT" "$OUTPUT/Main.swift" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
output = Path(sys.argv[2])
class_pattern = re.compile(r'^final class (\w+): XCTestCase\s*\{', re.M)
test_pattern = re.compile(r'^    func (test\w+)\(\)( async)?( throws)?\s*\{', re.M)
candidate_pattern = re.compile(r'^\s+func (test\w+)\s*\(', re.M)
tests = []
for file in sorted((root / 'Tests/BridgeCoreTests').glob('*.swift')):
    text = file.read_text()
    methods = list(test_pattern.finditer(text))
    candidates = candidate_pattern.findall(text)
    if len(methods) != len(candidates):
        raise SystemExit(f'Unsupported test signature in {file.name}; update portable discovery explicitly.')
    if not methods:
        continue
    classes = class_pattern.findall(text)
    if len(classes) != 1:
        raise SystemExit(f'Expected exactly one XCTestCase subclass in {file.name}.')
    for method in methods:
        tests.append((classes[0], method.group(1), bool(method.group(2)), bool(method.group(3))))
if not tests:
    raise SystemExit('No test methods discovered; refusing an empty pass.')

lines = ['import Foundation', 'import Darwin', '', '@main struct PortableCheckMain {',
         '    static func main() async {',
         '        print("Portable checks: same test bodies with a local assertion adapter; this is not an XCTest run.")']
for suite, method, is_async, throws in tests:
    effects = ('try ' if throws else '') + ('await ' if is_async else '')
    lines += ['        do {', f'            let test = {suite}()',
              f'            await PortableChecks.run("{suite}.{method}",',
              '                setup: { try test.setUpWithError() },',
              f'                body: {{ {effects}test.{method}() }},',
              '                teardown: { try test.tearDownWithError() })', '        }']
lines += ['        print("Portable checks: \\(PortableChecks.testCount) cases, \\(PortableChecks.failedTestCount) failed.")',
          '        exit(PortableChecks.failedTestCount == 0 ? 0 : 1)', '    }', '}']
output.write_text('\n'.join(lines) + '\n')
print(f'Discovered {len(tests)} portable checks from the existing test sources.')
PY

"$SWIFTC" -sdk "$SDK" -swift-version 5 -D PORTABLE_CHECKS -parse-as-library \
  -module-cache-path "$OUTPUT/module-cache" \
  Sources/BridgeCore/*.swift Tests/BridgeCoreTests/*.swift \
  Tests/PortableSupport/Assertions.swift "$OUTPUT/Main.swift" \
  -o "$OUTPUT/portable-checks"
exec "$OUTPUT/portable-checks"
