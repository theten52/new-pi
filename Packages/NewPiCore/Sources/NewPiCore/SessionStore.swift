import Foundation

public struct SessionHeader: Sendable, Codable, Equatable {
    public var id: UUID
    public var version: Int
    public var createdAt: Date
    public var workingDirectory: URL
    public var providerProfileID: String?
    public var modelID: String?
    public var label: String?

    public init(
        id: UUID = UUID(),
        version: Int = 1,
        createdAt: Date = Date(),
        workingDirectory: URL,
        providerProfileID: String? = nil,
        modelID: String? = nil,
        label: String? = nil
    ) {
        self.id = id
        self.version = version
        self.createdAt = createdAt
        self.workingDirectory = workingDirectory
        self.providerProfileID = providerProfileID
        self.modelID = modelID
        self.label = label
    }
}

public struct SessionEntry: Sendable, Codable, Equatable, Identifiable {
    public enum EntryType: String, Sendable, Codable {
        case message
        case modelChange
        case compaction
        case label
    }

    public var id: String
    public var parentID: String?
    public var type: EntryType
    public var timestamp: Date
    public var message: AgentMessage?
    public var modelProvider: String?
    public var modelID: String?
    public var compactionSummary: String?

    public init(
        id: String = String(UUID().uuidString.prefix(8)).lowercased(),
        parentID: String?,
        type: EntryType,
        timestamp: Date = Date(),
        message: AgentMessage? = nil,
        modelProvider: String? = nil,
        modelID: String? = nil,
        compactionSummary: String? = nil
    ) {
        self.id = String(id)
        self.parentID = parentID
        self.type = type
        self.timestamp = timestamp
        self.message = message
        self.modelProvider = modelProvider
        self.modelID = modelID
        self.compactionSummary = compactionSummary
    }
}

public struct SessionContext: Sendable, Equatable {
    public var header: SessionHeader
    public var entries: [SessionEntry]
    public var leafID: String?

    public init(header: SessionHeader, entries: [SessionEntry] = [], leafID: String? = nil) {
        self.header = header
        self.entries = entries
        self.leafID = leafID
    }

    public func branch(from leafID: String?) -> [SessionEntry] {
        guard let leafID else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        var path: [SessionEntry] = []
        var current = byID[leafID]
        while let entry = current {
            path.append(entry)
            guard let parentID = entry.parentID else { break }
            current = byID[parentID]
        }
        return path.reversed()
    }

    public mutating func append(_ entry: SessionEntry) {
        entries.append(entry)
        leafID = entry.id
    }
}

public protocol SessionStore: Sendable {
    func load(sessionID: UUID) async throws -> SessionContext
    func save(_ context: SessionContext) async throws
}

public actor InMemorySessionStore: SessionStore {
    private var sessions: [UUID: SessionContext] = [:]

    public init() {}

    public func load(sessionID: UUID) async throws -> SessionContext {
        guard let context = sessions[sessionID] else {
            throw AgentError.invalidState("Session not found: \(sessionID)")
        }
        return context
    }

    public func save(_ context: SessionContext) async throws {
        sessions[context.header.id] = context
    }
}
