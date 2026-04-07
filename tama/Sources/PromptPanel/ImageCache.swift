import AppKit

/// Simple image cache for loading local images referenced in markdown responses.
@MainActor
enum ImageCache {
    private static var cache: [String: NSImage] = [:]

    /// Loads an image from a local file path or file:// URL. Returns nil for http(s) URLs.
    /// Results are cached by the original URL string.
    static func load(from urlString: String) -> NSImage? {
        if let cached = cache[urlString] {
            return cached
        }

        let path: String
        if urlString.hasPrefix("file://") {
            guard let fileURL = URL(string: urlString) else { return nil }
            path = fileURL.path
        } else if urlString.hasPrefix("/") {
            path = urlString
        } else if urlString.hasPrefix("~") {
            path = NSString(string: urlString).expandingTildeInPath
        } else if urlString.hasPrefix("http://") || urlString.hasPrefix("https://") {
            return nil
        } else {
            return nil
        }

        guard let image = NSImage(contentsOfFile: path) else { return nil }
        cache[urlString] = image
        return image
    }

    /// Clears the cache (e.g. on session reset).
    static func clear() {
        cache.removeAll()
    }
}
