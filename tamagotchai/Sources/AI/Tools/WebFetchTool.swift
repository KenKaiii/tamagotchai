import Foundation
import os

private let logger = Logger(
    subsystem: "com.unstablemind.tamagotchai",
    category: "tool.web"
)

/// Agent tool that fetches and reads content from a URL.
final class WebFetchTool: AgentTool, @unchecked Sendable {
    let name = "web_fetch"

    let description =
        "Fetch and read content from a URL. Returns text content with HTML tags stripped."

    init() {}

    // MARK: - Input Schema

    nonisolated var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "url": [
                    "type": "string",
                    "description": "The URL to fetch",
                ],
                "max_length": [
                    "type": "number",
                    "description":
                        "Maximum number of characters to return (default: 10000)",
                ],
            ],
            "required": ["url"],
        ]
    }

    // MARK: - Execution

    func execute(args: [String: Any]) async throws -> String {
        guard let urlString = args["url"] as? String else {
            throw WebFetchError.missingURL
        }

        let maxLength = (args["max_length"] as? NSNumber)?.intValue ?? 10000
        logger.info("Fetching URL: \(urlString, privacy: .public), maxLength: \(maxLength)")

        guard let url = URL(string: urlString) else {
            logger.error("Invalid URL: \(urlString, privacy: .public)")
            throw WebFetchError.invalidURL(urlString)
        }

        // SSRF protection — block private/local addresses.
        do {
            try validateHost(url)
        } catch {
            logger.error("Blocked host for URL: \(urlString, privacy: .public)")
            throw error
        }

        // Configure URLSession with 30s timeout.
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: config)

        // Fetch the URL.
        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebFetchError.invalidResponse
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            logger.error("HTTP error \(httpResponse.statusCode) for URL: \(urlString, privacy: .public)")
            return "HTTP error: \(httpResponse.statusCode)"
        }

        guard var text = String(data: data, encoding: .utf8) else {
            throw WebFetchError.requestFailed(
                "Unable to decode response as UTF-8"
            )
        }

        // Strip HTML tags.
        text = text.replacingOccurrences(
            of: "<[^>]+>",
            with: "",
            options: .regularExpression
        )

        // Decode common HTML entities.
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        text = text.replacingOccurrences(of: "&quot;", with: "\"")
        text = text.replacingOccurrences(of: "&#39;", with: "'")
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")

        // Collapse multiple blank lines into single blank lines.
        text = text.replacingOccurrences(
            of: "\\n{3,}",
            with: "\n\n",
            options: .regularExpression
        )

        // Trim whitespace.
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Truncate if needed.
        if text.count > maxLength {
            let truncated = String(text.prefix(maxLength))
            logger.info("Fetch complete: \(text.count) chars, truncated=true")
            return truncated + "\n[...truncated at \(maxLength) chars]"
        }

        logger.info("Fetch complete: \(text.count) chars, truncated=false")
        return text
    }

    // MARK: - SSRF Protection

    /// Validates that the URL host is not a private or local address.
    private func validateHost(_ url: URL) throws {
        guard let host = url.host?.lowercased() else {
            throw WebFetchError.invalidURL(url.absoluteString)
        }

        let blockedHosts: Set<String> = [
            "localhost", "127.0.0.1", "0.0.0.0", "::1",
        ]
        if blockedHosts.contains(host) {
            throw WebFetchError.blockedHost(host)
        }

        if isPrivateIP(host) {
            throw WebFetchError.blockedHost(host)
        }
    }

    /// Returns true if the given string is an IPv4 address in a private range.
    private func isPrivateIP(_ host: String) -> Bool {
        let parts = host.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }

        // 10.0.0.0 – 10.255.255.255
        if parts[0] == 10 {
            return true
        }

        // 172.16.0.0 – 172.31.255.255
        if parts[0] == 172, (16 ... 31).contains(parts[1]) {
            return true
        }

        // 192.168.0.0 – 192.168.255.255
        if parts[0] == 192, parts[1] == 168 {
            return true
        }

        return false
    }
}

// MARK: - Errors

enum WebFetchError: LocalizedError {
    case missingURL
    case invalidURL(String)
    case blockedHost(String)
    case requestFailed(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingURL:
            "Missing required parameter: url"
        case let .invalidURL(url):
            "Invalid URL: \(url)"
        case let .blockedHost(host):
            "Blocked host: \(host) — requests to private/local addresses are not allowed"
        case let .requestFailed(reason):
            "Request failed: \(reason)"
        case .invalidResponse:
            "Invalid response from server"
        }
    }
}
