#!/bin/bash
# Real controller/adapter/signature code; no model calls or persistent fixture writes.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRATCH="${NEWPI_VALIDATION_SCRATCH:-/private/tmp/newpi-rendering-spm}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
swift build --package-path "$ROOT/Packages/NewPiCore" --scratch-path "$SCRATCH" --target NewPiCore >&2
BIN="$(swift build --package-path "$ROOT/Packages/NewPiCore" --scratch-path "$SCRATCH" --show-bin-path)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# 对照运行只提取指定版本的控制器源码，不切分支、不改工作区。
CONTROLLER="$ROOT/NewPiApp/NewPiChatRoomStore.swift"
if [[ -n "${NEWPI_CONTROLLER_REVISION:-}" ]]; then
  git -C "$ROOT" show "${NEWPI_CONTROLLER_REVISION}:NewPiApp/NewPiChatRoomStore.swift" > "$TMP/Controller.swift"
  CONTROLLER="$TMP/Controller.swift"
fi
python3 - "$ROOT" "$TMP" <<'PY'
from pathlib import Path
import sys
root, tmp = map(Path, sys.argv[1:])
source = (root/'NewPiApp/NewPiViewModel.swift').read_text()
start = source.index('enum NewPiToolState:')
end = source.index('struct NewPiProviderListItem:')
(tmp/'TranscriptTypes.swift').write_text('import Foundation\nimport NewPiCore\n'+source[start:end])
bridge = (root/'NewPiApp/NewPiTranscriptDocumentView.swift').read_text()
start = bridge.index('        struct Signature:')
end = bridge.index('        private static func upsertOp(', start)
signature = bridge[start:end].replace('private static func', 'static func', 1)
(tmp/'Signature.swift').write_text('import Foundation\nimport NewPiCore\nstruct TranscriptSignatureProbe {\n'+signature+'}\n')
PY
xcrun swiftc -O -swift-version 6 -parse-as-library -I "$BIN/Modules" \
  "$TMP/TranscriptTypes.swift" "$TMP/Signature.swift" \
  "$ROOT/NewPiApp/NewPiChatRoomTranscriptAdapter.swift" \
  "$CONTROLLER" \
  "$ROOT/scripts/validation/ChatRoomPerformanceChecks.swift" \
  "$BIN"/NewPiCore.build/*.o -o "$TMP/check"
"$TMP/check"
