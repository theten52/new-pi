import Foundation
import NewPiCore
import OSLog
import SwiftUI

@MainActor
final class NewPiLogStore: ObservableObject {
    static let shared = NewPiLogStore()

    @Published private(set) var entries: [NewPiLogEntry] = []
    @Published private(set) var logFileURLs: [URL] = []

    private let maxEntries: Int
    private let osLogger: Logger

    init(maxEntries: Int = 2000) {
        self.maxEntries = maxEntries
        self.osLogger = Logger(subsystem: "com.newpi.app", category: "NewPi")

        NewPiLogger.bootstrapFileLogging()
        logFileURLs = NewPiLogger.logFileURLs

        NewPiLogger.setHandler { [weak self] entry in
            Task { @MainActor in
                self?.append(entry)
            }
        }

        NewPiLogger.info(
            category: "lifecycle",
            message: "NewPi app logging initialized",
            details: """
            In-memory log limit: \(maxEntries) entries
            Global log file: \(NewPiLogger.globalLogFileURL.path)
            Project log file: <project>/.new-pi/debug.log (after opening a project)
            """
        )
    }

    func setProjectDirectory(_ url: URL?) {
        NewPiLogger.setProjectLogDirectory(url)
        logFileURLs = NewPiLogger.logFileURLs
    }

    func append(_ entry: NewPiLogEntry) {
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }

        switch entry.level {
        case .debug:
            osLogger.debug("\(entry.formattedMessage, privacy: .public)")
        case .info:
            osLogger.info("\(entry.formattedMessage, privacy: .public)")
        case .error:
            osLogger.error("\(entry.formattedMessage, privacy: .public)")
        }
    }

    func clear() {
        entries.removeAll()
        NewPiLogger.info(category: "lifecycle", message: "In-memory log buffer cleared")
    }

    var logText: String {
        let header = logFileHeader
        guard !entries.isEmpty else {
            return header + "\nNo in-memory entries for this app session yet."
        }
        return header + "\n" + entries.map(\.formattedMessage).joined(separator: "\n\n")
    }

    var logFileHeader: String {
        let paths = logFileURLs.map(\.path).joined(separator: "\n  ")
        return """
        Persistent log files (survive app restart):
          \(paths)

        In-memory session log:
        """
    }
}
