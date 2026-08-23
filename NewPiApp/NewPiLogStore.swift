import Foundation
import NewPiCore
import OSLog
import SwiftUI

@MainActor
final class NewPiLogStore: ObservableObject {
    static let shared = NewPiLogStore()

    @Published private(set) var entries: [NewPiLogEntry] = []

    private let maxEntries: Int
    private let osLogger: Logger

    init(maxEntries: Int = 500) {
        self.maxEntries = maxEntries
        self.osLogger = Logger(subsystem: "com.newpi.app", category: "NewPi")
        NewPiLogger.setHandler { [weak self] entry in
            Task { @MainActor in
                self?.append(entry)
            }
        }
    }

    func append(_ entry: NewPiLogEntry) {
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }

        switch entry.level {
        case .info:
            osLogger.info("\(entry.formattedMessage, privacy: .public)")
        case .error:
            osLogger.error("\(entry.formattedMessage, privacy: .public)")
        }
    }

    func clear() {
        entries.removeAll()
    }

    var logText: String {
        guard !entries.isEmpty else {
            return "No logs for this app session yet."
        }
        return entries.map(\.formattedMessage).joined(separator: "\n\n")
    }
}
