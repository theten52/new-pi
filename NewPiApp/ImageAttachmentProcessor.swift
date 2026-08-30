import AppKit
import Foundation
import ImageIO
import NewPiCore
import UniformTypeIdentifiers

/// 用户在 composer 里选中的「待发送」图片草稿。
/// 与已落盘的 `MessageAttachment` 不同，这里还持有原始数据，发送时才落盘。
struct DraftImageAttachment: Identifiable, Equatable {
    let id: UUID
    /// 原始图片数据（解码后；用于展示缩略图与后续落盘）。
    let data: Data
    /// 原始文件名（展示用）。
    let displayName: String
    /// 推断出的 MIME 类型。
    let mediaType: String
    /// 附给模型的说明文本（缩放后的坐标映射提示；nil = 未做处理，原样透传）。
    let note: String?

    init(
        id: UUID = UUID(),
        data: Data,
        displayName: String,
        mediaType: String,
        note: String? = nil
    ) {
        self.id = id
        self.data = data
        self.displayName = displayName
        self.mediaType = mediaType
        self.note = note
    }
}

/// 图片附件的解码、缩放、压缩处理（BACKLOG-IMAGE-INPUT）。
///
/// 策略（对标 pi agent / osaurus 的实现，见 docs/multi-modal-vision-plan.md）：
/// 1. **原样优先**：尺寸与 base64 体积均在预算内 → 不动字节（重编码只会更大或不可控）；
/// 2. **双编码取小**：需要处理时 PNG 与 JPEG 都编码，取满足体积预算的最小者
///    （截图类 PNG 转 JPEG 常省 3-5 倍；JPEG 走质量阶梯 0.85→0.4 逐档下降）；
/// 3. **尺寸递减兜底**：最低质量仍超预算 → 长边 ×0.75 循环，直到满足或 1×1；
/// 4. **体积口径 = base64 后字节**：Anthropic 单图限制 5MB 按 base64 编码后计
///    （膨胀 ×4/3），校验与预算都用同一口径，杜绝「原始 4.9MB → 编码后 6.5MB → 400」；
/// 5. **坐标映射提示**：发生缩放时生成 note（pi 的 formatDimensionNote 同款），
///    随 image 块以 text 块下发，模型输出的坐标可映射回原图。
enum ImageAttachmentProcessor {
    /// 单附件允许的最大体积（**base64 编码后**字节；Anthropic 单图 5MB 口径）。
    static let maxAttachmentBytes = 5 * 1024 * 1024
    /// 缩放目标：最长边像素上限（Anthropic 推荐长边上限；超过会被服务端不可控地缩小）。
    static let maxDimension: CGFloat = 1568
    /// JPEG 重编码质量阶梯（先高后低，逐档尝试直到满足体积预算）。
    static let jpegQualitySteps: [CGFloat] = [0.85, 0.7, 0.55, 0.4]

    /// base64 编码后字节数（每 3 字节膨胀为 4 字符），不做真编码。
    static func base64EncodedSize(ofByteCount count: Int) -> Int {
        (count + 2) / 3 * 4
    }

    /// 从原始数据构造草稿附件：原样可发则透传；否则解码 + 缩放 + 双编码取小。
    /// 返回 nil 表示数据不可解码为图片。
    static func makeDraft(from data: Data, displayName: String) -> DraftImageAttachment? {
        let mediaType = Self.inferMediaType(from: data) ?? "image/png"
        let originalSize = Self.pixelSize(of: data)

        // 原样优先：尺寸与 base64 体积均在预算内 → 不动字节。
        if let size = originalSize,
           CGFloat(size.width) <= maxDimension, CGFloat(size.height) <= maxDimension,
           base64EncodedSize(ofByteCount: data.count) <= maxAttachmentBytes {
            return DraftImageAttachment(data: data, displayName: displayName, mediaType: mediaType)
        }

        guard let image = NSImage(data: data) else { return nil }
        if let processed = Self.processedData(from: image) {
            let origin = originalSize ?? (width: processed.width, height: processed.height)
            return DraftImageAttachment(
                data: processed.data,
                displayName: displayName,
                mediaType: processed.mediaType,
                note: Self.dimensionNote(original: origin, output: (processed.width, processed.height))
            )
        }
        // 极端兜底：解得出 NSImage 但重编码全失败 → 原样透传（validate 兜底校验）。
        return DraftImageAttachment(data: data, displayName: displayName, mediaType: mediaType)
    }

