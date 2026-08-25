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

        let workspace = workingDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedCandidate = candidate.resolvingSymlinksInPath()
        let workspacePath = workspace.path
        let candidatePath = resolvedCandidate.path

        guard candidatePath == workspacePath || candidatePath.hasPrefix(workspacePath + "/") else {
            NewPiLogger.error(
                category: "path",
                message: "Path escapes workspace",
                details: """
                input=\(path)
                workspace=\(workspacePath)
                resolved=\(candidatePath)
                """
            )
            throw PathResolverError.pathEscapesWorkspace
        }

        NewPiLogger.debug(
            category: "path",
            message: "Path resolved",
            details: "input=\(path) -> \(resolvedCandidate.path)"
        )

        return resolvedCandidate
    }
}
