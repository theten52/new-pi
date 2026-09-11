import AppKit
import SwiftUI

/// 应用外观模式（跟随系统 / 浅色 / 深色）。
/// 默认跟随系统：macOS 系统切换浅/深色时 App 自动跟随（这正是此前 App 会出现在夜间模式的根源）。
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    /// 设置界面显示名
    var displayName: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    /// 对应的系统图标（设置界面 Picker 展示用）
    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }

    /// 映射到 NSAppearanceName
    var nsAppearanceName: NSAppearance.Name? {
        switch self {
        case .system: return nil
        case .light: return .aqua
        case .dark: return .darkAqua
        }
    }

    /// 映射到 SwiftUI ColorScheme 环境（用于 WebView CSS prefers-color-scheme 覆盖）
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// 外观模式管理器：负责持久化与全局应用。
/// 通过 UserDefaults 存储，默认值为 .system（跟随系统）。
@MainActor
final class AppearanceModeManager: ObservableObject {
    static let shared = AppearanceModeManager()
    private static let defaultsKey = "com.new-pi.appearanceMode"

    @Published var mode: AppearanceMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: Self.defaultsKey)
            apply(mode)
        }
    }

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.defaultsKey) ?? ""
        mode = AppearanceMode(rawValue: raw) ?? .system
    }

    /// 将持久化的外观模式应用到整个 App（NSApp + 所有窗口）。
    func applyOnLaunch() {
        apply(mode)
    }

    /// 切换外观。system 模式时清除自定义 appearance，恢复跟随系统。
    /// NSApp 在 SwiftUI App.init 阶段可能尚未创建（隐式解包为 nil 即崩），
    /// 此时跳过本次——启动路径由 AppDelegate 的 applicationWillFinishLaunching 再应用。
    private func apply(_ mode: AppearanceMode) {
        guard let app = NSApp else { return }
        app.appearance = mode.nsAppearanceName.flatMap { NSAppearance(named: $0) }
    }
}
