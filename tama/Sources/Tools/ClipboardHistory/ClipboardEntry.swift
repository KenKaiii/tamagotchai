import Foundation

/// A single clipboard history entry.
struct ClipboardEntry: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let contentType: ContentType
    let textContent: String?
    let imageData: Data?
    let fileURL: String?
    let sourceAppName: String?
    let sourceAppBundle: String?

    enum ContentType: String, Codable {
        case text
        case image
        case fileURL
    }

    /// Returns a truncated preview string for display in the list.
    /// Matches the 50-character limit used by ChatSession.generateTitle.
    var preview: String {
        switch contentType {
        case .text:
            guard let text = textContent else { return "" }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
            guard trimmed.count > 50 else { return trimmed }
            let prefix = String(trimmed.prefix(50))
            if let lastSpace = prefix.lastIndex(of: " ") {
                return String(prefix[..<lastSpace]) + "…"
            }
            return prefix + "…"
        case .image:
            return "[Image]"
        case .fileURL:
            guard let path = fileURL else { return "[File]" }
            return (path as NSString).lastPathComponent
        }
    }

    /// Returns the content as a string suitable for copying back to the pasteboard.
    var copyableText: String? {
        switch contentType {
        case .text: textContent
        case .fileURL: fileURL
        case .image: nil
        }
    }
}
