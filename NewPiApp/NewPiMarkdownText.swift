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

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text(hasProject ? "Start a session" : "Open a project")
                .font(.title3.weight(.semibold))
            Text(hasProject
                ? "Ask NewPi to read, edit, or run commands in your project. Sessions are saved automatically."
                : "Choose a project folder to load AGENTS.md, skills, and saved sessions.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}
