#!/bin/bash
# App 层守卫回归检查，不访问模型、不修改已有聊天室；需要 macOS + Swift 6。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRATCH="${NEWPI_VALIDATION_SCRATCH:-/private/tmp/newpi-ui-review-spm}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
swift build --package-path "$ROOT/Packages/NewPiCore" --scratch-path "$SCRATCH" --target NewPiCore
BIN="$(swift build --package-path "$ROOT/Packages/NewPiCore" --scratch-path "$SCRATCH" --show-bin-path)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
xcrun swiftc -swift-version 6 -parse-as-library -I "$BIN/Modules" \
  "$ROOT/NewPiApp/NewPiChatRoomStore.swift" \
  "$ROOT/NewPiApp/NewPiComposerDraft.swift" "$ROOT/NewPiApp/ImageAttachmentProcessor.swift" \
  "$ROOT/scripts/validation/ChatRoomControllerChecks.swift" \
  "$BIN"/NewPiCore.build/*.o -o "$TMP/check"
"$TMP/check"
