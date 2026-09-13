#!/bin/bash
# 独立 AppKit/SwiftUI 组件；不启动真实 NewPi、不加载 ViewModel/用户配置、不截图。
# 用法：bash scripts/validation/check-settings-escape.sh
# 0 = 自动组件断言通过（仍需读 LIMIT）；1 = 编译/断言失败；2 = 无图形会话。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'UNVERIFIED: 需要 macOS 图形会话'; exit 2
fi
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/newpi-settings-escape.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home" "$TMP/config" "$TMP/cache"
# 仅隔离此探针进程；源码中没有 UserDefaults、Keychain、providers 或 MCP 读取。
export HOME="$TMP/home" CFFIXED_USER_HOME="$TMP/home"
export XDG_CONFIG_HOME="$TMP/config" XDG_CACHE_HOME="$TMP/cache"

# 生产声明经 stdin 编译，不把新的 Swift 源文件写到工作区之外。
python3 - "$ROOT" <<'PY' | xcrun swiftc -swift-version 6 -parse-as-library \
  -module-name SettingsEscapeChecks -target "$(uname -m)-apple-macosx15.0" \
  -module-cache-path "$TMP/modules" - -o "$TMP/check"
from pathlib import Path
import hashlib, re, sys

root = Path(sys.argv[1])
def read(name):
    source = (root / 'NewPiApp' / name).read_text()
    print(f'SOURCE: {name} SHA256={hashlib.sha256(source.encode()).hexdigest()}', file=sys.stderr)
    return source

# 锚点不匹配时失败，不能悄悄测试手抄的替代实现。
def block(source, anchor):
    assert source.count(anchor) == 1, f'提取锚点变化：{anchor}'
    start = source.index(anchor)
    opening = source.index('{', start)
    depth = 1
    for end in range(opening + 1, len(source)):
        depth += (source[end] == '{') - (source[end] == '}')
        if depth == 0:
            return source[start:end + 1]
    raise AssertionError(f'声明未闭合：{anchor}')

controller = read('NewPiSettingsWindowController.swift')
settings = read('NewPiSettingsView.swift')
vendor = read('NewPiVendorTemplateView.swift')
mcp = read('NewPiMCPSettingsView.swift')
window = block(controller, '@MainActor\nfinal class NewPiSettingsWindow: NSWindow')
for forbidden in ('addLocalMonitorForEvents', 'addGlobalMonitorForEvents', 'onExitCommand'):
    assert forbidden not in controller + settings + vendor, f'禁止抢占 ESC：{forbidden}'
assert 'let window = NewPiSettingsWindow(' in controller
assert 'window.delegate = self' in controller
assert 'private static var shared: NewPiSettingsWindowController?' in controller
close = block(controller, 'func windowWillClose(_ notification: Notification)')
assert re.fullmatch(r'func windowWillClose\(_ notification: Notification\)\s*\{\s*Self.shared = nil\s*\}', close)
assert 'Button("Cancel", role: .cancel)' in mcp, 'MCP 保留系统 alert 取消角色'

print('import AppKit\nimport SwiftUI')
print(window)
# 只复用实际生命周期方法；不构造带 frame autosave/真实 ViewModel 的生产 controller。
print('extension SettingsLifetimeFixture: NSWindowDelegate {')
print(close)
print('}')

print('extension SettingsCancelKind {')
print('@MainActor @ToolbarContentBuilder func cancellation(dismiss: DismissAction) -> some ToolbarContent {')
print('switch self {')
for case, source, name in [
    ('addProvider', settings, 'NewPiAddProviderSheet'),
    ('editProvider', settings, 'NewPiEditProviderSheet'),
    ('templates', vendor, 'NewPiVendorTemplateManagerView'),
    ('vendor', vendor, 'NewPiVendorTemplateEditorView'),
    ('model', vendor, 'NewPiModelDefinitionEditorView'),
]:
    view = block(source, f'struct {name}: View')
    cancel = block(view, 'ToolbarItem(placement: .cancellationAction)')
    assert re.search(r'Button\("(?:Cancel|Done|取消)"\)\s*\{\s*dismiss\(\)\s*\}\s*\.keyboardShortcut\(\.cancelAction\)', cancel), name
    print(f'case .{case}:\n{cancel}')
print('}\n}\n}')
print((root / 'scripts/validation/SettingsEscapeChecks.swift').read_text())
print('PASS: 生产窗口/生命周期/五个实际取消按钮已提取；无键盘 monitor', file=sys.stderr)
PY
"$TMP/check"