    /// 从文件 URL 构造草稿（读文件 → 解码 → 缩放压缩）。
    static func makeDraft(fromFileURL url: URL) -> DraftImageAttachment? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return makeDraft(from: data, displayName: url.lastPathComponent)
    }

    /// 落盘前校验：按 base64 后字节口径（与 provider 限制一致）。
    /// 正常流程处理管道已保证满足，此处仅兜底（如极端兜底透传的原图）。
    static func validate(_ draft: DraftImageAttachment) -> String? {
        guard base64EncodedSize(ofByteCount: draft.data.count) <= maxAttachmentBytes else {
            return "图片「\(draft.displayName)」编码后超过 5MB，请压缩后再试。"
        }
        return nil
    }

    // MARK: - 处理管道

    /// 缩放 + 重编码：PNG / JPEG 双编码取满足预算的最小者；全超则尺寸 ×0.75 循环。
    /// 返回 nil 表示完全无法处理。
    private static func processedData(from image: NSImage) -> (data: Data, mediaType: String, width: Int, height: Int)? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let maxEdge = max(width, height)
        let scale = maxEdge > maxDimension ? maxDimension / maxEdge : 1.0
        var targetWidth = max(1, Int(width * scale))
        var targetHeight = max(1, Int(height * scale))

        while true {
            guard let rep = Self.bitmapRep(from: image, width: targetWidth, height: targetHeight) else {
                return nil
            }
            // 双编码取小（pi 策略）：PNG 保截图文字锐利，JPEG 压照片更小；
            // 质量阶梯逐档下降，取**满足预算的候选中最小者**。
            var best: (data: Data, mediaType: String)?
            if let png = rep.representation(using: .png, properties: [:]),
               base64EncodedSize(ofByteCount: png.count) <= maxAttachmentBytes {
                best = (png, "image/png")
            }
            for quality in jpegQualitySteps {
                guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: quality]),
                      base64EncodedSize(ofByteCount: jpeg.count) <= maxAttachmentBytes else { continue }
                if best == nil || jpeg.count < best!.data.count {
                    best = (jpeg, "image/jpeg")
                }
            }
            if let best {
                return (best.data, best.mediaType, targetWidth, targetHeight)
            }
            // 最低质量仍超预算：尺寸 ×0.75 递减重试，直到 1×1（此时 PNG 必然几十字节级，
            // 数学上不可能仍超 5MB；循环上限由 1×1 分支终止）。
            if targetWidth == 1, targetHeight == 1 { break }
            targetWidth = max(1, targetWidth * 3 / 4)
            targetHeight = max(1, targetHeight * 3 / 4)
        }
        return nil
    }

    /// 以指定尺寸把 NSImage 绘制进新的位图（等比缩放已由调用方算好）。
    private static func bitmapRep(from image: NSImage, width: Int, height: Int) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(
            in: NSRect(x: 0, y: 0, width: width, height: height),
            from: .zero,
            operation: .copy,
            fraction: 1.0
        )
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    // MARK: - 元数据

    /// Header-only 读图片像素尺寸（不整图解码，比 NSImage 解码高效；osaurus 同款）。
    private static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }

    /// 缩放说明（pi 的 formatDimensionNote 同款）：模型输出的坐标乘 scale 映射回原图。
    private static func dimensionNote(
        original: (width: Int, height: Int),
        output: (width: Int, height: Int)
    ) -> String? {
        guard original.width != output.width || original.height != output.height else { return nil }
        let scale = Double(original.width) / Double(output.width)
        let formatted = String(format: "%.2f", scale)
        return "[Image: original \(original.width)x\(original.height), sent at \(output.width)x\(output.height). Multiply coordinates by \(formatted) to map to the original image.]"
    }

    /// 依据魔数嗅探常见图片格式。
    private static func inferMediaType(from data: Data) -> String? {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "image/gif" }
        if bytes.count >= 12, bytes[8 ... 11] == [0x57, 0x45, 0x42, 0x50] { return "image/webp" }
        return nil
    }
}

