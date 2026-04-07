import Foundation
import os

private let logger = Logger(
    subsystem: "com.unstablemind.tamagotchai",
    category: "tool.search"
)

/// Agent tool that searches the web by scraping search engine HTML pages.
/// Uses DuckDuckGo as the primary engine with Brave and Google as fallbacks.
final class WebSearchTool: AgentTool, @unchecked Sendable {
    let name = "web_search"

    let description =
        "Search the web and return results. Use for current information, recent events, or facts beyond your knowledge."

    init() {}

    // MARK: - Input Schema

    nonisolated var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "query": [
                    "type": "string",
                    "description": "Search query",
                ],
                "max_results": [
                    "type": "integer",
                    "description": "Max results to return (default: 5, max: 20)",
                ],
            ],
            "required": ["query"],
        ]
    }

    // MARK: - Search Engine

    private enum SearchEngine: String, CaseIterable {
        case duckDuckGo = "DuckDuckGo"
        case brave = "Brave"
        case google = "Google"
    }

    // MARK: - Search Result

    private struct SearchResult {
        let title: String
        let url: String
        let snippet: String
    }

    // MARK: - User Agents

    private static let userAgents = [
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15",
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:125.0) Gecko/20100101 Firefox/125.0",
        "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
    ]

    // MARK: - Execution

    func execute(args: [String: Any]) async throws -> String {
        guard let query = args["query"] as? String, !query.isEmpty else {
            return "Error: Missing required parameter 'query'."
        }

        let maxResults = min((args["max_results"] as? NSNumber)?.intValue ?? 5, 20)
        logger.info("Web search: \"\(query, privacy: .public)\", maxResults: \(maxResults)")

        let (results, engine) = await performSearch(query: query, maxResults: maxResults)

        if results.isEmpty {
            logger.error("All search engines exhausted for query: \"\(query, privacy: .public)\"")
            return "No search results found for: \"\(query)\". All search engines were unavailable or returned no results."
        }

        var output = "Web search results for: \"\(query)\"\n\n"
        for (index, result) in results.enumerated() {
            output += "\(index + 1). [\(result.title)](\(result.url))\n"
            if !result.snippet.isEmpty {
                output += "   \(result.snippet)\n"
            }
            output += "\n"
        }
        output += "(\(results.count) results from \(engine.rawValue))"

        logger.info("Search complete: \(results.count) results from \(engine.rawValue, privacy: .public)")
        return output
    }

    // MARK: - Search Cascade

    private func performSearch(query: String, maxResults: Int) async -> ([SearchResult], SearchEngine) {
        for engine in SearchEngine.allCases {
            do {
                let results = try await searchWith(engine: engine, query: query, maxResults: maxResults)
                if !results.isEmpty {
                    return (results, engine)
                }
                logger.warning("No results from \(engine.rawValue, privacy: .public), trying next engine")
            } catch {
                logger
                    .warning(
                        "Engine \(engine.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                    )
            }
        }
        return ([], .duckDuckGo)
    }

    private func searchWith(engine: SearchEngine, query: String, maxResults: Int) async throws -> [SearchResult] {
        let (url, headers) = buildRequest(engine: engine, query: query)

        guard let requestURL = URL(string: url) else {
            throw WebSearchError.invalidURL
        }

        var request = URLRequest(url: requestURL)
        request.timeoutInterval = 15
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, statusCode) = try await fetchWithRetry(request: request)

        guard let html = String(data: data, encoding: .utf8) else {
            throw WebSearchError.invalidResponse
        }

        if isRateLimited(statusCode: statusCode, html: html) {
            logger.warning("Rate limited by \(engine.rawValue, privacy: .public)")
            throw WebSearchError.rateLimited(engine.rawValue)
        }

        var results: [SearchResult] = switch engine {
        case .duckDuckGo:
            parseDDGResults(html: html)
        case .brave:
            parseBraveResults(html: html)
        case .google:
            parseGoogleResults(html: html)
        }

        if results.count > maxResults {
            results = Array(results.prefix(maxResults))
        }

        return results
    }

    // MARK: - Request Building

    private func buildRequest(engine: SearchEngine, query: String) -> (url: String, headers: [String: String]) {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let ua = Self.userAgents.randomElement()!

        var headers = [
            "User-Agent": ua,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "en-US,en;q=0.9",
        ]

        let url: String
        switch engine {
        case .duckDuckGo:
            url = "https://html.duckduckgo.com/html/?q=\(encoded)"
        case .brave:
            url = "https://search.brave.com/search?q=\(encoded)&source=web"
            headers["Accept"] = "text/html"
        case .google:
            url = "https://www.google.com/search?q=\(encoded)&hl=en"
        }

        return (url, headers)
    }

    // MARK: - Fetch with Retry

    private func fetchWithRetry(request: URLRequest, maxRetries: Int = 3) async throws -> (Data, Int) {
        let session = URLSession(configuration: .ephemeral)
        var lastError: Error = WebSearchError.invalidResponse

        for attempt in 0 ..< maxRetries {
            if attempt > 0 {
                let baseDelay = pow(2.0, Double(attempt - 1))
                let jitter = Double.random(in: 1.0 ... 1.5)
                let delay = baseDelay * jitter
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }

            do {
                let (data, response) = try await session.data(for: request)
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                return (data, statusCode)
            } catch {
                lastError = error
                logger.warning("Request attempt \(attempt + 1) failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        throw lastError
    }

    // MARK: - Rate Limit Detection

    private func isRateLimited(statusCode: Int, html: String) -> Bool {
        if [429, 403, 503].contains(statusCode) {
            return true
        }

        let lowerHTML = html.lowercased()
        let rateLimitPatterns = [
            "you appear to be a bot",
            "unusual traffic",
            "captcha",
            "rate limit",
            "too many requests",
            "blocked",
            "access denied",
            "sorry, you have been blocked",
            "anomaly-modal",
            "unfortunately, bots use duckduckgo",
            "challenge-form",
        ]

        return rateLimitPatterns.contains { lowerHTML.contains($0) }
    }

    // MARK: - DuckDuckGo Parser

    private func parseDDGResults(html: String) -> [SearchResult] {
        var results: [SearchResult] = []

        // DDG HTML results are in <div class="result results_links results_links_deep web-result ">
        // Each has <a class="result__a" href="...">Title</a> and <a class="result__snippet">...</a>
        let resultPattern = #"<a[^>]*class="[^"]*result__a[^"]*"[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#
        let snippetPattern = #"class="[^"]*result__snippet[^"]*"[^>]*>(.*?)</(?:a|div|span)>"#

        guard let resultRegex = try? NSRegularExpression(pattern: resultPattern, options: .dotMatchesLineSeparators),
              let snippetRegex = try? NSRegularExpression(pattern: snippetPattern, options: .dotMatchesLineSeparators)
        else { return [] }

        let range = NSRange(html.startIndex ..< html.endIndex, in: html)
        let resultMatches = resultRegex.matches(in: html, range: range)
        let snippetMatches = snippetRegex.matches(in: html, range: range)

        for (index, match) in resultMatches.enumerated() {
            guard let rawURLRange = Range(match.range(at: 1), in: html),
                  let titleRange = Range(match.range(at: 2), in: html)
            else { continue }

            let rawURL = String(html[rawURLRange])
            let title = cleanHTML(String(html[titleRange]))

            let url = unwrapDDGRedirect(rawURL: rawURL)

            var snippet = ""
            if index < snippetMatches.count {
                if let snippetRange = Range(snippetMatches[index].range(at: 1), in: html) {
                    snippet = cleanHTML(String(html[snippetRange]))
                }
            }

            if !url.isEmpty, !title.isEmpty {
                results.append(SearchResult(title: title, url: url, snippet: snippet))
            }
        }

        return results
    }

    // MARK: - DDG URL Unwrapping

    private func unwrapDDGRedirect(rawURL: String) -> String {
        // DDG wraps URLs in a redirect: //duckduckgo.com/l/?uddg=<encoded_url>&rut=...
        if rawURL.contains("uddg="),
           let components = URLComponents(string: rawURL),
           let uddg = components.queryItems?.first(where: { $0.name == "uddg" })?.value
        {
            return uddg
        }
        // If it starts with //, prepend https:
        if rawURL.hasPrefix("//") {
            return "https:" + rawURL
        }
        return rawURL
    }

    // MARK: - Brave Parser

    private func parseBraveResults(html: String) -> [SearchResult] {
        var results: [SearchResult] = []

        // Brave search results are in <div class="snippet" ...> with <a class="result-header" href="...">
        let blockPattern = #"<div[^>]*class="snippet[^"]*"[^>]*>(.*?)</div>\s*</div>"#
        let linkPattern = #"<a[^>]*href="([^"]*)"[^>]*class="[^"]*result-header[^"]*"[^>]*>(.*?)</a>"#
        let descPattern = #"<p[^>]*class="[^"]*snippet-description[^"]*"[^>]*>(.*?)</p>"#

        guard let blockRegex = try? NSRegularExpression(pattern: blockPattern, options: .dotMatchesLineSeparators),
              let linkRegex = try? NSRegularExpression(pattern: linkPattern, options: .dotMatchesLineSeparators),
              let descRegex = try? NSRegularExpression(pattern: descPattern, options: .dotMatchesLineSeparators)
        else { return [] }

        let range = NSRange(html.startIndex ..< html.endIndex, in: html)
        let blocks = blockRegex.matches(in: html, range: range)

        for block in blocks {
            guard let blockRange = Range(block.range(at: 1), in: html) else { continue }
            let blockHTML = String(html[blockRange])
            let blockNSRange = NSRange(blockHTML.startIndex ..< blockHTML.endIndex, in: blockHTML)

            guard let linkMatch = linkRegex.firstMatch(in: blockHTML, range: blockNSRange),
                  let urlRange = Range(linkMatch.range(at: 1), in: blockHTML),
                  let titleRange = Range(linkMatch.range(at: 2), in: blockHTML)
            else { continue }

            let url = String(blockHTML[urlRange])
            let title = cleanHTML(String(blockHTML[titleRange]))

            var snippet = ""
            if let descMatch = descRegex.firstMatch(in: blockHTML, range: blockNSRange),
               let descRange = Range(descMatch.range(at: 1), in: blockHTML)
            {
                snippet = cleanHTML(String(blockHTML[descRange]))
            }

            if !url.isEmpty, !title.isEmpty {
                results.append(SearchResult(title: title, url: url, snippet: snippet))
            }
        }

        return results
    }

    // MARK: - Google Parser

    private func parseGoogleResults(html: String) -> [SearchResult] {
        var results: [SearchResult] = []

        // Google results: look for <a href="/url?q=..."> inside <div class="g">
        let linkPattern = #"<a[^>]*href="/url\?q=([^&"]+)[^"]*"[^>]*>"#
        let headingPattern = #"<h3[^>]*>(.*?)</h3>"#

        guard let linkRegex = try? NSRegularExpression(pattern: linkPattern, options: .dotMatchesLineSeparators),
              let headingRegex = try? NSRegularExpression(pattern: headingPattern, options: .dotMatchesLineSeparators)
        else { return [] }

        let range = NSRange(html.startIndex ..< html.endIndex, in: html)
        let linkMatches = linkRegex.matches(in: html, range: range)
        let headingMatches = headingRegex.matches(in: html, range: range)

        for (index, match) in linkMatches.enumerated() {
            guard let urlRange = Range(match.range(at: 1), in: html) else { continue }
            let rawURL = String(html[urlRange])
            let url = rawURL.removingPercentEncoding ?? rawURL

            var title = url
            if index < headingMatches.count,
               let titleRange = Range(headingMatches[index].range(at: 1), in: html)
            {
                title = cleanHTML(String(html[titleRange]))
            }

            if !url.isEmpty, url.hasPrefix("http") {
                results.append(SearchResult(title: title, url: url, snippet: ""))
            }
        }

        return results
    }

    // MARK: - HTML Helpers

    private func cleanHTML(_ text: String) -> String {
        var cleaned = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        cleaned = decodeHTMLEntities(cleaned)
        cleaned = cleaned.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func decodeHTMLEntities(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(of: "&amp;", with: "&")
        result = result.replacingOccurrences(of: "&lt;", with: "<")
        result = result.replacingOccurrences(of: "&gt;", with: ">")
        result = result.replacingOccurrences(of: "&quot;", with: "\"")
        result = result.replacingOccurrences(of: "&#39;", with: "'")
        result = result.replacingOccurrences(of: "&apos;", with: "'")
        result = result.replacingOccurrences(of: "&nbsp;", with: " ")
        result = result.replacingOccurrences(of: "&#x27;", with: "'")
        result = result.replacingOccurrences(of: "&#x2F;", with: "/")
        return result
    }
}

// MARK: - Errors

private enum WebSearchError: LocalizedError {
    case invalidURL
    case invalidResponse
    case rateLimited(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Failed to construct search URL"
        case .invalidResponse:
            "Invalid response from search engine"
        case let .rateLimited(engine):
            "Rate limited by \(engine)"
        }
    }
}
