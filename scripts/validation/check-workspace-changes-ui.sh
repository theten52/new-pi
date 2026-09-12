#!/bin/bash
# 独立原生窗口 + 完整生产 Status（除 Preview）/Changes overlay + 真实 Reader / 系统 Git。
# 0 = 全部通过；1 = 构建/运行/断言失败；2 = 存在无法验证的 SKIP。无宽松模式。
# 请用 bash 执行；不启动、查找、关闭用户 NewPi App，不读取用户仓库的 Git 内容。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
if [[ "$(uname -s)" != Darwin ]]; then
    echo 'SKIP: 需要 macOS 15+ 的 AppKit 图形会话'; exit 2
fi
OS_VERSION="$(sw_vers -productVersion)"
if [[ "${OS_VERSION%%.*}" -lt 15 ]]; then
    echo 'SKIP: 需要 macOS 15 或更新版本'; exit 2
fi
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
# 不接受外部 TMPDIR，避免 fixture 意外进入用户工作区；退出时只删除本次 mktemp 的目录。
TMP="$(mktemp -d /private/tmp/newpi-workspace-changes-ui.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
trap 'echo "FAIL: fixture、构建或运行失败（见上方日志）" >&2; exit 1' ERR
mkdir -p "$TMP/home/.config" "$TMP/repo-a/nested" "$TMP/repo-b" "$TMP/clean" "$TMP/not-git"
printf 'newpi-workspace-changes-ui\n' > "$TMP/fixture-owner"

# fixture 的 Git 环境完全隔离；不继承 GIT_DIR、INDEX_FILE、配置注入、hooks 或凭据。
fixture_git() {
    local repository="$1"; shift
    case "$repository" in "$TMP/repo-a"|"$TMP/repo-b"|"$TMP/clean") ;; *) return 1 ;; esac
    env -i PATH=/usr/bin:/bin HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/home/.config" LC_ALL=C \
        GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
        GIT_TERMINAL_PROMPT=0 GIT_ATTR_NOSYSTEM=1 GIT_ALLOW_PROTOCOL= \
        /usr/bin/git -C "$repository" --no-pager -c core.hooksPath=/dev/null \
        -c protocol.allow=never -c commit.gpgsign=false \
        -c user.name=UIFixture -c user.email=ui-fixture@example.invalid "$@"
}
for repository in "$TMP/repo-a" "$TMP/repo-b" "$TMP/clean"; do
    fixture_git "$repository" init --quiet --initial-branch=main
done
printf 'BASE_A\n' > "$TMP/repo-a/a-both.txt"
printf 'DELETED_A\n' > "$TMP/repo-a/b-deleted.txt"
printf 'ignored.txt\n' > "$TMP/repo-a/.gitignore"
fixture_git "$TMP/repo-a" add --all -- .
fixture_git "$TMP/repo-a" commit --quiet -m fixture
printf 'STAGED_A\n' > "$TMP/repo-a/a-both.txt"
fixture_git "$TMP/repo-a" add -- a-both.txt
printf 'WORKTREE_A\n' > "$TMP/repo-a/a-both.txt"
rm "$TMP/repo-a/b-deleted.txt"
printf 'UNTRACKED_A\n' > "$TMP/repo-a/c-new-新 文件.txt"
printf 'MUST_NOT_APPEAR\n' > "$TMP/repo-a/ignored.txt"
# 长行应被真实横向 ScrollView 包住，而不是挤出面板。
python3 - "$TMP" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
with (root/'repo-a/c-new-新 文件.txt').open('a') as file:
    file.write('LONG_LINE_' + '0123456789' * 160 + '\n')
PY
printf 'BASE_B\n' > "$TMP/repo-b/b-only.txt"
fixture_git "$TMP/repo-b" add -- b-only.txt
fixture_git "$TMP/repo-b" commit --quiet -m fixture
printf 'SWITCH_B\n' > "$TMP/repo-b/b-only.txt"
fixture_git "$TMP/clean" commit --quiet --allow-empty -m fixture

