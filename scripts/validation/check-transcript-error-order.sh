#!/bin/bash
# 提取真实转录重建方法；不运行 AgentSession、不调用模型、不读取用户历史。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
SCRATCH="${NEWPI_VALIDATION_SCRATCH:-/private/tmp/newpi-rendering-spm}"
swift build --package-path "$ROOT/Packages/NewPiCore" --scratch-path "$SCRATCH" --target NewPiCore
BIN="$(swift build --package-path "$ROOT/Packages/NewPiCore" --scratch-path "$SCRATCH" --show-bin-path)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
python3 - "$ROOT" "$TMP" <<'PY'
from pathlib import Path
import os, subprocess, sys
root, tmp = map(Path, sys.argv[1:])
revision = os.environ.get('NEWPI_ERROR_ORDER_REVISION')
path = 'NewPiApp/NewPiViewModel.swift'
source = subprocess.check_output(['git', '-C', str(root), 'show', revision+':'+path], text=True) if revision else (root/path).read_text()
types = source[source.index('enum NewPiToolState:'):source.index('struct NewPiProviderListItem:')]
helpers = source[source.index('private func detailTurnID('):source.index('enum NewPiAgentActivity:')]
methods = source[source.index('    private func rebuildTranscript('):source.index('    private func cleanupEmptySessions()')]
methods = methods.replace('    private func rebuildTranscript(', '    func rebuildTranscript(', 1)
(tmp/'Production.swift').write_text('import Foundation\nimport NewPiCore\n'+types+helpers+'\nfinal class RebuildHarness {\nvar activeRuntime: SessionRuntime?\nvar transcript: [NewPiTranscriptItem] = []\nfunc commitLiveTranscript(on runtime: SessionRuntime) { if let live = runtime.liveTranscript { runtime.transcript = live; runtime.liveTranscript = nil } }\n'+methods+'\n}\n')
print('ERROR ORDER SOURCE:', revision or 'working tree')
PY
xcrun swiftc -swift-version 6 -parse-as-library -I "$BIN/Modules" \
  "$TMP/Production.swift" "$ROOT/scripts/validation/TranscriptErrorOrderChecks.swift" \
  "$BIN"/NewPiCore.build/*.o -o "$TMP/check"
"$TMP/check"