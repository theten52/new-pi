#!/bin/bash
# 只由主 agent 执行：提取真实共享组件和创建适配器，使用合成窗口／内存发布接口。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
TMP="$(mktemp -d /private/tmp/newpi-native-audit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
cd "$ROOT/Packages/NewPiCore"
swift build --scratch-path "$TMP/spm" --target NewPiCore
BIN="$(swift build --scratch-path "$TMP/spm" --show-bin-path)"
python3 - "$ROOT" "$TMP" <<'PY'
from pathlib import Path
import sys
root, tmp = map(Path, sys.argv[1:])
chat = (root/'NewPiApp/NewPiChatView.swift').read_text()
status = (root/'NewPiApp/NewPiAgentStatusView.swift').read_text()
assert chat.count('extension NewPiViewModel {') == 1
creation = 'extension NewPiViewModel {' + chat.split('extension NewPiViewModel {', 1)[1].split('/// 单个会话的聊天面板', 1)[0]
(tmp/'Creation.swift').write_text('import Combine\nimport Foundation\n' + creation)
(tmp/'Composer.swift').write_text('import AppKit\nimport SwiftUI\nimport NewPiCore\nimport UniformTypeIdentifiers\n' + chat[chat.index('struct NewPiComposerTextView:'):chat.index('#Preview')])
(tmp/'Status.swift').write_text(status.split('#Preview("Ready")', 1)[0])
PY
xcrun swiftc -swift-version 6 -parse-as-library -target "$(uname -m)-apple-macosx15.0" \
    "$TMP/Creation.swift" "$ROOT/scripts/validation/ComposerCreationChecks.swift" -o "$TMP/creation"
"$TMP/creation"
xcrun swiftc -swift-version 6 -parse-as-library -target "$(uname -m)-apple-macosx15.0" \
    -I "$BIN/Modules" "$TMP/Composer.swift" "$TMP/Status.swift" \
    "$ROOT/NewPiApp/NewPiComposerDraft.swift" "$ROOT/NewPiApp/ImageAttachmentProcessor.swift" \
    "$ROOT/scripts/validation/NativeAuditChecks.swift" "$BIN"/NewPiCore.build/*.o -o "$TMP/native"
"$TMP/native"