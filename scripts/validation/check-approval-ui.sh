#!/bin/bash
# macOS 图形会话 + 辅助功能权限；无模型请求/真实工具。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
SCRATCH="${NEWPI_VALIDATION_SCRATCH:-/private/tmp/newpi-rendering-spm}"
swift build --package-path "$ROOT/Packages/NewPiCore" --scratch-path "$SCRATCH" --target NewPiCore
BIN="$(swift build --package-path "$ROOT/Packages/NewPiCore" --scratch-path "$SCRATCH" --show-bin-path)"
TMP="$(mktemp -d)"
PID=""
trap 'if [[ -n "$PID" ]]; then kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; fi; rm -rf "$TMP"' EXIT
python3 - "$ROOT" "$TMP" <<'PY'
from pathlib import Path
import sys
root,tmp = map(Path,sys.argv[1:])
source = (root/'NewPiApp/NewPiToolApprovalSheet.swift').read_text()
(tmp/'ApprovalContent.swift').write_text('import AppKit\nimport NewPiCore\nimport SwiftUI\n'+source[source.index('struct NewPiApprovalContent:'):source.index('#Preview')])
PY
xcrun swiftc -swift-version 6 -parse-as-library -I "$BIN/Modules" "$TMP/ApprovalContent.swift" \
  "$ROOT/scripts/validation/ApprovalUIProbe.swift" "$BIN"/NewPiCore.build/*.o -o "$TMP/check"
xcrun swiftc "$ROOT/scripts/validation/ApprovalUIActions.swift" -o "$TMP/actions"
for mode in room high session; do
  "$TMP/check" "$mode" > "$TMP/$mode.log" 2>&1 &
  PID=$!
  sleep 2
  if [[ -n "${NEWPI_UI_INSPECTOR:-}" ]]; then "$NEWPI_UI_INSPECTOR" "$PID"; fi
  if [[ -n "${NEWPI_UI_SNAPSHOTS:-}" ]]; then
    mkdir -p "$NEWPI_UI_SNAPSHOTS"
    WINDOW_ID=$(sed -n 's/.*WINDOW=//p' "$TMP/$mode.log" | head -1)
    screencapture -x -l "$WINDOW_ID" "$NEWPI_UI_SNAPSHOTS/$mode.png"
  fi
  "$TMP/actions" "$PID" "$mode"
  wait "$PID"
  PID=""
  cat "$TMP/$mode.log"
done
