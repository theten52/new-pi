import Foundation

public enum PathResolverError: Error, Sendable, Equatable {
    case emptyPath
    case pathEscapesWorkspace
    case notFound(String)
}

extension PathResolverError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyPath:
            "Path is empty."
        case .pathEscapesWorkspace:
            "Path escapes the project working directory."
        case let .notFound(path):
            "Path not found: \(path)"
        }
    }
}

public enum PathResolver {
    public static func resolve(_ path: String, relativeTo workingDirectory: URL) throws -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PathResolverError.emptyPath
        }

        let expanded = (trimmed as NSString).expandingTildeInPath
        let candidate: URL
        if expanded.hasPrefix("/") {
            candidate = URL(fileURLWithPath: expanded).standardizedFileURL
        } else {
            candidate = workingDirectory
                .appendingPathComponent(expanded)
                .standardizedFileURL
        }

        let workspace = workingDirectory.standardizedFileURL
        let workspacePath = workspace.path
        let candidatePath = candidate.path

        guard candidatePath == workspacePath || candidatePath.hasPrefix(workspacePath + "/") else {
            throw PathResolverError.pathEscapesWorkspace
        }

        return candidate
    }
}
