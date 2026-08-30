import Foundation
import Testing
@testable import NewPiCore

/// 附件 note（缩放/坐标映射提示）随 image 块以 text 块下发（BACKLOG-IMAGE-INPUT）。
/// 三种 provider 序列化同构：`[text(正文), image(块), text(note)]`。
@Suite("Image attachment note encoding")
struct ImageAttachmentNoteEncodingTests {
    /// 在默认附件根目录下建 uuid 隔离的临时附件（encoder 读盘走 SessionAttachments），
    /// 测试后清理；uuid 隔离不与真实会话数据冲突。
    private func withTempAttachment(_ body: (MessageAttachment) throws -> Void) throws {
        let sessionID = UUID()
        let dir = try SessionAttachments.directory(for: sessionID)
        let fileName = "\(UUID().uuidString).png"
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(
            to: dir.appendingPathComponent(fileName)
        )
        defer { try? FileManager.default.removeItem(at: dir) }
        let attachment = MessageAttachment(
            mediaType: "image/png",
            path: "\(sessionID.uuidString)/\(fileName)",
            displayName: "test.png",
            note: "[Image: original 3000x2000, sent at 1568x1045. Multiply coordinates by 1.91 to map to the original image.]"
        )
        try body(attachment)
    }

    @Test("Anthropic: note follows image block as text block")
    func anthropicNoteBlock() throws {
        try withTempAttachment { attachment in
            let encoded = AnthropicMessageEncoder.encodeMessages([
                .user(UserMessage(content: "看图", attachments: [attachment]))
            ])
            let content = try #require(encoded[0]["content"] as? [[String: Any]])
            #expect(content.count == 3)
            #expect(content[0]["type"] as? String == "text")
            #expect(content[0]["text"] as? String == "看图")
            #expect(content[1]["type"] as? String == "image")
            #expect(content[2]["type"] as? String == "text")
            #expect(content[2]["text"] as? String == attachment.note)
        }
    }

    @Test("OpenAI compatible: note follows image_url block as text block")
    func openAICompatibleNoteBlock() throws {
        try withTempAttachment { attachment in
            let encoded = OpenAIMessageEncoder.encodeMessages([
                .user(UserMessage(content: "看图", attachments: [attachment]))
            ])
            let content = try #require(encoded[0]["content"] as? [[String: Any]])
            #expect(content.count == 3)
            #expect(content[0]["type"] as? String == "text")
            #expect(content[1]["type"] as? String == "image_url")
            #expect(content[2]["type"] as? String == "text")
            #expect(content[2]["text"] as? String == attachment.note)
        }
    }

    @Test("Responses: note follows input_image block as input_text block")
    func responsesNoteBlock() throws {
        try withTempAttachment { attachment in
            let encoded = ResponsesMessageEncoder.encodeInput([
                .user(UserMessage(content: "看图", attachments: [attachment]))
            ])
            // encodeInput 外层是 message item，content 在其下。
            let item = try #require(encoded.first { ($0["role"] as? String) == "user" })
            let content = try #require(item["content"] as? [[String: Any]])
            #expect(content.count == 3)
            #expect(content[0]["type"] as? String == "input_text")
            #expect(content[1]["type"] as? String == "input_image")
            #expect(content[2]["type"] as? String == "input_text")
            #expect(content[2]["text"] as? String == attachment.note)
        }
    }

    @Test("no note: image block alone, no extra text block")
    func noNoteNoExtraBlock() throws {
        try withTempAttachment { attachment in
            let encoded = AnthropicMessageEncoder.encodeMessages([
                .user(UserMessage(content: "看图", attachments: [attachment.withoutNote()]))
            ])
            let content = try #require(encoded[0]["content"] as? [[String: Any]])
            #expect(content.count == 2)
            #expect(content.last?["type"] as? String == "image")
        }
    }

    @Test("legacy attachment JSON without note decodes with nil note")
    func legacyDecodeWithoutNote() throws {
        let json = #"{"kind":"image","mediaType":"image/png","path":"s/x.png","displayName":"x.png"}"#
        let attachment = try JSONDecoder().decode(MessageAttachment.self, from: Data(json.utf8))
        #expect(attachment.note == nil)
        #expect(attachment.displayName == "x.png")
    }

    @Test("note roundtrips through Codable")
    func noteRoundtrip() throws {
        let attachment = MessageAttachment(
            mediaType: "image/jpeg",
            path: "s/y.jpg",
            displayName: "y.jpg",
            note: "[Image: original 100x100, sent at 100x100.]"
        )
        let data = try JSONEncoder().encode(attachment)
        let decoded = try JSONDecoder().decode(MessageAttachment.self, from: data)
        #expect(decoded == attachment)
    }
}

extension MessageAttachment {
    /// 测试助手：剥掉 note。
    fileprivate func withoutNote() -> MessageAttachment {
        MessageAttachment(mediaType: mediaType, path: path, displayName: displayName, note: nil)
    }
}