/// 从剪贴板读取图片数据（Cmd+V 粘贴路径）。
enum PasteboardImageReader {
    /// 按优先级读取剪贴板中的图片数据。返回 nil 表示剪贴板无图片。
    ///
    /// 优先读 `.png`（截图工具的原始格式、体积小、魔数可识别），其后再读 `.tiff`。
    /// 若优先读 `.tiff`，Snipaste 等截图常会同时放一份 **17MB 级**的 TIFF 到剪贴板，
    /// 导致 `paste()` 在主线程同步解码/重编码时明显卡顿，甚至被感知为「粘贴不生效」；
    /// 且 `inferMediaType` 的魔数表不识别 TIFF，会错走默认 mediaType 分支。
    static func readImageData() -> Data? {
        let pasteboard = NSPasteboard.general
        
        // 常见图片 pasteboard 类型（按优先级排列）：
        // 1. 标准 UTI 类型（public.png 等）
        // 2. 非标准但广泛支持的类型（image/png 等 MIME 类型）
        // 3. 应用自定义类型（Qt、Snipaste 等）
        let types: [NSPasteboard.PasteboardType] = [
            .png,                                                          // public.png
            .tiff,                                                         // public.tiff
            NSPasteboard.PasteboardType("public.jpeg"),                   // JPEG UTI
            NSPasteboard.PasteboardType("image/png"),                     // MIME 类型（某些应用使用）
            NSPasteboard.PasteboardType("image/tiff"),                    // MIME 类型
            NSPasteboard.PasteboardType("image/jpeg"),                    // MIME 类型
            NSPasteboard.PasteboardType("Apple PNG pasteboard type"),     // 旧版 macOS / 某些工具
            NSPasteboard.PasteboardType("com.trolltech.anymime.image--png"),  // Qt/Snipaste
            NSPasteboard.PasteboardType("NeXT TIFF v4.0 pasteboard type"),   // 旧版 NeXT
            NSPasteboard.PasteboardType("com.apple.pasteboard.tiff"),    // Apple TIFF 变体
        ]
        
        for type in types {
            if let data = pasteboard.data(forType: type), !data.isEmpty {
                // 验证数据是否为有效图片（通过魔数检查）
                if Self.isValidImageData(data) {
                    return data
                }
            }
        }
        
        // 兜底 1：尝试用 NSImage(pasteboard:) 读取（处理非标准格式）
        if let image = NSImage(pasteboard: pasteboard),
           let tiffData = image.tiffRepresentation {
            // NSImage 成功读取，返回 TIFF 数据（后续会被 ImageAttachmentProcessor 处理）
            return tiffData
        }
        
        // 兜底 2：读取任意可读文件 URL 指向图片的场景（拖拽文件后的剪贴板）。
        if let url = pasteboard.readObjects(forClasses: [NSURL.self], options: nil)?.first as? URL,
           url.pathExtension.lowercased().isImageExtension {
            return try? Data(contentsOf: url)
        }
        
        return nil
    }
    
    /// 检查数据是否为有效图片（通过魔数嗅探）。
    private static func isValidImageData(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(12))
        // PNG: 89 50 4E 47 0D 0A 1A 0A
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return true }
        // JPEG: FF D8 FF
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return true }
        // GIF: 47 49 46 38
        if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) { return true }
        // TIFF: 49 49 2A 00 (little-endian) 或 4D 4D 00 2A (big-endian)
        if bytes.starts(with: [0x49, 0x49, 0x2A, 0x00]) || bytes.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) { return true }
        // BMP: 42 4D
        if bytes.starts(with: [0x42, 0x4D]) { return true }
        // WebP: 52 49 46 46 ... 57 45 42 50
        if bytes.count >= 12, bytes[0...3] == [0x52, 0x49, 0x46, 0x46], bytes[8...11] == [0x57, 0x45, 0x42, 0x50] { return true }
        return false
    }
}

// MARK: - String 扩展
private extension String {
    /// 检查文件扩展名是否为常见图片格式。
    var isImageExtension: Bool {
        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "webp", "heic", "heif"]
        return imageExtensions.contains(self.lowercased())
    }
}
