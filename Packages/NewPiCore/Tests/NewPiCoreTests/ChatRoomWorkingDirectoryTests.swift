import Foundation
import Testing
@testable import NewPiCore

@Suite("ChatRoom working directory")
struct ChatRoomWorkingDirectoryTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("rejects empty and relative paths")
    func invalidPaths() {
        for path in ["", " ", "project", "../project"] {
            #expect(ChatRoomWorkingDirectory.issue(for: path) == .invalidPath)
        }
    }

    @Test("detects disappearance and recovery without creating the directory")
    func recovery() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let child = dir.appendingPathComponent("project")
        #expect(ChatRoomWorkingDirectory.issue(for: child.path) == .missing)
        #expect(!FileManager.default.fileExists(atPath: child.path))
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        #expect(ChatRoomWorkingDirectory.issue(for: child.path) == nil)
        try FileManager.default.removeItem(at: child)
        #expect(ChatRoomWorkingDirectory.issue(for: child.path) == .missing)
    }

    @Test("rejects a file used as the working directory")
    func regularFile() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("file")
        try Data().write(to: file)
        #expect(ChatRoomWorkingDirectory.issue(for: file.path) == .notDirectory)
    }

    @Test("valid symlinks work, broken links block execution")
    func symlinks() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("target")
        let link = dir.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(ChatRoomWorkingDirectory.issue(for: link.path) == nil)
        try FileManager.default.removeItem(at: target)
        #expect(ChatRoomWorkingDirectory.issue(for: link.path) != nil)
    }

    @Test("grouping normalizes spelling, not folder basename")
    func groups() {
        #expect(ChatRoomWorkingDirectory.groupID(for: "/a/project/") == "/a/project")
        #expect(ChatRoomWorkingDirectory.groupID(for: "/a/./project") == "/a/project")
        #expect(ChatRoomWorkingDirectory.groupID(for: "/a/project") != ChatRoomWorkingDirectory.groupID(for: "/b/project"))
    }

    @Test("home shorthand expands and missing directories retain their group")
    func homeAndMissing() {
        #expect(ChatRoomWorkingDirectory.issue(for: "~") == nil)
        let path = "/missing-\(UUID().uuidString)/project"
        #expect(ChatRoomWorkingDirectory.groupID(for: path) == path)
        #expect(ChatRoomWorkingDirectory.issue(for: path) == .missing)
    }
}
