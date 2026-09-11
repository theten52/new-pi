#!/bin/bash
# 编译真实的 transcript 数据类型和适配器，无 UI 自动点击、无网络模型请求。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRATCH="${NEWPI_VALIDATION_SCRATCH:-/private/tmp/newpi-rendering-spm}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
swift build --package-path "$ROOT/Packages/NewPiCore" --scratch-path "$SCRATCH" --target NewPiCore
BIN="$(swift build --package-path "$ROOT/Packages/NewPiCore" --scratch-path "$SCRATCH" --show-bin-path)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# ViewModel 与 App 类型未建独立测试 target；精确提取其纯数据定义，避免复制一份测试模型。
python3 - "$ROOT" "$TMP" <<'PY'
from pathlib import Path
import sys
source = (Path(sys.argv[1])/'NewPiApp/NewPiViewModel.swift').read_text()
start = source.index('enum NewPiToolState:')
end = source.index('struct NewPiProviderListItem:')
(Path(sys.argv[2])/'TranscriptTypes.swift').write_text('import Foundation\nimport NewPiCore\n'+source[start:end])
PY
xcrun swiftc -swift-version 6 -parse-as-library -I "$BIN/Modules" \
  "$TMP/TranscriptTypes.swift" \
  "$ROOT/NewPiApp/NewPiChatRoomTranscriptAdapter.swift" \
  "$ROOT/scripts/validation/ChatRoomRenderingChecks.swift" \
  "$BIN"/NewPiCore.build/*.o -o "$TMP/check"
"$TMP/check"
