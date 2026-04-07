import Foundation

/// Shared helpers for file-system-based tools (path resolution, binary detection, directory filtering).
enum FileSystemToolHelpers {
    /// Resolves a possibly-relative path against the given working directory.
    static func resolvePath(_ path: String, workingDirectory: String) -> String {
        if path.hasPrefix("/") {
            return path
        }
        return (workingDirectory as NSString).appendingPathComponent(path)
    }

    /// File extensions treated as binary (skipped by read/grep).
    static let binaryExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "bmp", "ico", "webp", "svg",
        "mp3", "mp4", "avi", "mov", "mkv", "wav", "flac",
        "pdf", "zip", "tar", "gz", "bz2", "7z", "rar",
        "exe", "dll", "dylib", "so", "o", "a",
        "class", "jar", "pyc", "wasm",
        "ttf", "otf", "woff", "woff2", "eot",
        "sqlite", "db",
    ]

    /// Directories that should be skipped during recursive file enumeration.
    static let ignoredDirectories: Set<String> = [
        ".git", "node_modules", ".build", "DerivedData", "__pycache__",
    ]
}

/// Protocol that all agent tools must conform to.
protocol AgentTool: Sendable {
    /// The tool name as sent to the Anthropic API (e.g. "bash", "read").
    var name: String { get }

    /// Human-readable description of what the tool does.
    var description: String { get }

    /// JSON Schema describing the tool's input parameters,
    /// matching Anthropic's `input_schema` format.
    var inputSchema: [String: Any] { get }

    /// Execute the tool with the given arguments and return the result string.
    func execute(args: [String: Any]) async throws -> String
}

/// Holds the set of available tools and serializes their schemas for the API.
final class ToolRegistry: Sendable {
    let tools: [AgentTool]

    init(tools: [AgentTool]) {
        self.tools = tools
    }

    /// Creates the default registry with all built-in tools.
    static func defaultRegistry(workingDirectory: String? = nil) -> ToolRegistry {
        let cwd = workingDirectory ?? FileManager.default.currentDirectoryPath
        return ToolRegistry(tools: [
            BashTool(workingDirectory: cwd),
            ReadTool(workingDirectory: cwd),
            WriteTool(workingDirectory: cwd),
            EditTool(workingDirectory: cwd),
            LsTool(workingDirectory: cwd),
            FindTool(workingDirectory: cwd),
            GrepTool(workingDirectory: cwd),
            WebFetchTool(),
            WebSearchTool(),
            CreateReminderTool(),
            CreateRoutineTool(),
            ListSchedulesTool(),
            DeleteScheduleTool(),
            TaskTool(),
            DismissTool(),
            BrowserTool(),
        ])
    }

    /// Look up a tool by name.
    func tool(named name: String) -> AgentTool? {
        tools.first { $0.name == name }
    }

    /// Serializes all tool definitions into the format expected by the Anthropic API.
    func apiToolDefinitions() -> [[String: Any]] {
        tools.map { tool in
            [
                "name": tool.name,
                "description": tool.description,
                "input_schema": tool.inputSchema,
            ]
        }
    }
}
