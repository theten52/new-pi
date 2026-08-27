#!/usr/bin/env bash
#
# NewPi macOS 一键打包脚本
#
# 用法:
#   ./scripts/package.sh            # 默认 Release
#   ./scripts/package.sh Debug      # 指定配置
#
# 行为:
#   1. xcodebuild 构建指定配置（ad-hoc 本地签名，无需开发者账号）
#   2. 将产物 NewPi.app 拷贝到项目 ./dist/
#   3. 清除 quarantine 标记并校验签名
#
# 产物: ./dist/NewPi.app   (本机可直接双击运行; 分发需正式签名+公证)
#
set -euo pipefail

# ---- 路径与配置 ----
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHEME="${SCHEME:-NewPi}"
CONFIGURATION="${1:-Release}"
DERIVED_DATA="$PROJECT_DIR/build/derived"
DIST_DIR="$PROJECT_DIR/dist"
APP_NAME="NewPi.app"                     # 产物名 = target 的 PRODUCT_NAME

# 无开发者账号时使用 ad-hoc 本地签名
CODE_SIGN_STYLE="${CODE_SIGN_STYLE:-Manual}"
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}"

cd "$PROJECT_DIR"

echo "==> NewPi 打包"
echo "    工程目录     : $PROJECT_DIR"
echo "    scheme      : $SCHEME"
echo "    configuration: $CONFIGURATION"
echo "    derivedData : $DERIVED_DATA"

# ---- 构建 ----
echo "==> 构建 (ad-hoc 本地签名, CODE_SIGN_IDENTITY=$CODE_SIGN_IDENTITY)"
xcodebuild \
  -project NewPi.xcodeproj \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGN_STYLE="$CODE_SIGN_STYLE" \
  CODE_SIGN_IDENTITY="$CODE_SIGN_IDENTITY" \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM"

# ---- 定位产物 ----
SRC_APP="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME"
if [ ! -d "$SRC_APP" ]; then
  echo "!! 未找到构建产物: $SRC_APP" >&2
  exit 1
fi

# ---- 拷贝到 dist/ ----
echo "==> 拷贝到 $DIST_DIR/"
mkdir -p "$DIST_DIR"
rm -rf "$DIST_DIR/$APP_NAME"
cp -R "$SRC_APP" "$DIST_DIR/$APP_NAME"

# ---- 清除 quarantine + 校验签名 ----
xattr -dr com.apple.quarantine "$DIST_DIR/$APP_NAME" 2>/dev/null || true
if codesign --verify --deep --strict "$DIST_DIR/$APP_NAME" 2>/dev/null; then
  echo "    签名校验: OK (adhoc 本地签名)"
else
  echo "    签名校验: 提示可绕过（ad-hoc 仅本机有效; 分发需正式证书+公证）"
fi

echo
echo "==> 完成 ✅"
echo "    产物: $DIST_DIR/$APP_NAME"
echo "    运行: open \"$DIST_DIR/$APP_NAME\""
