#!/bin/bash
# 提取真实 VM 业务方法；无窗口、无用户 App、无 renderer 测试、无网络。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT/Packages/NewPiCore"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
SCRATCH="${NEWPI_VALIDATION_SCRATCH:-/private/tmp/newpi-retry-vm-spm}"
swift build --scratch-path "$SCRATCH" --target NewPiCore
BIN="$(swift build --scratch-path "$SCRATCH" --show-bin-path)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
python3 - "$ROOT" "$TMP" <<'PY'
from pathlib import Path
import sys
root, tmp = map(Path, sys.argv[1:])
source = (root/'NewPiApp/NewPiViewModel.swift').read_text()
types = source[source.index('enum NewPiToolState:'):source.index('struct NewPiProviderListItem:')]
runtime = source[source.index('struct TokenRateTracker {'):source.index('/// 后台构建一个全新 Session')]
helpers = source[source.index('private func detailTurnID('):source.index('enum NewPiAgentActivity:')].replace('private func ', 'func ')
activity = source[source.index('enum NewPiAgentActivity:'):source.index('@MainActor\nfinal class NewPiViewModel:')]
names = ['retryError', 'handle', 'syncTranscriptMessageIndices', 'calibrateTranscriptAfterAgentEnd',
         'rebuildTranscript', 'preservedTranscriptID', 'restoringErrors', 'appendTruncatedOutputNoticeIfNeeded',
         'streamingFlushIntervalMS', 'enqueueStreamingDelta', 'enqueueThinkingDelta', 'pokeStreamingFlushFromBackground',
         'scheduleStreamingFlush', 'flushStreamingDelta', 'storeFlushTarget', 'commitLiveTranscript',
         'transcriptTintHues', 'appendOrUpdateAssistant', 'appendOrUpdateThinking', 'freezeStreamingThinking',
         'ensureDetailGroupMarker', 'finalizeDetailGroup', 'appendTranscript']
lines = source.splitlines(keepends=True)
methods = []
for index, line in enumerate(lines):
    if not line.startswith('    ') or line.startswith('        '): continue
    if not any('func '+name+'(' in line for name in names): continue
    end = next(i for i in range(index+1, len(lines)) if lines[i].rstrip() == '    }')
    annotation = lines[index-1] if index > 0 and lines[index-1].strip() == '@discardableResult' else ''
    methods.append(annotation+''.join(lines[index:end+1]).replace('    private ', '    ', 1))
stubs = '''
@MainActor final class NewPiComposerDraft: ObservableObject {}
@MainActor final class TranscriptDocumentController {
    func endLiveApply() {}
    func beginLatencyTrace(_ trace: RequestLatencyTrace, firstTextItemID: UUID?) {}
    func applyLive(items: [NewPiTranscriptItem], isStreaming: Bool, streamingBubbleComplete: Bool, tintHues: [UUID: Int]) {}
}
extension Color { static func bubbleTintHueDegrees(for id: UUID) -> Int { 0 } }
@MainActor final class VMHarness {
    var activeRuntime: SessionRuntime?
    var activeProfile: ProviderProfile?
    var transcript: [NewPiTranscriptItem] = []
    var agentActivity: NewPiAgentActivity = .idle
    var tokenRateText: String?
    var branchPointCount = 0
    var isForkedBranch = false
    func effectiveModelConfig(for profile: ProviderProfile) -> ModelConfig { profile.modelConfig }
    func reflectActive() { transcript = activeRuntime?.transcript ?? [] }
    func startTokenRateRefresh() {}
    func stopTokenRateRefresh() {}
    func autoLabelCurrentSessionIfNeeded(on runtime: SessionRuntime) async {}
    func refreshSessionList() async {}
'''
(tmp/'Production.swift').write_text('import Foundation\nimport SwiftUI\nimport NewPiCore\n'+types+runtime+helpers+activity+stubs+'\n'.join(methods)+'\n}\n')
PY
xcrun swiftc -swift-version 6 -parse-as-library -I "$BIN/Modules" \
  "$TMP/Production.swift" "$ROOT/scripts/validation/SessionRetryVMChecks.swift" \
  "$BIN"/NewPiCore.build/*.o -o "$TMP/check"
"$TMP/check"