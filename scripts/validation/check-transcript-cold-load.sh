#!/bin/bash
# Real Coordinator + HTML shell + WKWebView, controlled temporary history; no live LLM requests.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
SCRATCH="${NEWPI_VALIDATION_SCRATCH:-/private/tmp/newpi-rendering-spm}"
swift build --package-path "$ROOT/Packages/NewPiCore" --scratch-path "$SCRATCH" --target NewPiCore >&2
BIN="$(swift build --package-path "$ROOT/Packages/NewPiCore" --scratch-path "$SCRATCH" --show-bin-path)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/Probe.app/Contents/MacOS" "$TMP/Probe.app/Contents/Resources"
cp -R "$ROOT/NewPiApp/MarkdownRenderer" "$TMP/Probe.app/Contents/Resources/MarkdownRenderer"
if [[ -n "${NEWPI_RENDERER_REVISION:-}" ]]; then
  git -C "$ROOT" show "${NEWPI_RENDERER_REVISION}:NewPiApp/MarkdownRenderer/markdown-renderer.js" > "$TMP/Probe.app/Contents/Resources/MarkdownRenderer/markdown-renderer.js"
fi
python3 - "$ROOT" "$TMP" <<'PY'
from pathlib import Path
import sys, plistlib
root,tmp = map(Path,sys.argv[1:])
source = (root/'NewPiApp/NewPiViewModel.swift').read_text()
(tmp/'Types.swift').write_text('import Foundation\nimport NewPiCore\n'+source[source.index('enum NewPiToolState:'):source.index('struct NewPiProviderListItem:')])
(tmp/'Probe.app/Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable':'Probe','CFBundleIdentifier':'com.newpi.coldloadprobe','CFBundlePackageType':'APPL'}))
PY
xcrun swiftc -O -swift-version 6 -parse-as-library -I "$BIN/Modules" \
  "$TMP/Types.swift" "$ROOT/NewPiApp/NewPiChatRoomTranscriptAdapter.swift" \
  "$ROOT/NewPiApp/NewPiTranscriptDocumentView.swift" "$ROOT/NewPiApp/NewPiMarkdownWebRenderer.swift" \
  "$ROOT/NewPiApp/NewPiChatScrollHelper.swift" "$ROOT/NewPiApp/AttachmentSchemeHandler.swift" \
  "$ROOT/NewPiApp/AttachmentPreviewWindow.swift" "$ROOT/scripts/validation/TranscriptColdLoadChecks.swift" \
  "$BIN"/NewPiCore.build/*.o -o "$TMP/Probe.app/Contents/MacOS/Probe"
"$TMP/Probe.app/Contents/MacOS/Probe"
