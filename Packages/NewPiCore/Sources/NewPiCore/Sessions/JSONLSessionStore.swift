import CryptoKit
import Foundation

public enum JSONLSessionRecord: Sendable, Codable, Equatable {
    case header(SessionHeader)
    case entry(SessionEntry)

    private enum CodingKeys: String, CodingKey {
        case recordType
        case header
        case entry
    }

    private enum RecordType: String, Codable {
        case header
        case entry
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(RecordType.self, forKey: .recordType)
        switch type {
        case .header:
            self = .header(try container.decode(SessionHeader.self, forKey: .header))
        case .entry:
            self = .entry(try container.decode(SessionEntry.self, forKey: .entry))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .header(header):
            try container.encode(RecordType.header, forKey: .recordType)
            try container.encode(header, forKey: .header)
        case let .entry(entry):
            try container.encode(RecordType.entry, forKey: .recordType)
            try container.encode(entry, forKey: .entry)
        }
    }
}

public enum JSONLSessionStoreError: Error, Sendable, Equatable {
    case missingHeader
    case duplicateHeader
    case emptyFile
    case invalidLine(Int)
}

extension JSONLSessionStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingHeader:
            "Session file is missing a header record."
        case .duplicateHeader:
            "Session file contains multiple header records."
        case .emptyFile:
            "Session file is empty."
        case let .invalidLine(line):
            "Session file contains invalid JSON at line \(line)."
        }
    }
}

public struct JSONLSessionCodec: Sendable {
    public init() {}

    public func encode(_ context: SessionContext) throws -> Data {
        var lines: [JSONLSessionRecord] = [.header(context.header)]
        lines.append(contentsOf: context.entries.map { .entry($0) })

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]

        var data = Data()
        for record in lines {
            let line = try encoder.encode(record)
            data.append(line)
            data.append(0x0A)
        }
        return data
    }

    public func decode(_ data: Data) throws -> SessionContext {
        guard !data.isEmpty else {
            throw JSONLSessionStoreError.emptyFile
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var header: SessionHeader?
        var entries: [SessionEntry] = []
        var lineNumber = 0

        for lineData in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            lineNumber += 1
            do {
                let record = try decoder.decode(JSONLSessionRecord.self, from: Data(lineData))
                switch record {
                case let .header(value):
                    if header != nil {
                        throw JSONLSessionStoreError.duplicateHeader
                    }
                    header = value
                case let .entry(entry):
                    entries.append(entry)
                }
            } catch let storeError as JSONLSessionStoreError {
                throw storeError
            } catch {
                throw JSONLSessionStoreError.invalidLine(lineNumber)
            }
        }

        guard let header else {
            throw JSONLSessionStoreError.missingHeader
        }

        return SessionContext(header: header, entries: entries, leafID: entries.last?.id)
    }

    /// Reads only the session header and counts message/compaction entries without decoding message bodies.
    public func decodeSummary(_ data: Data, fileURL: URL) throws -> SessionSummary {
        guard !data.isEmpty else {
            throw JSONLSessionStoreError.emptyFile
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var header: SessionHeader?
        var messageCount = 0
        var lineNumber = 0

        for lineData in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            lineNumber += 1
            if lineNumber == 1 {
                let record = try decoder.decode(JSONLSessionRecord.self, from: Data(lineData))
                guard case let .header(value) = record else {
                    throw JSONLSessionStoreError.missingHeader
                }
                header = value
                continue
            }

            if Self.lineCountsTowardMessageTotal(lineData) {
                messageCount += 1
            }
        }

        guard let header else {
            throw JSONLSessionStoreError.missingHeader
        }

        return SessionSummary(
            id: header.id,
            fileURL: fileURL,
            createdAt: header.createdAt,
            label: header.label,
            messageCount: messageCount,
            providerProfileID: header.providerProfileID,
            modelID: header.modelID,
            archived: header.archived
        )
    }

    private static func lineCountsTowardMessageTotal(_ line: some DataProtocol) -> Bool {
        guard let text = String(data: Data(line), encoding: .utf8) else { return false }
        guard text.contains(#""recordType":"entry""#) else { return false }
        return text.contains(#""type":"message""#) || text.contains(#""type":"compaction""#)
    }
}

public struct JSONLSessionStore: Sendable {
    public var codec: JSONLSessionCodec

    public init(codec: JSONLSessionCodec = JSONLSessionCodec()) {
        self.codec = codec
    }

    public func load(from fileURL: URL) throws -> SessionContext {
        let data = try Data(contentsOf: fileURL)
        return try codec.decode(data)
    }

    public func loadSummary(from fileURL: URL) throws -> SessionSummary {
        let data = try Data(contentsOf: fileURL)
        return try codec.decodeSummary(data, fileURL: fileURL)
    }

    public func save(_ context: SessionContext, to fileURL: URL) throws {
        let directory = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let data = try codec.encode(context)
        try data.write(to: fileURL, options: .atomic)
    }
}

public struct SessionSummary: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var fileURL: URL
    public var createdAt: Date
    public var label: String?
    public var messageCount: Int
    public var providerProfileID: String?
    public var modelID: String?
    public var archived: Bool

    public init(
        id: UUID,
        fileURL: URL,
        createdAt: Date,
        label: String? = nil,
        messageCount: Int = 0,
        providerProfileID: String? = nil,
        modelID: String? = nil,
        archived: Bool = false
    ) {
        self.id = id
        self.fileURL = fileURL
        self.createdAt = createdAt
        self.label = label
        self.messageCount = messageCount
        self.providerProfileID = providerProfileID
        self.modelID = modelID
        self.archived = archived
    }
}

