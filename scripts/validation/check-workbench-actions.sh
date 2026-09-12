#!/bin/bash
# 独立组件交互；生产源码经标准输入编译，不在外部目录写源码，不启动用户 App。
# 退出码：0 全部通过；1 断言/构建失败；2 有不可验证的交互（SKIP），绝不冒充 PASS。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'SKIP: 需要 macOS AppKit 图形会话'; exit 2
fi
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/newpi-workbench-actions.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
trap 'echo "FAIL: 构建或运行失败（见上方日志）" >&2' ERR
# SwiftPM 从包目录运行；缓存、模块与可执行文件均在临时目录。
cd "$ROOT/Packages/NewPiCore"
swift build --scratch-path "$TMP/spm" --target NewPiCore
BIN="$(swift build --scratch-path "$TMP/spm" --show-bin-path)"
python3 - "$ROOT" <<'PY' | xcrun swiftc -swift-version 6 -parse-as-library -module-name WorkbenchActions \
  -module-cache-path "$TMP/modules" -I "$BIN/Modules" - \
    "$BIN"/NewPiCore.build/*.o -o "$TMP/check"
from pathlib import Path
import hashlib, sys
root = Path(sys.argv[1])
def read(name):
    data = (root/'NewPiApp'/name).read_text()
    print('SOURCE:', name, hashlib.sha256(data.encode()).hexdigest(), file=sys.stderr)
    return data
def section(source, start, end):
    a = source.index(start)
    return source[a:source.index(end, a)]
def once(source, old, new):
    if source.count(old) != 1:
        raise RuntimeError('提取契约变化：' + old)
    return source.replace(old, new)
def measure(key):
    return '.onGeometryChange(for: CGRect.self) { $0.frame(in: .named("actions")) } action: { ActionFrames.values[' + key + '] = $0 }'
chat = read('NewPiChatView.swift')
app = read('NewPiApp.swift')
vm = read('NewPiViewModel.swift')
empty = read('NewPiMarkdownText.swift')
approval = read('NewPiToolApprovalSheet.swift')
style = read('NewPiAgentStatusView.swift')
print('import AppKit\nimport SwiftUI\nimport NewPiCore\nimport UniformTypeIdentifiers')
print(section(style, 'enum NewPiWorkbenchStyle {', '/// 唯一的原生分栏外壳'))
empty = empty[empty.index('struct NewPiChatEmptyStateView:'):]
# 只增加只读几何观察，不修改 Button action、disabled、尺寸或状态。
print(once(empty, '.buttonStyle(.plain)', '.buttonStyle(.plain)\n' + measure('suggestion.title')))
approval = section(approval, 'struct NewPiApprovalContent:', '#Preview')
approval = once(approval, 'respond(.deny)\n            }', 'respond(.deny)\n            }\n' + measure('"deny"'))
approval = once(approval, '.menuStyle(.borderedButton)', '.menuStyle(.borderedButton)\n' + measure('"remember"'))
approval = once(approval, '.buttonStyle(.borderedProminent)', '.buttonStyle(.borderedProminent)\n' + measure('"once"'))
print(approval)
print(section(chat, 'struct NewPiComposerTextView:', '#Preview'))
print('extension SuggestionVMFixture {\n' + section(vm, '    func fillSuggestedDraft(', '    func resumeSession(') + '}')
# 接线只读契约不是交互 PASS；以下生产表达式直接成为可执行 fixture 的视图。
session_suggestion = section(chat[chat.index('struct NewPiSessionPanel:'):], 'NewPiChatEmptyStateView(hasProject:', '\n                            .frame')
initial_suggestion = section(chat, 'NewPiChatEmptyStateView(hasProject:', '\n                    .frame')
print('struct SessionSuggestionFixture: View { @ObservedObject var draft: NewPiComposerDraft; let viewModel: SuggestionVMFixture; var body: some View { ' + session_suggestion + ' } }')
print('struct InitialSuggestionFixture: View { @ObservedObject var viewModel: SuggestionVMFixture; var body: some View { ' + initial_suggestion + ' } }')
# 正式审批已进入 WK 单文档；下方原生夹具仅验证兼容组件，不能提取/重建已删除的 dock。
# 保留接线只读契约；实际 bridge 守卫在 check-transcript-cold-load.sh 中运行。
assert 'approval: transcriptApproval' in chat
assert 'viewModel.respondToTranscriptApproval(requestID: requestID, decision: decision, on: runtime)' in chat
assert 'approvalManager.pendingApprovals.first?.request == pending.request' in app
assert 'NewPiApprovalContent' not in section(chat, 'struct NewPiSessionPanel:', '// MARK: - Multiline composer')
assert 'NewPiApprovalContent' not in section(app, 'struct ChatRoomDetailView:', '// MARK: - 投票 Sheet')
print(read('NewPiComposerDraft.swift'))
print(read('ImageAttachmentProcessor.swift'))
print((root/'scripts/validation/WorkbenchActionsChecks.swift').read_text())
print('EXTRACT: 生产建议接线、fillSuggestedDraft、NSTextView；审批仅生产兼容组件+测试容器（非 WK 接线）；按钮增加只读几何探针', file=sys.stderr)
PY
if "$TMP/check"; then
    exit 0
else
    RESULT=$?
    exit "$RESULT"
fi