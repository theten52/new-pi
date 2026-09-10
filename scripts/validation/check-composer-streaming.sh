#!/bin/bash
# Real NSTextView and SwiftUI binding; synthetic output ticks and input method composition.
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
import sys,os,subprocess
root,tmp = map(Path,sys.argv[1:])
revision = os.environ.get('NEWPI_COMPOSER_REVISION')
source = subprocess.check_output(['git','-C',str(root),'show',revision+':NewPiApp/NewPiChatView.swift'],text=True) if revision else (root/'NewPiApp/NewPiChatView.swift').read_text()
(tmp/'Composer.swift').write_text('import AppKit\nimport SwiftUI\nimport NewPiCore\nimport UniformTypeIdentifiers\n'+source[source.index('struct NewPiComposerTextView:'):source.index('#Preview')])
PY
xcrun swiftc -swift-version 6 -parse-as-library -I "$BIN/Modules" "$TMP/Composer.swift" \
  "$ROOT/NewPiApp/ImageAttachmentProcessor.swift" "$ROOT/scripts/validation/ComposerStreamingChecks.swift" \
  "$BIN"/NewPiCore.build/*.o -o "$TMP/check"
"$TMP/check"
