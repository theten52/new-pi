import Foundation
import NewPiCore

enum SessionCommands {
    static func run(_ args: [String]) async {
        var remaining = args
        guard let subcommand = remaining.first else {
            printUsage()
            return
        }
        remaining.removeFirst()

        switch subcommand {
        case "list":
            listSessions(args: remaining)
        case "show":
            showSession(args: remaining)
        case "help", "-h", "--help":
            printUsage()
        default:
            fputs("Unknown sessions subcommand: \(subcommand)\n", stderr)
            printUsage()
            exit(1)
        }
    }

    private static func listSessions(args: [String]) {
        var flags = args
        let projectURL = projectURL(from: &flags)

        if !flags.isEmpty {
            fputs("Unexpected arguments: \(flags.joined(separator: " "))\n", stderr)
            printUsage()
            exit(1)
        }

        do {
            let summaries = try SessionManager.listSessions(for: projectURL)
            print(SessionCLIDisplay.formatList(summaries, projectURL: projectURL))
        } catch {
            fputs("Failed to list sessions: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func showSession(args: [String]) {
        var flags = args
        guard let token = flags.first else {
            fputs("Missing session id.\n", stderr)
            printUsage()
            exit(1)
        }
        flags.removeFirst()
        let projectURL = projectURL(from: &flags)

        if !flags.isEmpty {
            fputs("Unexpected arguments: \(flags.joined(separator: " "))\n", stderr)
            printUsage()
            exit(1)
        }

        do {
            guard let match = try SessionManager.findSession(matching: token, for: projectURL) else {
                fputs("Session not found: \(token)\n", stderr)
                exit(1)
            }
            let messages = SessionManager.messages(from: match.context)
            print(SessionCLIDisplay.formatShow(
                context: match.context,
                messages: messages,
                fileURL: match.summary.fileURL
            ))
        } catch {
            fputs("Failed to show session: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func projectURL(from args: inout [String]) -> URL {
        if let index = args.firstIndex(of: "--project"), index + 1 < args.count {
            let path = args[index + 1]
            args.remove(at: index + 1)
            args.remove(at: index)
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .standardizedFileURL
    }

    private static func printUsage() {
        print(
            """
            Usage:
              new-pi sessions list [--project PATH]
              new-pi sessions show <session-id> [--project PATH]

            Options:
              --project PATH   Project directory (default: current working directory)
            """
        )
    }
}
