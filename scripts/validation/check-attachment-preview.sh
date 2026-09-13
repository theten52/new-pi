#!/bin/bash
# 生产预览控制器/视图，唯一路径解析替身限制为测试临时目录。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
python3 - "$ROOT" "$TMP" <<'PY'
from pathlib import Path
import os, subprocess, sys
root, tmp = map(Path, sys.argv[1:])
path = 'NewPiApp/AttachmentPreviewWindow.swift'
revision = os.environ.get('NEWPI_PREVIEW_REVISION')
source = subprocess.check_output(['git','-C',str(root),'show',revision+':'+path],text=True) if revision else (root/path).read_text()
(tmp/'Preview.swift').write_text(source.replace('import NewPiCore\n',''))
print('PREVIEW SOURCE:',revision or 'working tree')
PY
xcrun swiftc -swift-version 6 -parse-as-library "$TMP/Preview.swift" \
  "$ROOT/scripts/validation/AttachmentPreviewChecks.swift" -o "$TMP/check"
"$TMP/check" "$@"