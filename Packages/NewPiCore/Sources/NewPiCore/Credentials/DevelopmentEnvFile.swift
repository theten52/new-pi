import Foundation

public enum DevelopmentEnvFile {
    public static let overrideVariable = "NEW_PI_ENV_FILE"
    private static let projectMarkers = ["NewPi.xcodeproj", "Package.swift"]

    public static func resolve(
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
        fileManager: FileManager = .default
    ) -> URL? {
        if let override = processEnvironment[overrideVariable]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            // SECURITY-REVIEW: user-controlled path reads local dev secrets only; never executed.
            return URL(fileURLWithPath: override).standardizedFileURL
        }

        var directory = startingDirectory(from: currentDirectory, fileManager: fileManager)
        while true {
            let envFile = directory.appendingPathComponent(".env", isDirectory: false)
            if fileManager.fileExists(atPath: envFile.path),
               projectMarkers.contains(where: { fileManager.fileExists(atPath: directory.appendingPathComponent($0).path) }) {
                return envFile.standardizedFileURL
            }

            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path {
                return nil
            }
            directory = parent
        }
    }

    public static func loadEnvironment(
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
        fileManager: FileManager = .default
    ) -> [String: String] {
        guard let url = resolve(
            processEnvironment: processEnvironment,
            currentDirectory: currentDirectory,
            fileManager: fileManager
        ) else {
            return [:]
        }
        return (try? DotEnvFile.load(from: url)) ?? [:]
    }

    private static func startingDirectory(from url: URL, fileManager: FileManager) -> URL {
        let standardized = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: standardized.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            return standardized.deletingLastPathComponent()
        }
        return standardized
    }
}

enum DotEnvFile {
    static func load(from url: URL) throws -> [String: String] {
        // SECURITY-REVIEW: dev .env may contain secrets; kept in memory only.
        let contents = try String(contentsOf: url, encoding: .utf8)
        return parse(contents)
    }

    static func parse(_ contents: String) -> [String: String] {
        var values: [String: String] = [:]
        for rawLine in contents.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }
            if line.hasPrefix("export ") {
                line = String(line.dropFirst("export ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard let separator = line.firstIndex(of: "=") else {
                continue
            }

            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                continue
            }
            let rawValue = String(line[line.index(after: separator)...])
            values[key] = decodeValue(rawValue)
        }
        return values
    }

    private static func decodeValue(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count >= 2, let first = trimmed.first, let last = trimmed.last,
           (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            return String(trimmed.dropFirst().dropLast())
        }
        return stripInlineComment(from: trimmed).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripInlineComment(from value: String) -> String {
        var inSingleQuote = false
        var inDoubleQuote = false
        var index = value.startIndex

        while index < value.endIndex {
            let character = value[index]
            if character == "'", !inDoubleQuote {
                inSingleQuote.toggle()
            } else if character == "\"", !inSingleQuote {
                inDoubleQuote.toggle()
            } else if character == "#", !inSingleQuote, !inDoubleQuote {
                return String(value[..<index])
            }
            index = value.index(after: index)
        }

        return value
    }
}
