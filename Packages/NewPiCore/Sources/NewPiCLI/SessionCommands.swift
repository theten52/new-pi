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
        case "export":
            exportSession(args: remaining)
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

    private static func exportSession(args: [String]) {
        var flags = args
        guard let token = flags.first else {
            fputs("Missing session id.\n", stderr)
            printUsage()
            exit(1)
        }
        flags.removeFirst()

        var format: SessionExportFormat = .markdown
        var outputPath: String?

        var index = 0
        while index < flags.count {
            let flag = flags[index]
            if flag == "--format", index + 1 < flags.count {
                index += 1
                guard let parsed = SessionExportFormat(rawValue: flags[index]) else {
                    fputs("Unknown format: \(flags[index]). Use markdown, json, or text.\n", stderr)
                    exit(1)
                }
                format = parsed
            } else if flag == "--output", index + 1 < flags.count {
                index += 1
                outputPath = flags[index]
            } else {
                break
            }
            index += 1
        }

        if index > 0 {
            flags.removeFirst(index)
        }
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
            let exporter = SessionExporter()
            let content: String
            switch format {
            case .markdown:
                content = exporter.exportMarkdown(context: match.context, messages: messages)
            case .text:
                content = exporter.exportText(messages: messages)
            case .json:
                let data = try exporter.exportJSON(context: match.context)
                content = String(decoding: data, as: UTF8.self)
            }

            if let outputPath {
                let url = URL(fileURLWithPath: outputPath)
                try content.write(to: url, atomically: true, encoding: .utf8)
                print("Exported to \(url.path)")
            } else {
                print(content)
            }
        } catch {
            fputs("Failed to export session: \(error.localizedDescription)\n", stderr)
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
              new-pi sessions export <session-id> [--format markdown|json|text] [--output PATH] [--project PATH]

            Options:
              --project PATH   Project directory (default: current working directory)
              --format         Export format (default: markdown)
              --output PATH    Write export to file instead of stdout
            """
        )
    }
}