# SwiftPM 始终在包目录运行；产物/模块缓存只在本次临时目录。
cd "$ROOT/Packages/NewPiCore"
swift build --scratch-path "$TMP/spm" --target NewPiCore
BIN="$(swift build --scratch-path "$TMP/spm" --show-bin-path)"
python3 - "$ROOT" <<'PY' | xcrun swiftc -swift-version 6 -parse-as-library \
    -target "$(uname -m)-apple-macosx15.0" \
    -module-name WorkspaceChangesUIChecks -module-cache-path "$TMP/modules" \
    -I "$BIN/Modules" - "$BIN"/NewPiCore.build/*.o -o "$TMP/check"
from pathlib import Path
import hashlib, sys
root = Path(sys.argv[1])
status = (root/'NewPiApp/NewPiAgentStatusView.swift').read_text()
print('SOURCE: NewPiAgentStatusView.swift', hashlib.sha256(status.encode()).hexdigest(), file=sys.stderr)
# 完整共享生产实现（包括 presentation/filter/backdrop/style），只剥离尾部 Preview。
marker = '#Preview("Ready")'
if status.count(marker) != 1:
    raise RuntimeError('Status Preview 提取契约变化')
status, previews = status.split(marker, 1)
if '#Preview' in status or not previews.rstrip().endswith('}'):
    raise RuntimeError('Status Preview 边界变化')
print(status)
source = (root/'NewPiApp/NewPiChangesView.swift').read_text()
print('SOURCE: NewPiChangesView.swift', hashlib.sha256(source.encode()).hexdigest(), file=sys.stderr)
def once(old, new):
    global source
    if source.count(old) != 1:
        raise RuntimeError('提取契约变化（不继续猜测/删除断言）: ' + old)
    source = source.replace(old, new)
def measure(key):
    return '.workspaceMeasure(' + key + ')'
# 唯一的插桩：只读视图坐标。无状态观察/替换、无 Reader 注入、无 action 修改。
once('        .help("查看整个 Git 工作区',
     '        .workspaceMeasure("open", space: "workspace-button")\n        .help("查看整个 Git 工作区')
for key, expression in [
    ('title', 'Label("工作区 Git 改动", systemImage: "plus.forwardslash.minus").font(.headline)'),
    ('refresh', 'Button("刷新", systemImage: "arrow.clockwise") { model.refreshNow() }'),
    ('notice', '.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)'),
    ('scope', '.font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)'),
    ('count', r'Text("最近完整清单：\(snapshot.readAt.formatted(date: .omitted, time: .standard)) · \(snapshot.files.count) 个文件；diff 按需读取，非原子快照")'
              + '\n                        .font(.caption2).foregroundStyle(.secondary)'),
    ('selected', 'Text(file.displayPath).font(.system(.body, design: .monospaced)).textSelection(.enabled)'),
    ('picker', '.accessibilityLabel("改动分区")'),
    ('diff', 'NewPiChangesDiffLines(diff: diff)'),
]:
    once(expression, expression + '\n                ' + measure('"' + key + '"'))
once('                            .accessibilityLabel(file.displayPath)\n                            if model.selectedPath == file.path {',
    '                            .accessibilityLabel(file.displayPath)\n                            .workspaceMeasure("row:" + file.path)\n                            if model.selectedPath == file.path {')
once('                        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(NewPiWorkbenchStyle.line) }',
    '                        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(NewPiWorkbenchStyle.line) }\n                        .workspaceMeasure("card:" + file.path)')
once('                }.padding(12)\n            }\n        } else {',
    '                }.padding(12)\n            }\n            .workspaceMeasure("cards-scroll")\n        } else {')
once('.accessibilityAddTraits(model.area == area ? .isSelected : [])',
    '.accessibilityAddTraits(model.area == area ? .isSelected : [])\n            .workspaceMeasure("area:" + area.rawValue)')
once('        }.frame(maxWidth: .infinity, maxHeight: .infinity)\n    }\n\n    private var areaButtons',
    '        }.frame(maxWidth: .infinity, maxHeight: .infinity)\n        .workspaceMeasure("detail")\n    }\n\n    private var areaButtons')
once('                }.frame(width: max(geometry.size.width, layout.width)).textSelection(.enabled)\n            }\n        }',
    '                }.frame(width: max(geometry.size.width, layout.width)).textSelection(.enabled)\n                .workspaceMeasure("diff-content")\n            }\n            .workspaceMeasure("diff-scroll")\n        }')
frame = '.frame(minWidth: isOverlay ? 0 : 420, idealWidth: 920, minHeight: isOverlay ? 0 : 420, idealHeight: 650)'
once(frame, frame + '\n        .workspaceMeasure("panel")\n        .coordinateSpace(name: "workspace-panel")\n        .background(WorkspaceCoordinate(space: "workspace-panel"))')
# 原文件完整拼接，所有 private 声明保持原样；测试不访问/调用生产 model。
print(source)
checks = (root/'scripts/validation/WorkspaceChangesUIChecks.swift').read_text()
print(checks)
print('CHECKS:', hashlib.sha256(checks.encode()).hexdigest(), file=sys.stderr)
print('EXTRACT: 完整 Status（除 Preview）与 Changes，仅增加只读 geometry/坐标锚点；真实 NewPiCore，无 mock', file=sys.stderr)
PY
# Reader 的默认 HOME 可能由 Foundation 取自账号；显式配置定位可确保不读取用户 Git 配置。
# 此环境也不继承用户 DYLD、Git trace、仓库定位或 SwiftUI 测试开关。
cd "$TMP"
if env -i PATH=/usr/bin:/bin HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/home/.config" \
    LC_ALL=C GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
    "$TMP/check" "$TMP"; then
    exit 0
else
    RESULT=$?
    case "$RESULT" in
        1|2) exit "$RESULT" ;;
        *) echo "FAIL: 原生校验异常退出 $RESULT" >&2; exit 1 ;;
    esac
fi