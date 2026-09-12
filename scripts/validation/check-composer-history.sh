#!/bin/bash
# 隔离原生输入框：历史草稿状态 + 实际 keyDown + 生产 Coordinator。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
SCRATCH="${NEWPI_VALIDATION_SCRATCH:-/private/tmp/newpi-rendering-spm}"
cd "$ROOT/Packages/NewPiCore"
swift build --scratch-path "$SCRATCH" --target NewPiCore
BIN="$(swift build --scratch-path "$SCRATCH" --show-bin-path)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
python3 - "$ROOT" "$TMP" <<'PY'
from pathlib import Path
import sys
root, tmp = map(Path, sys.argv[1:])
source = (root/'NewPiApp/NewPiChatView.swift').read_text()
(tmp/'Composer.swift').write_text('import AppKit\nimport SwiftUI\nimport NewPiCore\nimport UniformTypeIdentifiers\n'+source[source.index('struct NewPiComposerTextView:'):source.index('#Preview')])
assert 'runtime.transcript.filter { $0.kind == .user }.map(\\.body)' in source
assert 'runtime.messages.filter(\\.isUserMessage).map(\\.content)' in (root/'NewPiApp/NewPiApp.swift').read_text()
PY
xcrun swiftc -swift-version 6 -parse-as-library -I "$BIN/Modules" "$TMP/Composer.swift" \
  "$ROOT/NewPiApp/NewPiComposerDraft.swift" "$ROOT/NewPiApp/ImageAttachmentProcessor.swift" \
  "$ROOT/scripts/validation/ComposerHistoryChecks.swift" "$BIN"/NewPiCore.build/*.o -o "$TMP/check"
"$TMP/check"