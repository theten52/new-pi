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
if [[ -n "${NEWPI_TRANSCRIPT_REVISION:-}" ]]; then
  for resource in transcript-document.js transcript-document.css; do
    git -C "$ROOT" show "${NEWPI_TRANSCRIPT_REVISION}:NewPiApp/MarkdownRenderer/$resource" > "$TMP/Probe.app/Contents/Resources/MarkdownRenderer/$resource"
  done
fi
python3 - "$ROOT" "$TMP" <<'PY'
from pathlib import Path
import sys, plistlib, uuid, os
root,tmp = map(Path,sys.argv[1:])
source = (root/'NewPiApp/NewPiViewModel.swift').read_text()
(tmp/'Types.swift').write_text('import Foundation\nimport NewPiCore\n'+source[source.index('enum NewPiToolState:'):source.index('struct NewPiProviderListItem:')])
if os.environ.get('NEWPI_WORKBENCH_UI') == '1':
    # 直接编译生产输入框及其后续 AppKit 类；不引入 ViewModel / AgentSession。
    composer = (root/'NewPiApp/NewPiChatView.swift').read_text()
    start = composer.index('struct NewPiComposerTextView:')
    end = composer.index('#Preview', start)
    (tmp/'Composer.swift').write_text(
        'import AppKit\nimport NewPiCore\nimport SwiftUI\nimport UniformTypeIdentifiers\n'
        + composer[start:end])
(tmp/'Probe.app/Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable':'Probe','CFBundleIdentifier':'com.newpi.coldloadprobe.'+uuid.uuid4().hex,'CFBundlePackageType':'APPL'}))
PY
CHECK="$ROOT/scripts/validation/TranscriptColdLoadChecks.swift"
OPTIMIZATION="-O"
# 位置参数承载可选源文件，兼容 macOS 自带 Bash 3 的 nounset / 空数组行为。
set --
if [[ "${NEWPI_WORKBENCH_UI:-0}" == "1" ]]; then
  CHECK="$ROOT/scripts/validation/WorkbenchUIChecks.swift"
  OPTIMIZATION="-Onone"
  set -- "$TMP/Composer.swift" "$ROOT/NewPiApp/ImageAttachmentProcessor.swift"
elif [[ "${NEWPI_PRESENTATION_REPLAY:-0}" == "1" ]]; then
  CHECK="$ROOT/scripts/validation/TranscriptPresentationChecks.swift"
  OPTIMIZATION="-Onone"
fi
xcrun swiftc "$OPTIMIZATION" -swift-version 6 -parse-as-library -I "$BIN/Modules" \
  "$TMP/Types.swift" "$ROOT/NewPiApp/NewPiChatRoomTranscriptAdapter.swift" \
  "$ROOT/NewPiApp/NewPiTranscriptDocumentView.swift" "$ROOT/NewPiApp/NewPiMarkdownWebRenderer.swift" \
  "$ROOT/NewPiApp/NewPiChatScrollHelper.swift" "$ROOT/NewPiApp/AttachmentSchemeHandler.swift" \
  "$ROOT/NewPiApp/AttachmentPreviewWindow.swift" "$ROOT/NewPiApp/NewPiUserMessageRail.swift" \
  "$ROOT/NewPiApp/NewPiConfettiBurst.swift" "${NEWPI_STATUS_VIEW_SOURCE:-$ROOT/NewPiApp/NewPiAgentStatusView.swift}" "$@" "$CHECK" \
  "$BIN"/NewPiCore.build/*.o -o "$TMP/Probe.app/Contents/MacOS/Probe"
"$TMP/Probe.app/Contents/MacOS/Probe"
