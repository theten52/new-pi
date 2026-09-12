#!/bin/bash
# 真实 AppKit 图片处理；仅创建临时合成图片，不访问用户图片或剪贴板。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
SCRATCH="${NEWPI_VALIDATION_SCRATCH:-/private/tmp/newpi-rendering-spm}"
swift build --package-path "$ROOT/Packages/NewPiCore" --scratch-path "$SCRATCH" --target NewPiCore
BIN="$(swift build --package-path "$ROOT/Packages/NewPiCore" --scratch-path "$SCRATCH" --show-bin-path)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
xcrun swiftc -swift-version 6 -parse-as-library -I "$BIN/Modules" \
  "$ROOT/NewPiApp/ImageAttachmentProcessor.swift" "$ROOT/scripts/validation/AttachmentProcessingChecks.swift" \
  "$BIN"/NewPiCore.build/*.o -o "$TMP/check"
"$TMP/check"