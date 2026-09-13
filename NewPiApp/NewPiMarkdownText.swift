import AppKit
import SwiftUI

extension Color {
    /// 由"轮对话"锚点 id 确定性派生柔和浅色气泡背景色（BACKLOG-BUBBLE-BG）。
    /// 同轮对话内输入/输出气泡同色、跨轮异色、重启后稳定。
    /// 低饱和 + 高亮 + 低不透明 = 浅色柔和。
    static func bubbleTint(for anchorID: UUID) -> Color {
        Color(hue: deterministicHue(for: anchorID), saturation: 0.20, brightness: 0.98, opacity: 0.20)
    }

    /// FNV-1a 哈希把 UUID 字符串映射到 [0,1) 的色相，确定性（不依赖 Swift 随机 hashValue，
    /// 后者每次启动都会变）。
    private static func deterministicHue(for anchorID: UUID) -> Double {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in anchorID.uuidString.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return Double(hash % 360) / 360.0
    }

    /// 色相度数（0-359）：供单文档 transcript 把同一套确定性配色传给 CSS hsl()。
    static func bubbleTintHueDegrees(for anchorID: UUID) -> Int {
        Int(deterministicHue(for: anchorID) * 360) % 360
    }
}

struct NewPiChatEmptyStateView: View {
    var hasProject: Bool
    var onSuggestion: ((String) -> Void)? = nil
    var suggestionsEnabled = true
    var projectName: String? = nil

    static let suggestions: [(title: String, icon: String, prompt: String)] = [
        ("理解项目结构", "folder", "请先梳理这个项目的结构和主要入口。"),
        ("检查最近的改动", "doc.text.magnifyingglass", "检查最近的代码改动，先列出风险，不修改文件。"),
        ("一起定位问题", "bubble.left", "帮我定位一个问题：")
    ]

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 14) {
            Text("n·")
                .font(.system(size: 27, weight: .semibold, design: .rounded))
                .foregroundStyle(NewPiWorkbenchStyle.accent)
                .frame(width: 47, height: 47)
                .background(NewPiWorkbenchStyle.accentSoft, in: RoundedRectangle(cornerRadius: 13))
                .padding(.bottom, 11)
            Text("NEW SESSION" + (projectName.map { " / \($0)" } ?? ""))
                .font(.system(size: 11))
                .tracking(2)
                .foregroundStyle(.secondary)
            Text(hasProject ? "今天，我们从哪里开始？" : "选择你的工作项目")
                .font(.system(size: 25, weight: .medium))
            Text(hasProject
                ? "项目已就绪。描述一个问题、一处改动，\n或者先一起理解这份代码。"
                : "从侧边栏打开项目文件夹，加载项目指令、技能与已保存的会话。")
                .foregroundStyle(.secondary)
                .lineSpacing(5)
                .frame(maxWidth: 420)
            if hasProject, let onSuggestion {
                ForEach(Self.suggestions, id: \.title) { suggestion in
                    Button {
                        onSuggestion(suggestion.prompt)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: suggestion.icon)
                            Text(suggestion.title)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                        }
                        .padding(12)
                        .frame(maxWidth: 420, alignment: .leading)
                        .background(NewPiWorkbenchStyle.surfaceRaised, in: RoundedRectangle(cornerRadius: 8))
                        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(NewPiWorkbenchStyle.line) }
                    }
                    .buttonStyle(.plain)
                    .disabled(!suggestionsEnabled)
                    .help(suggestionsEnabled ? "仅填入草稿，不会自动发送" : "已有草稿，请先处理当前输入")
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(32)
        }
        .background(NewPiWorkbenchStyle.surface)
    }
}
