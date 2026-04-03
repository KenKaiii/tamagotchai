import Foundation
import os

private let logger = Logger(
    subsystem: "com.unstablemind.tamagotchai",
    category: "tool.grep"
)

private struct ToolError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// swiftlint:disable:next type_body_length
final class GrepTool: AgentTool, @unchecked Sendable {
    let name = "grep"
    let description = "Search file contents using regex. Returns filepath:line_number:content for matches."

    let workingDirectory: String

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "pattern": [
                    "type": "string",
                    "description": "Search pattern (regex supported)",
                ],
                "path": [
                    "type": "string",
                    "description": "File or directory to search (defaults to cwd)",
                ],
                "include": [
                    "type": "string",
                    "description": "Glob pattern to filter files (e.g. '*.swift')",
                ],
                "max_results": [
                    "type": "integer",
                    "description": "Maximum matches to return (default: 50)",
                ],
                "case_insensitive": [
                    "type": "boolean",
                    "description": "Case-insensitive search",
                ],
            ],
            "required": ["pattern"],
        ]
    }

    init(workingDirectory: String) {
        self.workingDirectory = workingDirectory
    }

    func execute(args: [String: Any]) async throws -> String {
        let params = try parseArgs(args)
        logger
            .info(
                "Grep search: pattern=\(params.pattern, privacy: .public), path=\(params.standardizedPath, privacy: .public), include=\(params.includeGlob ?? "(none)", privacy: .public)"
            )
        let regex = try buildRegex(pattern: params.pattern, caseInsensitive: params.caseInsensitive)
        let filesToSearch = try collectFiles(
            standardizedPath: params.standardizedPath,
            isDirectory: params.isDirectory,
            includeGlob: params.includeGlob
        )
        let result = searchFiles(filesToSearch, regex: regex, maxResults: params.maxResults)
        logger.info("Grep complete: \(filesToSearch.count) files searched")
        return result
    }

    // MARK: - Private Helpers

    private struct ParsedArgs {
        let pattern: String
        let standardizedPath: String
        let isDirectory: Bool
        let includeGlob: String?
        let maxResults: Int
        let caseInsensitive: Bool
    }

    private func parseArgs(_ args: [String: Any]) throws -> ParsedArgs {
        guard let pattern = args["pattern"] as? String else {
            throw ToolError(message: "Missing required parameter: pattern")
        }

        let pathArg = args["path"] as? String ?? "."
        let resolvedPath = FileSystemToolHelpers.resolvePath(pathArg, workingDirectory: workingDirectory)

        let standardized = (resolvedPath as NSString).standardizingPath
        let fm = FileManager.default

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: standardized, isDirectory: &isDir) else {
            logger.error("Path not found: \(standardized, privacy: .public)")
            throw ToolError(message: "Path not found: \(standardized)")
        }

        return ParsedArgs(
            pattern: pattern,
            standardizedPath: standardized,
            isDirectory: isDir.boolValue,
            includeGlob: args["include"] as? String,
            maxResults: args["max_results"] as? Int ?? 50,
            caseInsensitive: args["case_insensitive"] as? Bool ?? false
        )
    }

    private func buildRegex(pattern: String, caseInsensitive: Bool) throws -> NSRegularExpression {
        var options: NSRegularExpression.Options = []
        if caseInsensitive {
            options.insert(.caseInsensitive)
        }
        do {
            return try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            logger.error("Invalid regex pattern: \(error.localizedDescription, privacy: .public)")
            throw ToolError(message: "Invalid regex pattern: \(error.localizedDescription)")
        }
    }

    private func collectFiles(
        standardizedPath: String,
        isDirectory: Bool,
        includeGlob: String?
    ) throws -> [(path: String, relativePath: String)] {
        if isDirectory {
            try collectDirectoryFiles(at: standardizedPath, includeGlob: includeGlob)
        } else {
            try collectSingleFile(at: standardizedPath)
        }
    }

    private func collectDirectoryFiles(
        at dirPath: String,
        includeGlob: String?
    ) throws -> [(path: String, relativePath: String)] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: dirPath),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.producesRelativePathURLs]
        ) else {
            throw ToolError(message: "Could not enumerate directory: \(dirPath)")
        }

        var results: [(path: String, relativePath: String)] = []

        while let obj = enumerator.nextObject() {
            guard let url = obj as? URL else { continue }
            let lastComponent = url.lastPathComponent

            if FileSystemToolHelpers.ignoredDirectories.contains(lastComponent) {
                enumerator.skipDescendants()
                continue
            }

            guard shouldIncludeFile(url: url, includeGlob: includeGlob) else { continue }

            results.append((path: url.path, relativePath: url.relativePath))
        }

        return results
    }

    private func shouldIncludeFile(url: URL, includeGlob: String?) -> Bool {
        let resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey])
        if resourceValues?.isDirectory == true { return false }

        let ext = url.pathExtension.lowercased()
        if FileSystemToolHelpers.binaryExtensions.contains(ext) { return false }

        if let glob = includeGlob, fnmatch(glob, url.lastPathComponent, 0) != 0 {
            return false
        }

        return true
    }

    private func collectSingleFile(
        at filePath: String
    ) throws -> [(path: String, relativePath: String)] {
        let ext = (filePath as NSString).pathExtension.lowercased()
        if FileSystemToolHelpers.binaryExtensions.contains(ext) {
            throw ToolError(message: "Cannot search binary file: \(filePath)")
        }

        let relPath: String = if filePath.hasPrefix(workingDirectory) {
            String(filePath.dropFirst(workingDirectory.count + 1))
        } else {
            (filePath as NSString).lastPathComponent
        }

        return [(path: filePath, relativePath: relPath)]
    }

    private func searchFiles(
        _ files: [(path: String, relativePath: String)],
        regex: NSRegularExpression,
        maxResults: Int
    ) -> String {
        let fm = FileManager.default
        var outputLines: [String] = []
        var matchCount = 0

        for file in files {
            guard let data = fm.contents(atPath: file.path),
                  let content = String(data: data, encoding: .utf8) else { continue }

            let lines = content.components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let range = NSRange(line.startIndex ..< line.endIndex, in: line)
                guard regex.firstMatch(in: line, range: range) != nil else { continue }

                matchCount += 1
                if matchCount <= maxResults {
                    outputLines.append("\(file.relativePath):\(index + 1):\(line)")
                }
            }
        }

        if outputLines.isEmpty {
            return "No matches found"
        }

        var result = outputLines.joined(separator: "\n")
        result += "\n\n\(matchCount) match(es) found"
        return result
    }
}
