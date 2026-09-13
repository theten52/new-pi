#!/bin/bash
# 仅编译/启动独立组件，不调用真实 App、不读用户存储、不访问网络。
# 0 全部通过；1 构建/断言失败；2 截图不可验证。需要当前 macOS 图形会话。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'UNVERIFIED: 需要 macOS AppKit 图形会话'; exit 2
fi
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/newpi-usage-dialog.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
cd "$ROOT/Packages/NewPiCore"
swift build --scratch-path "$TMP/spm" --target NewPiCore --skip-update
BIN="$(swift build --scratch-path "$TMP/spm" --show-bin-path)"
# 不改生产声明；仅去掉无关 #Preview 宏（避免独立 swiftc 依赖预览插件）。
python3 - "$ROOT" <<'PY' | xcrun swiftc -swift-version 6 -parse-as-library -module-name UsageDialogChecks \
  -target "$(uname -m)-apple-macosx15.0" \
  -module-cache-path "$TMP/modules" -I "$BIN/Modules" - \
  "$BIN"/NewPiCore.build/*.o -o "$TMP/check"
from pathlib import Path
import hashlib, os, subprocess, sys
root = Path(sys.argv[1])
revision = os.environ.get('NEWPI_USAGE_REVISION')
# 对照版只通过 git show 送入临时编译，不覆盖工作区生产文件。
source = subprocess.check_output(['git', 'show', f'{revision}:NewPiApp/NewPiAgentStatusView.swift'],
  cwd=root, text=True) if revision else (root/'NewPiApp/NewPiAgentStatusView.swift').read_text()
print('SOURCE: revision=' + (revision or 'worktree'), file=sys.stderr)
print('SOURCE: NewPiAgentStatusView.swift SHA256=' + hashlib.sha256(source.encode()).hexdigest(), file=sys.stderr)
assert source.count('#Preview("Ready")') == 1, '生产源码提取锚点变化'
print(source.split('#Preview("Ready")', 1)[0])
print((root/'scripts/validation/UsageDialogChecks.swift').read_text())
PY
"$TMP/check"