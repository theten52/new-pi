#!/bin/bash
# 提取生产状态声明/初始化/绑定/Session 提交守卫，真实重建 SwiftUI/NSTextView；不访问用户会话。
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
import os, re, subprocess, sys
root, tmp = map(Path, sys.argv[1:])
revision = os.environ.get('NEWPI_DRAFT_REVISION')
def read(name):
    path = 'NewPiApp/' + name
    return subprocess.check_output(['git', '-C', str(root), 'show', revision+':'+path], text=True) if revision else (root/path).read_text()
chat = read('NewPiChatView.swift')
app = read('NewPiApp.swift')
vm = read('NewPiViewModel.swift')
(tmp/'Controller.swift').write_text(read('NewPiChatRoomStore.swift'))
types = vm[vm.index('enum NewPiToolState:'):vm.index('struct NewPiProviderListItem:')]
runtime = vm[vm.index('struct TokenRateTracker {'):vm.index('/// 后台构建一个全新 Session')]
activity = vm[vm.index('enum NewPiAgentActivity:'):vm.index('@MainActor\nfinal class NewPiViewModel:')]
(tmp/'Runtime.swift').write_text('import AppKit\nimport SwiftUI\nimport NewPiCore\n'+types+runtime+activity)
composer = chat[chat.index('struct NewPiComposerTextView:'):chat.index('#Preview', chat.index('struct NewPiComposerTextView:'))]
(tmp/'Composer.swift').write_text('import AppKit\nimport SwiftUI\nimport NewPiCore\nimport UniformTypeIdentifiers\n'+composer)
start = chat.index('struct NewPiSessionPanel:')
session = chat[start:chat.index('    private var userMessageMarkers:', start)].replace('struct NewPiSessionPanel:', 'struct SessionDraftFixture:', 1)
start = app.index('struct ChatRoomDetailView:')
room = app[start:app.index('    private var runtime:', start)].replace('struct ChatRoomDetailView:', 'struct RoomDraftFixture:', 1)
session_binding = re.search(r'NewPiComposerTextView\(\s*text:\s*([^,]+),', chat).group(1).strip()
room_binding = re.search(r'NewPiComposerTextView\(\s*text:\s*([^,]+),', app[start:]).group(1).strip()
attachments = re.search(r'NewPiDraftAttachmentStrip\(drafts:\s*([^\)]+)\)', chat).group(1).strip()
send_start = chat.index('    private func sendComposerInput()')
send = chat[send_start:chat.index('    // MARK: - 图片附件采集', send_start)]
def body(binding, attachment_binding, submit):
    return f'''    var body: some View {{
        NewPiComposerTextView(text: {binding}, onSubmit: {submit})
            .frame(height: NewPiComposerScrollView.fixedHeight)
            .onAppear {{
                ProbeBindings.text = {binding}
                ProbeBindings.attachments = {attachment_binding}
            }}
    }}
'''
(tmp/'Fixtures.swift').write_text('import SwiftUI\nimport NewPiCore\n'+session+body(session_binding, attachments, 'sendComposerInput')+send+'}\n'+room+body(room_binding, 'nil', '{}')+'}\n')
print('DRAFT SOURCE:', revision or 'working tree')
PY
xcrun swiftc -swift-version 6 -parse-as-library -I "$BIN/Modules" \
  "$TMP/Runtime.swift" "$TMP/Controller.swift" "$TMP/Composer.swift" "$TMP/Fixtures.swift" \
  "$ROOT/NewPiApp/NewPiComposerDraft.swift" "$ROOT/NewPiApp/ImageAttachmentProcessor.swift" \
  "$ROOT/scripts/validation/DraftNavigationChecks.swift" \
  "$BIN"/NewPiCore.build/*.o -o "$TMP/check"
"$TMP/check"