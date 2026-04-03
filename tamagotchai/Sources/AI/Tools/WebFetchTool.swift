import Foundation
import os

private let logger = Logger(
    subsystem: "com.unstablemind.tamagotchai",
    category: "tool.web"
)

/// Agent tool that fetches and reads content from a URL.
final class WebFetchTool: AgentTool {
    let name = "web_fetch"

    let description =
        "Fetch and read content from a URL. Returns text content with HTML tags stripped."

    /// Maximum response body size (10 MB).
    private static let maxResponseBytes = 10 * 1024 * 1024

    /// Shared session with redirect delegate — reused across calls.
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config, delegate: SafeRedirectDelegate.shared, delegateQueue: nil)
    }()

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

        // Only allow http and https schemes.
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            logger.error("Blocked scheme for URL: \(urlString, privacy: .public)")
            throw WebFetchError.invalidURL(urlString)
        }

        // SSRF protection — block private/local addresses.
        do {
            try validateHost(url)
        } catch {
            logger.error("Blocked host for URL: \(urlString, privacy: .public)")
            throw error
        }

        // Stream the response with a byte limit to avoid unbounded memory usage.
        let request = URLRequest(url: url)
        let (bytes, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebFetchError.invalidResponse
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            logger.error("HTTP error \(httpResponse.statusCode) for URL: \(urlString, privacy: .public)")
            return "HTTP error: \(httpResponse.statusCode)"
        }

        // Read incrementally up to maxResponseBytes.
        var collected = Data()
        for try await byte in bytes {
            collected.append(byte)
            if collected.count >= Self.maxResponseBytes {
                logger.warning("Response exceeded \(Self.maxResponseBytes) byte limit, truncating")
                break
            }
        }

        guard var text = String(data: collected, encoding: .utf8) else {
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
            "localhost", "0.0.0.0",
        ]
        if blockedHosts.contains(host) {
            throw WebFetchError.blockedHost(host)
        }

        if isPrivateIPv4(host) || isPrivateIPv6(host) {
            throw WebFetchError.blockedHost(host)
        }
    }

    /// Returns true if the given string is an IPv4 address in a private/reserved range.
    private func isPrivateIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }

        // 127.0.0.0/8 — full loopback range
        if parts[0] == 127 {
            return true
        }

        // 10.0.0.0/8
        if parts[0] == 10 {
            return true
        }

        // 172.16.0.0/12
        if parts[0] == 172, (16 ... 31).contains(parts[1]) {
            return true
        }

        // 192.168.0.0/16
        if parts[0] == 192, parts[1] == 168 {
            return true
        }

        // 169.254.0.0/16 — link-local
        if parts[0] == 169, parts[1] == 254 {
            return true
        }

        // 0.0.0.0/8
        if parts[0] == 0 {
            return true
        }

        return false
    }

    /// Returns true if the given string is an IPv6 address in a private/reserved range.
    private func isPrivateIPv6(_ host: String) -> Bool {
        // Strip brackets if present (e.g. from URL host)
        let cleaned = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))

        // ::1 loopback
        if cleaned == "::1" {
            return true
        }

        // IPv4-mapped IPv6 (::ffff:x.x.x.x)
        let lowerCleaned = cleaned.lowercased()
        if lowerCleaned.hasPrefix("::ffff:") {
            let ipv4Part = String(lowerCleaned.dropFirst(7))
            return isPrivateIPv4(ipv4Part)
        }

        // Expand to check prefix-based ranges
        let expanded = expandIPv6(lowerCleaned)
        guard !expanded.isEmpty else { return false }

        // fe80::/10 — link-local
        if expanded.hasPrefix("fe8") || expanded.hasPrefix("fe9") ||
            expanded.hasPrefix("fea") || expanded.hasPrefix("feb")
        {
            return true
        }

        // fc00::/7 — unique local addresses
        if expanded.hasPrefix("fc") || expanded.hasPrefix("fd") {
            return true
        }

        return false
    }

    /// Minimal IPv6 expansion — returns the full lowercased hex string (no colons) or empty on parse failure.
    private func expandIPv6(_ addr: String) -> String {
        var parts = addr.split(separator: ":", omittingEmptySubsequences: false).map(String.init)

        // Handle :: expansion
        if let emptyIdx = parts.firstIndex(where: { $0.isEmpty }) {
            // Count existing non-empty groups
            let nonEmpty = parts.filter { !$0.isEmpty }
            let missing = 8 - nonEmpty.count
            if missing > 0 {
                var expanded: [String] = []
                for (i, part) in parts.enumerated() {
                    if part.isEmpty, i == emptyIdx {
                        for _ in 0 ..< missing {
                            expanded.append("0000")
                        }
                    } else if !part.isEmpty {
                        expanded.append(part)
                    }
                }
                parts = expanded
            }
        }

        guard parts.count == 8 else { return "" }

        return parts.map { group in
            let padded = String(repeating: "0", count: max(0, 4 - group.count)) + group
            return padded.suffix(4).lowercased()
        }.joined()
    }

    /// Validates a redirect target URL against the same SSRF rules.
    static func isAllowedRedirectTarget(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return false }

        guard let host = url.host?.lowercased() else { return false }

        let blockedHosts: Set<String> = ["localhost", "0.0.0.0"]
        if blockedHosts.contains(host) { return false }

        let checker = WebFetchTool()
        if checker.isPrivateIPv4(host) || checker.isPrivateIPv6(host) {
            return false
        }

        return true
    }
}

// MARK: - Safe Redirect Delegate

/// URLSession delegate that validates redirect targets against SSRF rules.
private final class SafeRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = SafeRedirectDelegate()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url, WebFetchTool.isAllowedRedirectTarget(url) else {
            logger.warning("Blocked redirect to: \(request.url?.absoluteString ?? "nil", privacy: .public)")
            completionHandler(nil)
            return
        }
        completionHandler(request)
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