public enum SessionManager {
    public static func sessionsRoot(
        agentDirectory: URL = NewPiConfig.defaultAgentDirectory
    ) -> URL {
        agentDirectory.appendingPathComponent("sessions", isDirectory: true)
    }

    public static func projectHash(for projectURL: URL) -> String {
        let standardized = projectURL.standardizedFileURL.path
        let digest = SHA256.hash(data: Data(standardized.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    public static func projectDirectory(for projectURL: URL, root: URL = sessionsRoot()) -> URL {
        root.appendingPathComponent(projectHash(for: projectURL), isDirectory: true)
    }

    public static func makeSessionFileURL(in directory: URL, sessionID: UUID, createdAt: Date = Date()) -> URL {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withFullTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        let stamp = formatter.string(from: createdAt)
            .replacingOccurrences(of: ":", with: "")
        let shortID = sessionID.uuidString.prefix(8).lowercased()
        return directory.appendingPathComponent("\(stamp)_\(shortID).jsonl")
    }

    public static func createSession(
        workingDirectory: URL,
        providerProfileID: String? = nil,
        modelID: String? = nil,
        label: String? = nil,
        root: URL = sessionsRoot(),
        store: JSONLSessionStore = JSONLSessionStore()
    ) throws -> (context: SessionContext, fileURL: URL) {
        let header = SessionHeader(
            workingDirectory: workingDirectory,
            providerProfileID: providerProfileID,
            modelID: modelID,
            label: label
        )
        let context = SessionContext(header: header)
        let directory = projectDirectory(for: workingDirectory, root: root)
        let fileURL = makeSessionFileURL(in: directory, sessionID: header.id, createdAt: header.createdAt)
        try store.save(context, to: fileURL)
        return (context, fileURL)
    }

    public static func listSessions(
        for projectURL: URL,
        root: URL = sessionsRoot(),
        store: JSONLSessionStore = JSONLSessionStore(),
        includeArchived: Bool = false
    ) throws -> [SessionSummary] {
        let directory = projectDirectory(for: projectURL, root: root)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return []
        }

        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "jsonl" }
        .sorted { lhs, rhs in
            let lDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lDate > rDate
        }

        return try files.compactMap { fileURL in
            let summary = try store.loadSummary(from: fileURL)
            guard includeArchived || !summary.archived else { return nil }
            return summary
        }
    }

    /// Removes session files that contain no messages (header only).
    @discardableResult
    public static func deleteEmptySessions(
        for projectURL: URL,
        excluding excludedFileURL: URL? = nil,
        root: URL = sessionsRoot(),
        store: JSONLSessionStore = JSONLSessionStore()
    ) throws -> Int {
        let directory = projectDirectory(for: projectURL, root: root)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return 0
        }

        let summaries = try listSessions(
            for: projectURL,
            root: root,
            store: store,
            includeArchived: true
        )
        var deleted = 0
        for summary in summaries where summary.messageCount == 0 {
            guard summary.fileURL != excludedFileURL else { continue }
            try FileManager.default.removeItem(at: summary.fileURL)
            deleted += 1
        }
        return deleted
    }

    public static func setArchived(
        _ archived: Bool,
        for fileURL: URL,
        store: JSONLSessionStore = JSONLSessionStore()
    ) throws {
        var context = try store.load(from: fileURL)
        context.header.archived = archived
        try store.save(context, to: fileURL)
    }

    public static func updateLabel(
        _ label: String,
        for fileURL: URL,
        store: JSONLSessionStore = JSONLSessionStore()
    ) throws {
        var context = try store.load(from: fileURL)
        context.header.label = label
        try store.save(context, to: fileURL)
    }

    public static func findSession(
        matching token: String,
        for projectURL: URL,
        root: URL = sessionsRoot(),
        store: JSONLSessionStore = JSONLSessionStore()
    ) throws -> (summary: SessionSummary, context: SessionContext)? {
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }

        let summaries = try listSessions(for: projectURL, root: root, store: store)
        let summary = summaries.first { candidate in
            candidate.id.uuidString.lowercased().hasPrefix(normalized)
                || candidate.fileURL.lastPathComponent.lowercased().contains(normalized)
                || candidate.fileURL.deletingPathExtension().lastPathComponent.lowercased() == normalized
        }

