#!/bin/bash
# 需要 macOS 图形登录会话；不依赖鼠标键盘辅助功能权限。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
xcrun swiftc -swift-version 6 -parse-as-library \
  "$ROOT/scripts/validation/TranscriptStreamingDOMChecks.swift" -o "$TMP/check"
"$TMP/check" "$ROOT" "$TMP"
