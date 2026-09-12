import AppKit
import ImageIO

// 使用真实可解码图片，不访问剪贴板、用户文件或模型。
@main struct AttachmentProcessingChecks {
    struct Failure: Error { let message: String }
    static func require(_ value: Bool, _ message: String) throws {
        guard value else { throw Failure(message: message) }
        print("PASS: \(message)")
    }
    static func image(width: Int, height: Int, format: NSBitmapImageRep.FileType) throws -> Data {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let bytes = bitmap.bitmapData else {
            throw Failure(message: "无法创建测试图片")
        }
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bitmap.bytesPerRow + x * 4
                bytes[offset] = UInt8(x % 256)
                bytes[offset + 1] = UInt8(y % 256)
                bytes[offset + 2] = 96
                bytes[offset + 3] = 255
            }
        }
        guard let data = bitmap.representation(using: format, properties: [:]) else { throw Failure(message: "编码失败") }
        return data
    }
    static func size(_ data: Data) throws -> (Int, Int) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure(message: "真实解码失败") }
        return (image.width, image.height)
    }
    static func main() throws {
        let small = try image(width: 320, height: 160, format: .png)
        for (format, mime) in [(NSBitmapImageRep.FileType.png, "image/png"), (.jpeg, "image/jpeg")] {
            let data = try image(width: 320, height: 160, format: format)
            guard let draft = ImageAttachmentProcessor.makeDraft(from: data, displayName: "fixture") else { throw Failure(message: "有效图片被拒绝") }
            try require(draft.data == data && draft.mediaType == mime && draft.note == nil, "小图原样保留：\(mime)")
            let dimensions = try size(draft.data)
            try require(dimensions.0 == 320 && dimensions.1 == 160 && ImageAttachmentProcessor.validate(draft) == nil, "输出可解码且通过体积校验")
        }
        let large = try image(width: 3136, height: 1568, format: .png)
        guard let resized = ImageAttachmentProcessor.makeDraft(from: large, displayName: "large.png") else { throw Failure(message: "大图处理失败") }
        let dimensions = try size(resized.data)
        try require(dimensions.0 == 1568 && dimensions.1 == 784, "大图等比缩至1568×784")
        try require(resized.note?.contains("2.00") == true && ImageAttachmentProcessor.validate(resized) == nil, "缩放说明与base64体积预算有效")
        try require(ImageAttachmentProcessor.makeDraft(from: Data("not an image".utf8), displayName: "invalid.png") == nil, "拒绝无效图片")
        let limit = ImageAttachmentProcessor.maxAttachmentBytes
        let largestRaw = limit / 4 * 3
        for count in [0, 1, 2, 3, largestRaw, largestRaw + 1] {
            try require(ImageAttachmentProcessor.base64EncodedSize(ofByteCount: count) == Data(count: count).base64EncodedData().count, "base64预算计算：\(count) bytes")
        }
        let oversized = DraftImageAttachment(data: Data(count: largestRaw + 1), displayName: "oversized.png", mediaType: "image/png")
        try require(ImageAttachmentProcessor.validate(oversized) != nil, "拒绝编码后超5MiB草稿")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("fixture.png")
        try small.write(to: file)
        try require(ImageAttachmentProcessor.makeDraft(fromFileURL: file)?.data == small, "生产文件采集入口读取生成图片")
        try require(ImageAttachmentProcessor.makeDraft(fromFileURL: directory.appendingPathComponent("missing.png")) == nil, "缺失文件返回nil")
        print("PASS: 图片处理验收；未覆盖剪贴板、拖放、预览和网络发送")
    }
}