        guard let summary else { return nil }
        let context = try store.load(from: summary.fileURL)
        return (summary, context)
    }

    public static func messages(from context: SessionContext) -> [AgentMessage] {
        messages(from: context, leafID: context.leafID)
    }

    public static func messages(from context: SessionContext, leafID: String?) -> [AgentMessage] {
        messageEntries(from: context, leafID: leafID).map(\.1)
    }

    public static func messageEntries(
        from context: SessionContext,
        leafID: String?
    ) -> [(SessionEntry, AgentMessage)] {
        context.branch(from: leafID).compactMap { entry in
            if entry.type == .compaction, let summary = entry.compactionSummary {
                return (entry, .compactionSummary(summary))
            }
            if let message = entry.message {
                return (entry, message)
            }
            return nil
        }
    }

    public static func forkContext(_ context: SessionContext, at entryID: String) throws -> SessionContext {
        guard context.entries.contains(where: { $0.id == entryID }) else {
            throw AgentError.invalidState("Session entry not found: \(entryID)")
        }
        var forked = context
        forked.leafID = entryID
        return forked
    }

    public static func childEntries(of entryID: String, in context: SessionContext) -> [SessionEntry] {
        context.entries.filter { $0.parentID == entryID }
    }

    public static func branchPointCount(in context: SessionContext) -> Int {
        let parentIDs = Set(context.entries.compactMap(\.parentID))
        return context.entries.filter { parentIDs.contains($0.id) }.count
    }

    public static func syncMessages(
        _ messages: [AgentMessage],
        into context: inout SessionContext,
        leafID: inout String?
    ) {
        let existing = Self.messages(from: context, leafID: leafID)
        guard messages.count >= existing.count else { return }
        guard messagesMatchForSync(Array(messages.prefix(existing.count)), existing) else { return }

        var parent = leafID
        for message in messages.dropFirst(existing.count) {
            let entry: SessionEntry
            switch message {
            case let .compactionSummary(summary):
                entry = SessionEntry(
                    parentID: parent,
                    type: .compaction,
                    compactionSummary: summary
                )
            default:
                entry = SessionEntry(
                    parentID: parent,
                    type: .message,
                    message: message
                )
            }
            context.entries.append(entry)
            parent = entry.id
        }
        leafID = parent
        context.leafID = leafID
    }

    private static func messagesMatchForSync(_ lhs: [AgentMessage], _ rhs: [AgentMessage]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy(messageContentEqual)
    }

    private static func messageContentEqual(_ lhs: AgentMessage, _ rhs: AgentMessage) -> Bool {
        switch (lhs, rhs) {
        case let (.user(l), .user(r)):
            return l.content == r.content
        case let (.assistant(l), .assistant(r)):
            return l.text == r.text
                && l.reasoningContent == r.reasoningContent
                && l.toolCalls == r.toolCalls
                && l.stopReason == r.stopReason
        case let (.toolResult(l), .toolResult(r)):
            return l.toolCallID == r.toolCallID && l.toolName == r.toolName
                && l.content == r.content && l.isError == r.isError
        case let (.compactionSummary(l), .compactionSummary(r)):
            return l == r
        default:
            return false
        }
    }

    public static func rebuildContext(from messages: [AgentMessage], header: SessionHeader) -> SessionContext {
        var context = SessionContext(header: header)
        var parentID: String?
        for message in messages {
            let entry: SessionEntry
            switch message {
            case let .compactionSummary(summary):
                entry = SessionEntry(
                    parentID: parentID,
                    type: .compaction,
                    compactionSummary: summary
                )
            default:
                entry = SessionEntry(
                    parentID: parentID,
                    type: .message,
                    message: message
                )
            }
            context.append(entry)
            parentID = entry.id
        }
        return context
    }

    public static func appendMessage(
        _ message: AgentMessage,
        to context: inout SessionContext,
        parentID: String?,
        modelProvider: String? = nil,
        modelID: String? = nil
    ) -> SessionEntry {
        let entry = SessionEntry(
            parentID: parentID,
            type: .message,
            message: message,
            modelProvider: modelProvider,
            modelID: modelID
        )
        context.append(entry)
        return entry
    }
}

public actor FileSessionStore: SessionStore {
    private var fileURLBySessionID: [UUID: URL] = [:]
    private var store: JSONLSessionStore

    public init(store: JSONLSessionStore = JSONLSessionStore()) {
        self.store = store
    }

    public func register(sessionID: UUID, fileURL: URL) {
        fileURLBySessionID[sessionID] = fileURL
    }

    public func load(sessionID: UUID) async throws -> SessionContext {
        guard let fileURL = fileURLBySessionID[sessionID] else {
            throw AgentError.invalidState("Session file not registered: \(sessionID)")
        }
        return try store.load(from: fileURL)
    }

    public func save(_ context: SessionContext) async throws {
        guard let fileURL = fileURLBySessionID[context.header.id] else {
            throw AgentError.invalidState("Session file not registered: \(context.header.id)")
        }
        try store.save(context, to: fileURL)
    }
}
