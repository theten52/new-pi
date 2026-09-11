import Foundation
import Testing
@testable import NewPiCore

@Suite("EditSnapshotStore retention")
struct EditSnapshotStoreTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapshot-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeFile(_ root: URL, _ path: String, text: String = "original") throws -> URL {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private func snapshots(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "snapshot" }
            .map { $0.standardizedFileURL.resolvingSymlinksInPath() }
    }

    @Test("automatic pruning isolates files with the same name")
    func sameNameIsolation() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try makeFile(root, "moduleA/index.ts", text: "module A")
        let b = try makeFile(root, "moduleB/index.ts")
        let store = EditSnapshotStore.forProject(root, retentionPolicy: .init(maxPerFile: 2, maxAgeDays: nil))
        let savedA = try store.snapshotBeforeEdit(sourceFile: a)
        var savedB: [URL] = []
        for index in 0..<5 {
            try "B \(index)".write(to: b, atomically: true, encoding: .utf8)
            savedB.append(try store.snapshotBeforeEdit(sourceFile: b))
        }
        let latestB = try #require(savedB.last)
        #expect(savedA.deletingLastPathComponent() != latestB.deletingLastPathComponent())
        #expect(try String(contentsOf: savedA, encoding: .utf8) == "module A")
        #expect(try String(contentsOf: latestB, encoding: .utf8) == "B 4")
        #expect(try snapshots(in: savedA.deletingLastPathComponent()).count == 1)
        #expect(try snapshots(in: latestB.deletingLastPathComponent()).count == 2)
        #expect(!FileManager.default.fileExists(atPath: savedB[0].path))
    }

    @Test("rapid snapshots are unique and retain the original bytes")
    func rapidSnapshots() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try makeFile(root, "Some-File.swift")
        let store = EditSnapshotStore.forProject(root, retentionPolicy: .unlimited)
        var saved: [URL] = []
        for index in 0..<10 {
            try "version \(index)".write(to: file, atomically: true, encoding: .utf8)
            saved.append(try store.snapshotBeforeEdit(sourceFile: file))
        }
        #expect(Set(saved).count == 10)
        for (index, url) in saved.enumerated() {
            #expect(try String(contentsOf: url, encoding: .utf8) == "version \(index)")
        }
        let metadata = try #require(saved.first).deletingLastPathComponent().appendingPathComponent("source-path.txt")
        #expect(try String(contentsOf: metadata, encoding: .utf8) == file.standardizedFileURL.resolvingSymlinksInPath().path)
        #expect(store.prune().isEmpty)
    }

    @Test("default policy keeps twenty snapshots per source")
    func defaultPolicy() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try makeFile(root, "source.txt")
        let store = EditSnapshotStore.forProject(root)
        var saved: [URL] = []
        for _ in 0..<22 {
            saved.append(try store.snapshotBeforeEdit(sourceFile: file))
        }
        let latest = try #require(saved.last)
        #expect(try snapshots(in: latest.deletingLastPathComponent()).count == 20)
        #expect(try String(contentsOf: latest, encoding: .utf8) == "original")
    }

    @Test("path aliases share one quota")
    func canonicalPath() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try makeFile(root, "src/index.ts")
        let alias = root.appendingPathComponent("alias.ts")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: file)
        let store = EditSnapshotStore.forProject(root, retentionPolicy: .init(maxPerFile: 1, maxAgeDays: nil))
        let first = try store.snapshotBeforeEdit(sourceFile: file)
        let second = try store.snapshotBeforeEdit(sourceFile: alias)
        #expect(first.deletingLastPathComponent() == second.deletingLastPathComponent())
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(try String(contentsOf: second, encoding: .utf8) == "original")
    }

    @Test("per-file cap orders snapshots by backup time, not source modification time")
    func perFileCap() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try makeFile(root, "index.ts")
        var store = EditSnapshotStore.forProject(root, retentionPolicy: .unlimited)
        var saved: [URL] = []
        for index in 0..<5 {
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)],
                ofItemAtPath: file.path)
            let url = try store.snapshotBeforeEdit(sourceFile: file)
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
            #expect(try #require(values.contentModificationDate).timeIntervalSince1970 > 1)
            // 固定排序时间，测试不依赖文件系统时间精度或 sleep。
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(index + 10))],
                ofItemAtPath: url.path)
            saved.append(url)
        }
        store.retentionPolicy = .init(maxPerFile: 2, maxAgeDays: nil)
        #expect(Set(store.prune()) == Set(saved.prefix(3)))
        #expect(Set(try snapshots(in: saved[0].deletingLastPathComponent())) == Set(saved.suffix(2)))
    }

    @Test("age cleanup applies to managed snapshots and keeps the boundary")
    func ageCap() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try makeFile(root, "source.txt")
        var store = EditSnapshotStore.forProject(root, retentionPolicy: .unlimited)
        let seed = try store.snapshotBeforeEdit(sourceFile: file)
        let directory = seed.deletingLastPathComponent()
        try FileManager.default.removeItem(at: seed)
        var fixtures: [URL] = []
        for stamp in ["2026-08-10T23-59-59Z", "2026-08-11T00-00-00Z", "2026-09-10T00-00-00Z"] {
            let url = directory.appendingPathComponent("\(stamp)-\(UUID().uuidString).snapshot")
            try Data("backup".utf8).write(to: url)
            fixtures.append(url)
        }
        store.retentionPolicy = .init(maxPerFile: nil, maxAgeDays: 30)
        let now = try #require(ISO8601DateFormatter().date(from: "2026-09-10T00:00:00Z"))
        #expect(store.prune(now: now) == [fixtures[0]])
        #expect(Set(try snapshots(in: directory)) == Set(fixtures.suffix(2)))
    }

    @Test("legacy snapshots and unknown entries are never automatically deleted")
    func legacyPreservation() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try makeFile(root, "index.ts")
        let store = EditSnapshotStore.forProject(root, retentionPolicy: .init(maxPerFile: 1, maxAgeDays: 1))
        let legacy = try makeFile(store.rootDirectory, "2020-01-01T00-00-00Z-index.ts", text: "legacy")
        let first = try store.snapshotBeforeEdit(sourceFile: file)
        let unknown = try makeFile(first.deletingLastPathComponent(), "notes.txt")
        let malformed = try makeFile(first.deletingLastPathComponent(), "2020-01-01T00-00-00Z-invalid.snapshot")
        _ = try store.snapshotBeforeEdit(sourceFile: file)
        _ = store.prune()
        for url in [legacy, unknown, malformed] {
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
        #expect(try String(contentsOf: legacy, encoding: .utf8) == "legacy")
    }

    @Test("invalid policies cannot delete the backup or crash pruning",
          arguments: [
            EditSnapshotStore.RetentionPolicy(maxPerFile: 0),
            .init(maxPerFile: -1),
            .init(maxAgeDays: 0),
            .init(maxAgeDays: -1)
          ])
    func invalidPolicy(policy: EditSnapshotStore.RetentionPolicy) throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try makeFile(root, "index.ts")
        var store = EditSnapshotStore.forProject(root, retentionPolicy: .unlimited)
        let saved = try store.snapshotBeforeEdit(sourceFile: file)
        store.retentionPolicy = policy
        #expect(throws: AgentError.self) { try store.snapshotBeforeEdit(sourceFile: file) }
        #expect(store.prune().isEmpty)
        #expect(try String(contentsOf: saved, encoding: .utf8) == "original")
    }

    @Test("pruning ignores symbolic links and directories disguised as snapshots")
    func nonRegularEntries() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try makeFile(root, "source.txt")
        let store = EditSnapshotStore.forProject(root, retentionPolicy: .init(maxPerFile: 1, maxAgeDays: 1))
        let saved = try store.snapshotBeforeEdit(sourceFile: file)
        let link = saved.deletingLastPathComponent()
            .appendingPathComponent("2020-01-01T00-00-00Z-\(UUID().uuidString).snapshot")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let directory = saved.deletingLastPathComponent()
            .appendingPathComponent("2020-01-01T00-00-00Z-\(UUID().uuidString).snapshot")
        let child = try makeFile(directory, "keep.txt")
        #expect(store.prune().isEmpty)
        #expect(try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
        #expect(FileManager.default.fileExists(atPath: child.path))
    }

    @Test("concurrent stores serialize creation and retention")
    func concurrentSnapshots() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try makeFile(root, "source.txt")
        let saved = try await withThrowingTaskGroup(of: URL.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    let store = EditSnapshotStore.forProject(root, retentionPolicy: .init(maxPerFile: 5, maxAgeDays: nil))
                    return try store.snapshotBeforeEdit(sourceFile: file)
                }
            }
            var urls: [URL] = []
            for try await url in group { urls.append(url) }
            return urls
        }
        #expect(Set(saved).count == 20)
        let directory = try #require(saved.first).deletingLastPathComponent()
        let remaining = try snapshots(in: directory)
        #expect(remaining.count == 5)
        for url in remaining {
            #expect(try String(contentsOf: url, encoding: .utf8) == "original")
        }
    }

    @Test("new snapshot survives pruning even when an old backup has a future timestamp")
    func protectsNewSnapshot() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try makeFile(root, "source.txt")
        let store = EditSnapshotStore.forProject(root, retentionPolicy: .init(maxPerFile: 1, maxAgeDays: nil))
        let first = try store.snapshotBeforeEdit(sourceFile: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(86_400)],
            ofItemAtPath: first.path)
        let second = try store.snapshotBeforeEdit(sourceFile: file)
        #expect(try String(contentsOf: second, encoding: .utf8) == "original")
        #expect(!FileManager.default.fileExists(atPath: first.path))
    }

    @Test("invalid source metadata prevents cleanup and further snapshot creation")
    func invalidMetadata() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try makeFile(root, "source.txt")
        let store = EditSnapshotStore.forProject(root)
        let saved = try store.snapshotBeforeEdit(sourceFile: file)
        let directory = saved.deletingLastPathComponent()
        try "wrong path".write(to: directory.appendingPathComponent("source-path.txt"),
            atomically: true, encoding: .utf8)
        #expect(store.prune(now: Date().addingTimeInterval(86_400 * 31)).isEmpty)
        #expect(throws: AgentError.self) { try store.snapshotBeforeEdit(sourceFile: file) }
        #expect(try String(contentsOf: saved, encoding: .utf8) == "original")
    }
}
