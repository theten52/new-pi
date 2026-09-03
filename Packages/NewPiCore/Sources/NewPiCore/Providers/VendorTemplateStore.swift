import Foundation

/// 厂商模板 overlay：只存「被用户改过的内置模板」和「用户新增的模板」。
/// 未改动的内置模板不落盘，app 升级时内置模板更新能自动生效。
public struct VendorTemplateOverlay: Codable {
    public static let currentVersion = 1
    public var version: Int
    /// 模板 id → 完整模板（覆盖内置或用户新增）。
    public var templates: [String: VendorPreset]

    public init(version: Int = currentVersion, templates: [String: VendorPreset] = [:]) {
        self.version = version
        self.templates = templates
    }
}

/// 厂商模板持久化：内置模板 + overlay 覆盖，实现「编辑内置 + 恢复默认 + 自定义新增」。
///
/// 存储位置 `~/.new-pi/agent/vendor-templates.json`。overlay 语义：
/// - 内置模板按固定 id 匹配；被改过才写入 overlay，未改的仍用内置。
/// - 用户新增模板 id 不在内置集合里，始终写入 overlay。
/// - 「恢复默认」即删除该 id 的 overlay 条目。
public struct VendorTemplateStore {
    public var fileURL: URL

    public init(fileURL: URL = NewPiConfig.defaultAgentDirectory.appendingPathComponent("vendor-templates.json")) {
        self.fileURL = fileURL
    }

    /// 加载合并后的模板列表：内置 + overlay（按 id 覆盖/追加），按显示名排序。
    /// overlay 文件缺失或损坏时静默降级为纯内置模板（模板是锦上添花的数据，不阻断启动）。
    public func load() -> [VendorPreset] {
        var merged: [String: VendorPreset] = [:]
        for preset in VendorPresets.all {
            merged[preset.id] = preset
        }
        if let overlay = try? loadOverlay() {
            for (id, preset) in overlay.templates {
                merged[id] = preset
            }
        }
        return merged.values.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    /// 保存模板列表：只把与内置不同的（修改或新增）写入 overlay。
    public func save(_ templates: [VendorPreset]) throws {
        let builtin = Dictionary(uniqueKeysWithValues: VendorPresets.all.map { ($0.id, $0) })
        var overlayTemplates: [String: VendorPreset] = [:]
        for template in templates {
            if let original = builtin[template.id] {
                if template != original {
                    overlayTemplates[template.id] = template
                }
            } else {
                overlayTemplates[template.id] = template
            }
        }
        try saveOverlay(VendorTemplateOverlay(templates: overlayTemplates))
    }

    /// 恢复某个模板：删除其 overlay 条目（内置回落默认；自定义则删除）。
    public func reset(id: String) throws {
        var overlay = (try? loadOverlay()) ?? VendorTemplateOverlay()
        overlay.templates.removeValue(forKey: id)
        try saveOverlay(overlay)
    }

    /// 该 id 是否被 overlay 覆盖/新增（用于 UI 显示「已修改」标记与「恢复默认」按钮）。
    public func isOverridden(id: String) -> Bool {
        (try? loadOverlay())?.templates[id] != nil
    }

    private func loadOverlay() throws -> VendorTemplateOverlay {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return VendorTemplateOverlay()
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(VendorTemplateOverlay.self, from: data)
    }

    private func saveOverlay(_ overlay: VendorTemplateOverlay) throws {
        let directory = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(overlay)
        try data.write(to: fileURL, options: .atomic)
    }
}
