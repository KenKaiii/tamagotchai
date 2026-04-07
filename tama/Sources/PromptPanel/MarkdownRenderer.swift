import AppKit
import Foundation
import Highlightr

/// Custom attribute keys for code block rendering.
extension NSAttributedString.Key {
    static let codeBlockContent = NSAttributedString.Key("codeBlockContent")
    static let codeBlockLanguage = NSAttributedString.Key("codeBlockLanguage")
    static let imageURL = NSAttributedString.Key("imageURL")
}

/// Renders markdown text to NSAttributedString with styling suited for a dark HUD panel.
@MainActor
enum MarkdownRenderer {
    // MARK: - Syntax Highlighting

    /// Lazily-created Highlightr instance. Released after `highlightrIdleTimeout` of inactivity.
    private static var _highlightr: Highlightr?
    private static var highlightrReleaseTask: Task<Void, Never>?
    private static let highlightrIdleTimeout: Duration = .seconds(30)

    /// Returns the shared Highlightr, creating it on first access.
    /// Schedules automatic release after 30 seconds of inactivity.
    private static var highlightr: Highlightr? {
        highlightrReleaseTask?.cancel()
        highlightrReleaseTask = nil

        if _highlightr == nil {
            let h = Highlightr()
            h?.setTheme(to: "atom-one-dark")
            _highlightr = h
        }

        // Schedule release after idle timeout
        highlightrReleaseTask = Task { @MainActor in
            try? await Task.sleep(for: highlightrIdleTimeout)
            guard !Task.isCancelled else { return }
            _highlightr = nil
            highlightrReleaseTask = nil
        }

        return _highlightr
    }

    // MARK: - Fonts

    private static let bodyFont = NSFont.systemFont(ofSize: 18, weight: .regular)
    private static let boldFont = NSFont.systemFont(ofSize: 18, weight: .semibold)
    private static let codeFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    private static let codeBoldFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .semibold)
    private static let tableFont = NSFont.systemFont(ofSize: 14, weight: .regular)
    private static let tableBoldFont = NSFont.systemFont(ofSize: 14, weight: .semibold)

    private static func headingFont(level: Int) -> NSFont {
        switch level {
        case 1: NSFont.systemFont(ofSize: 22, weight: .bold)
        case 2: NSFont.systemFont(ofSize: 18, weight: .bold)
        case 3: NSFont.systemFont(ofSize: 16, weight: .semibold)
        case 4: NSFont.systemFont(ofSize: 15, weight: .semibold)
        case 5: NSFont.systemFont(ofSize: 14, weight: .semibold)
        default: NSFont.systemFont(ofSize: 13, weight: .semibold)
        }
    }

    // MARK: - Colors

    private static let textColor = NSColor.labelColor
    private static let dimTextColor = NSColor.secondaryLabelColor
    private static let codeTextColor = NSColor(white: 0.95, alpha: 1)
    private static let codeBlockBg = NSColor(white: 0.15, alpha: 0.6)
    private static let inlineCodeBg = NSColor(white: 0.2, alpha: 0.5)
    private static let linkColor = NSColor.systemBlue
    private static let bulletColor = NSColor.secondaryLabelColor
    private static let blockquoteBorderColor = NSColor(white: 0.4, alpha: 0.8)
    private static let tableBorderColor = NSColor(white: 0.3, alpha: 0.6)
    private static let tableHeaderBg = NSColor(white: 0.18, alpha: 0.5)
    private static let checkboxColor = NSColor.systemGreen

    // MARK: - Public

    /// Renders a markdown string to an attributed string.
    static func render(_ markdown: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let lines = markdown.components(separatedBy: "\n")
        var idx = 0

        while idx < lines.count {
            let line = lines[idx]

            // Code block fences
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                let lang = line.trimmingCharacters(in: .whitespaces)
                    .dropFirst(3)
                    .trimmingCharacters(in: .whitespaces)
                idx += 1
                var codeLines: [String] = []
                while idx < lines.count {
                    if lines[idx].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        idx += 1
                        break
                    }
                    codeLines.append(lines[idx])
                    idx += 1
                }
                appendCodeBlock(to: result, content: codeLines.joined(separator: "\n"), language: lang)
                continue
            }

            // Empty line — skip consecutive blanks; a single blank is
            // represented implicitly via paragraphSpacing on the surrounding blocks.
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                idx += 1
                continue
            }

            // Headings (h1–h6)
            if let headingMatch = line.range(of: #"^(#{1,6})\s+"#, options: .regularExpression) {
                let hashes = line[headingMatch].count(where: { $0 == "#" })
                let text = String(line[headingMatch.upperBound...])
                appendHeading(to: result, text: text, level: hashes)
                idx += 1
                continue
            }

            // Horizontal rule: ---, ***, ___, or with spaces
            if isHorizontalRule(line) {
                appendHorizontalRule(to: result)
                idx += 1
                continue
            }

            // Table: line starting with | and next line is separator
            if line.contains("|"),
               idx + 1 < lines.count,
               lines[idx + 1].range(of: #"\|?\s*:?-+:?\s*\|"#, options: .regularExpression) != nil
            {
                var tableLines: [String] = []
                while idx < lines.count, lines[idx].contains("|") {
                    tableLines.append(lines[idx])
                    idx += 1
                }
                appendTable(to: result, lines: tableLines)
                continue
            }

            // Blockquote (possibly nested, possibly multi-line)
            if line.hasPrefix(">") {
                var quoteLines: [String] = []
                while idx < lines.count, lines[idx].hasPrefix(">") {
                    quoteLines.append(lines[idx])
                    idx += 1
                }
                appendBlockquote(to: result, lines: quoteLines)
                continue
            }

            // Unordered list item (with nesting detection)
            if isUnorderedListItem(line) {
                var listLines: [String] = []
                while idx < lines.count, isListItem(lines[idx]) {
                    listLines.append(lines[idx])
                    idx += 1
                }
                appendListBlock(to: result, lines: listLines)
                continue
            }

            // Ordered list item
            if isOrderedListItem(line) {
                var listLines: [String] = []
                while idx < lines.count, isListItem(lines[idx]) {
                    listLines.append(lines[idx])
                    idx += 1
                }
                appendListBlock(to: result, lines: listLines)
                continue
            }

            // Regular paragraph
            appendParagraph(to: result, text: line)
            idx += 1
        }

        // Strip trailing newlines down to exactly one so the last paragraph
        // is properly terminated (preventing attribute leakage when content is
        // appended after the rendered output) without leaving empty visual space.
        while result.length > 1,
              result.attributedSubstring(from: NSRange(location: result.length - 1, length: 1))
              .string == "\n",
              result.attributedSubstring(from: NSRange(location: result.length - 2, length: 1))
              .string == "\n"
        {
            result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1))
        }

        return result
    }

    // MARK: - Line classification helpers

    private static func isHorizontalRule(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3 else { return false }
        let stripped = trimmed.filter { $0 != " " }
        let chars = Set(stripped)
        return chars.count == 1 && (chars.contains("-") || chars.contains("*") || chars.contains("_"))
    }

    private static func isUnorderedListItem(_ line: String) -> Bool {
        let trimmed = line.replacingOccurrences(of: "^\\ +", with: "", options: .regularExpression)
        return trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ")
    }

    private static func isOrderedListItem(_ line: String) -> Bool {
        let trimmed = line.replacingOccurrences(of: "^\\ +", with: "", options: .regularExpression)
        return trimmed.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil
    }

    private static func isListItem(_ line: String) -> Bool {
        isUnorderedListItem(line) || isOrderedListItem(line)
    }

    // MARK: - Headings

    private static func appendHeading(
        to result: NSMutableAttributedString,
        text: String,
        level: Int
    ) {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = result.length > 0 ? (level <= 2 ? 12 : 8) : 0
        style.paragraphSpacing = 4
        style.lineSpacing = 2

        let font = headingFont(level: level)
        let inline = renderInline(text, baseFont: font)
        inline.addAttributes(
            [.paragraphStyle: style],
            range: NSRange(location: 0, length: inline.length)
        )
        result.append(inline)
        result.append(plain("\n", font: font))
    }

    // MARK: - Paragraphs

    private static func appendParagraph(
        to result: NSMutableAttributedString,
        text: String
    ) {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        style.paragraphSpacingBefore = result.length > 0 ? 8 : 0
        style.paragraphSpacing = 0

        let inline = renderInline(text, baseFont: bodyFont)
        inline.addAttributes(
            [.paragraphStyle: style],
            range: NSRange(location: 0, length: inline.length)
        )
        result.append(inline)
        result.append(plain("\n", font: bodyFont))
    }

    // MARK: - Lists (with nesting and task items)

    private static func appendListBlock(
        to result: NSMutableAttributedString,
        lines: [String]
    ) {
        for (lineIdx, line) in lines.enumerated() {
            let indent = line.prefix(while: { $0 == " " }).count
            let nestLevel = indent / 2
            let trimmed = String(line.dropFirst(indent))

            // Detect task list: - [x] or - [ ]
            var isTask = false
            var taskChecked = false
            var content = trimmed

            if let taskMatch = trimmed.range(
                of: #"^[-*•]\s+\[([ xX])\]\s+"#,
                options: .regularExpression
            ) {
                isTask = true
                let checkChar = trimmed[trimmed.index(trimmed.startIndex, offsetBy: trimmed.distance(
                    from: trimmed.startIndex,
                    to: taskMatch.lowerBound
                ) + 3)]
                taskChecked = checkChar == "x" || checkChar == "X"
                content = String(trimmed[taskMatch.upperBound...])
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ") {
                content = String(trimmed.dropFirst(2))
            } else if let match = trimmed.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
                content = String(trimmed[match.upperBound...])
            }

            // Determine bullet/number string
            let bullet: String
            let isOrdered = isOrderedListItem(trimmed)
            if isTask {
                bullet = taskChecked ? "☑" : "☐"
            } else if isOrdered {
                let numStr = trimmed.prefix(while: { $0.isNumber || $0 == "." })
                bullet = String(numStr)
            } else {
                let bullets = ["•", "◦", "▸", "▹"]
                bullet = bullets[min(nestLevel, bullets.count - 1)]
            }

            // Measure bullet width for tab alignment (Markdownosaur approach)
            let bulletFont = isOrdered
                ? NSFont.monospacedDigitSystemFont(ofSize: bodyFont.pointSize, weight: .regular)
                : bodyFont
            let bulletWidth = ceil(
                NSAttributedString(string: bullet, attributes: [.font: bulletFont]).size().width
            )

            let baseLeftMargin: CGFloat = 8
            let leftMarginOffset = baseLeftMargin + (20.0 * CGFloat(nestLevel))
            let spacingFromBullet: CGFloat = 8
            let firstTabLocation = leftMarginOffset + bulletWidth
            let secondTabLocation = firstTabLocation + spacingFromBullet

            let style = NSMutableParagraphStyle()
            style.lineSpacing = 3
            style.paragraphSpacing = 2
            style.paragraphSpacingBefore = lineIdx == 0 && result.length > 0 ? 6 : 0
            style.tabStops = [
                NSTextTab(textAlignment: .right, location: firstTabLocation),
                NSTextTab(textAlignment: .left, location: secondTabLocation),
            ]
            style.headIndent = secondTabLocation

            let bulletColor = isTask ? (taskChecked ? checkboxColor : dimTextColor) : bulletColor
            let prefix = NSAttributedString(
                string: "\t\(bullet)\t",
                attributes: [
                    .font: bulletFont,
                    .foregroundColor: bulletColor,
                    .paragraphStyle: style,
                ]
            )

            let inline = renderInline(content, baseFont: bodyFont)
            if isTask, taskChecked {
                inline.addAttributes(
                    [
                        .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                        .foregroundColor: dimTextColor,
                    ],
                    range: NSRange(location: 0, length: inline.length)
                )
            }
            inline.addAttributes(
                [.paragraphStyle: style],
                range: NSRange(location: 0, length: inline.length)
            )

            result.append(prefix)
            result.append(inline)
            result.append(plain("\n", font: bodyFont))
        }
    }

    // MARK: - Code Blocks

    private static let lineNumFont = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .regular)
    private static let lineNumColor = NSColor.white.withAlphaComponent(0.85)

    private static func appendCodeBlock(
        to result: NSMutableAttributedString,
        content: String,
        language: String
    ) {
        // Tab stops: right-aligned number gutter at 26px, code starts at 34px
        let numberTabStop = NSTextTab(textAlignment: .right, location: 26)
        let codeTabStop = NSTextTab(textAlignment: .left, location: 34)

        // Try syntax highlighting via Highlightr, fall back to plain mono text
        let highlighted: NSAttributedString
        let lang = language.isEmpty ? nil : language
        if let h = highlightr?.highlight(content, as: lang) {
            let m = NSMutableAttributedString(attributedString: h)
            m.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: m.length))
            m.addAttribute(.font, value: codeFont, range: NSRange(location: 0, length: m.length))
            highlighted = m
        } else {
            highlighted = NSAttributedString(
                string: content,
                attributes: [.font: codeFont, .foregroundColor: codeTextColor]
            )
        }

        // Split highlighted attributed string by \n boundaries
        let highlightedStr = highlighted.string as NSString
        var lineRanges: [NSRange] = []
        var searchStart = 0
        while searchStart <= highlightedStr.length {
            let nlRange = highlightedStr.range(
                of: "\n",
                range: NSRange(location: searchStart, length: highlightedStr.length - searchStart)
            )
            if nlRange.location != NSNotFound {
                lineRanges.append(NSRange(location: searchStart, length: nlRange.location - searchStart))
                searchStart = nlRange.location + 1
            } else {
                lineRanges.append(NSRange(location: searchStart, length: highlightedStr.length - searchStart))
                break
            }
        }

        let code = NSMutableAttributedString()
        let lineCount = lineRanges.count

        for (i, range) in lineRanges.enumerated() {
            // Build paragraph style for this line
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 2
            style.tabStops = [numberTabStop, codeTabStop]
            style.headIndent = 34
            style.tailIndent = -12

            if i == 0 {
                style.paragraphSpacingBefore = 38 // room for header drawn in draw()
            } else {
                style.paragraphSpacingBefore = 0
            }

            if i == lineCount - 1 {
                style.paragraphSpacing = 14 // spacing after block
            } else {
                style.paragraphSpacing = 0
            }

            // Line number prefix: \t<num>\t
            let lineNumStr = NSAttributedString(
                string: "\t\(i + 1)\t",
                attributes: [
                    .font: lineNumFont,
                    .foregroundColor: lineNumColor,
                    .paragraphStyle: style,
                ]
            )
            code.append(lineNumStr)

            // Append the highlighted code for this line
            let lineContent = highlighted.attributedSubstring(from: range)
            let mutableLine = NSMutableAttributedString(attributedString: lineContent)
            mutableLine.addAttribute(
                .paragraphStyle, value: style,
                range: NSRange(location: 0, length: mutableLine.length)
            )
            code.append(mutableLine)

            if i < lineCount - 1 {
                code.append(NSAttributedString(
                    string: "\n",
                    attributes: [.font: codeFont, .paragraphStyle: style]
                ))
            }
        }

        // Apply custom attributes for ResponseTextView to detect code blocks
        let fullRange = NSRange(location: 0, length: code.length)
        code.addAttributes(
            [
                .codeBlockContent: content,
                .codeBlockLanguage: language,
            ],
            range: fullRange
        )

        result.append(code)

        // Trailing newline with reset paragraph style to prevent leaking
        let resetStyle = NSMutableParagraphStyle()
        resetStyle.paragraphSpacingBefore = 0
        resetStyle.paragraphSpacing = 0
        result.append(NSAttributedString(
            string: "\n",
            attributes: [
                .font: bodyFont,
                .foregroundColor: textColor,
                .paragraphStyle: resetStyle,
            ]
        ))
    }

    // MARK: - Blockquotes

    private static func appendBlockquote(
        to result: NSMutableAttributedString,
        lines: [String]
    ) {
        for line in lines {
            // Count nesting depth and strip > prefixes
            var stripped = line
            var depth = 0
            while stripped.hasPrefix(">") {
                stripped = String(stripped.dropFirst())
                if stripped.hasPrefix(" ") {
                    stripped = String(stripped.dropFirst())
                }
                depth += 1
            }

            let leftIndent = CGFloat(16 * depth)

            let style = NSMutableParagraphStyle()
            style.headIndent = leftIndent
            style.firstLineHeadIndent = leftIndent
            style.paragraphSpacing = 4
            style.lineSpacing = 3

            // Use bar prefix for visual quote indicator
            let barStr = String(repeating: "┃ ", count: depth)
            let bar = NSAttributedString(
                string: barStr,
                attributes: [
                    .font: bodyFont,
                    .foregroundColor: blockquoteBorderColor,
                ]
            )

            let inline = renderInline(stripped, baseFont: bodyFont)
            inline.addAttributes(
                [
                    .paragraphStyle: style,
                    .foregroundColor: dimTextColor,
                ],
                range: NSRange(location: 0, length: inline.length)
            )

            result.append(bar)
            result.append(inline)
            result.append(plain("\n", font: bodyFont))
        }
    }

    // MARK: - Tables (using NSTextTable for proper column layout)

    private static func appendTable(
        to result: NSMutableAttributedString,
        lines: [String]
    ) {
        guard lines.count >= 2 else { return }

        // Parse alignment from separator row
        var alignments: [NSTextAlignment] = []
        if lines.count >= 2 {
            let sepLine = lines[1]
            let sepCells = sepLine.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            for cell in sepCells {
                let left = cell.hasPrefix(":")
                let right = cell.hasSuffix(":")
                if left, right {
                    alignments.append(.center)
                } else if right {
                    alignments.append(.right)
                } else {
                    alignments.append(.left)
                }
            }
        }

        // Parse data rows (skip separator)
        let parsedRows: [[String]] = lines.compactMap { line in
            if line.range(of: #"^\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$"#, options: .regularExpression) != nil {
                return nil
            }
            let cells = line.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return cells
        }

        guard !parsedRows.isEmpty else { return }
        let columnCount = parsedRows.map(\.count).max() ?? 1

        // Create the NSTextTable
        let table = NSTextTable()
        table.numberOfColumns = columnCount
        table.collapsesBorders = true
        table.hidesEmptyCells = false

        let borderColor = tableBorderColor

        for (rowIdx, row) in parsedRows.enumerated() {
            let isHeader = rowIdx == 0

            for colIdx in 0 ..< columnCount {
                let cellText = colIdx < row.count ? row[colIdx] : ""

                // Create the table block for this cell
                let block = NSTextTableBlock(
                    table: table,
                    startingRow: rowIdx,
                    rowSpan: 1,
                    startingColumn: colIdx,
                    columnSpan: 1
                )

                // Set equal column widths
                let widthPct = CGFloat(100.0 / Double(columnCount))
                block.setContentWidth(widthPct, type: .percentageValueType)

                // Cell padding
                block.setWidth(6.0, type: .absoluteValueType, for: .padding)

                // Borders — thin lines on all edges
                for edge: NSRectEdge in [.minX, .maxX, .minY, .maxY] {
                    block.setWidth(0.5, type: .absoluteValueType, for: .border, edge: edge)
                    block.setBorderColor(borderColor, for: edge)
                }

                // Header background
                if isHeader {
                    block.backgroundColor = tableHeaderBg
                }

                // Build the paragraph style with the text block
                let paraStyle = NSMutableParagraphStyle()
                paraStyle.textBlocks = [block]
                paraStyle.lineSpacing = 2
                if colIdx < alignments.count {
                    paraStyle.alignment = alignments[colIdx]
                }

                // Render cell content
                let font = isHeader ? tableBoldFont : tableFont
                let inline = renderInline(cellText, baseFont: font)
                inline.addAttributes(
                    [.paragraphStyle: paraStyle],
                    range: NSRange(location: 0, length: inline.length)
                )

                // Each cell needs a trailing newline for NSTextTable to work
                let cellStr = NSMutableAttributedString()
                cellStr.append(inline)
                cellStr.append(NSAttributedString(
                    string: "\n",
                    attributes: [
                        .paragraphStyle: paraStyle,
                        .font: font,
                        .foregroundColor: textColor,
                    ]
                ))

                result.append(cellStr)
            }
        }

        // Add spacing after the table
        result.append(plain("\n", font: tableFont))
    }

    // MARK: - Horizontal Rule

    private static func appendHorizontalRule(to result: NSMutableAttributedString) {
        let line = String(repeating: "─", count: 50)
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = 8
        style.paragraphSpacing = 8
        style.alignment = .center

        result.append(NSAttributedString(
            string: line + "\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor.separatorColor,
                .paragraphStyle: style,
            ]
        ))
    }
}

// MARK: - Inline rendering & helpers

extension MarkdownRenderer {
    /// Renders inline markdown (bold, italic, code, links, escape chars) within a text span.
    static func renderInline(
        _ text: String,
        baseFont: NSFont
    ) -> NSMutableAttributedString {
        let result = NSMutableAttributedString()
        let scanner = InlineScanner(text)

        while !scanner.isAtEnd {
            // Escape character
            if scanner.currentChar == "\\", scanner.hasNext {
                scanner.advance()
                let escaped = scanner.advance()
                result.append(NSAttributedString(
                    string: String(escaped),
                    attributes: [.font: baseFont, .foregroundColor: textColor]
                ))
            }
            // Bold + italic ***text***
            else if let content = scanner.scan(between: "***", and: "***") {
                let font = NSFontManager.shared.convert(
                    baseFont, toHaveTrait: [.boldFontMask, .italicFontMask]
                )
                result.append(attributed(content, font: font))
            }
            // Bold **text**
            else if let content = scanner.scan(between: "**", and: "**") {
                let bold = baseFont == codeFont ? codeBoldFont : boldFont
                result.append(attributed(content, font: bold))
            }
            // Bold __text__
            else if let content = scanner.scan(between: "__", and: "__") {
                result.append(attributed(content, font: boldFont))
            }
            // Italic *text* (but not ** which is bold)
            else if let content = scanner.scan(between: "*", and: "*") {
                let font = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
                result.append(attributed(content, font: font))
            }
            // Italic _text_
            else if let content = scanner.scan(between: "_", and: "_") {
                let font = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
                result.append(attributed(content, font: font))
            }
            // Strikethrough ~~text~~
            else if let content = scanner.scan(between: "~~", and: "~~") {
                result.append(NSAttributedString(string: content, attributes: [
                    .font: baseFont,
                    .foregroundColor: textColor,
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                ]))
            }
            // Inline code `text`
            else if let content = scanner.scan(between: "`", and: "`") {
                result.append(NSAttributedString(string: " \(content) ", attributes: [
                    .font: codeFont,
                    .foregroundColor: codeTextColor,
                    .backgroundColor: inlineCodeBg,
                ]))
            }
            // Link [text](url) — optionally with title
            else if let (linkText, url) = scanner.scanLink() {
                // Strip optional title from URL: "url \"title\""
                let cleanURL = url.components(separatedBy: " ").first ?? url
                let linkAttrs = linkAttributes(baseFont: baseFont, url: cleanURL)
                result.append(NSAttributedString(string: linkText, attributes: linkAttrs))
            }
            // Bare URL: https://... or http://...
            else if let bareURL = scanner.scanBareURL() {
                let linkAttrs = linkAttributes(baseFont: baseFont, url: bareURL)
                // Insert zero-width spaces after / and - so the URL can word-wrap
                let wrappable = bareURL
                    .replacingOccurrences(of: "/", with: "/\u{200B}")
                    .replacingOccurrences(of: "-", with: "-\u{200B}")
                    .replacingOccurrences(of: "=", with: "=\u{200B}")
                    .replacingOccurrences(of: "&", with: "&\u{200B}")
                result.append(NSAttributedString(string: wrappable, attributes: linkAttrs))
            }
            // Image ![alt](url) — render inline image or fallback to [🖼 alt]
            else if scanner.currentChar == "!", scanner.peekNext == "[" {
                scanner.advance() // skip !
                if let (altText, urlString) = scanner.scanLink() {
                    if let image = ImageCache.load(from: urlString) {
                        // Scale to fit panel width (max ~600px)
                        let maxWidth: CGFloat = 600
                        let scale = min(1.0, maxWidth / image.size.width)
                        let scaledSize = NSSize(
                            width: image.size.width * scale,
                            height: image.size.height * scale
                        )
                        let scaledImage = NSImage(size: scaledSize)
                        scaledImage.lockFocus()
                        image.draw(
                            in: NSRect(origin: .zero, size: scaledSize),
                            from: NSRect(origin: .zero, size: image.size),
                            operation: .copy,
                            fraction: 1.0
                        )
                        scaledImage.unlockFocus()

                        let attachment = NSTextAttachment()
                        let cell = NSTextAttachmentCell(imageCell: scaledImage)
                        attachment.attachmentCell = cell
                        attachment.bounds = NSRect(
                            origin: .zero, size: scaledSize
                        )
                        let attachStr = NSMutableAttributedString(
                            attributedString: NSAttributedString(attachment: attachment)
                        )
                        let fullRange = NSRange(location: 0, length: attachStr.length)
                        attachStr.addAttribute(.imageURL, value: urlString, range: fullRange)
                        result.append(attachStr)
                    } else {
                        let display = altText.isEmpty ? "🖼 Image" : "🖼 \(altText)"
                        result.append(NSAttributedString(string: display, attributes: [
                            .font: baseFont,
                            .foregroundColor: dimTextColor,
                        ]))
                    }
                } else {
                    result.append(attributed("!", font: baseFont))
                }
            }
            // Plain character
            else {
                let char = scanner.advance()
                result.append(NSAttributedString(
                    string: String(char),
                    attributes: [.font: baseFont, .foregroundColor: textColor]
                ))
            }
        }

        return result
    }

    /// Builds the standard link attributes (clickable, blue, underlined).
    private static func linkAttributes(baseFont: NSFont, url: String) -> [NSAttributedString.Key: Any] {
        [
            .font: baseFont,
            .foregroundColor: linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .link: url,
            .cursor: NSCursor.pointingHand,
        ]
    }

    static func plain(_ str: String, font: NSFont) -> NSAttributedString {
        NSAttributedString(string: str, attributes: [
            .font: font,
            .foregroundColor: textColor,
        ])
    }

    static func attributed(_ str: String, font: NSFont) -> NSAttributedString {
        NSAttributedString(string: str, attributes: [
            .font: font,
            .foregroundColor: textColor,
        ])
    }
}

// MARK: - Inline Scanner

/// Simple character scanner for inline markdown parsing.
private final class InlineScanner {
    private let text: [Character]
    private(set) var position: Int

    var isAtEnd: Bool { position >= text.count }
    var hasNext: Bool { position + 1 < text.count }
    var currentChar: Character { text[position] }
    var peekNext: Character? { hasNext ? text[position + 1] : nil }

    init(_ string: String) {
        text = Array(string)
        position = 0
    }

    /// Try to scan content between matching delimiters. Returns content if found.
    func scan(between open: String, and close: String) -> String? {
        let openChars = Array(open)
        let closeChars = Array(close)

        guard hasPrefix(openChars) else { return nil }

        let start = position + openChars.count
        guard start < text.count else { return nil }

        // Don't match if the character after the opening delimiter is a space
        if text[start] == " " { return nil }

        var searchPos = start
        while searchPos <= text.count - closeChars.count {
            if Array(text[searchPos ..< searchPos + closeChars.count]) == closeChars {
                // Don't match if the character before closing is a space
                if searchPos > start, text[searchPos - 1] == " " {
                    searchPos += 1
                    continue
                }
                let content = String(text[start ..< searchPos])
                guard !content.isEmpty else {
                    searchPos += 1
                    continue
                }
                position = searchPos + closeChars.count
                return content
            }
            searchPos += 1
        }

        return nil
    }

    /// Try to scan a markdown link [text](url).
    func scanLink() -> (text: String, url: String)? {
        guard position < text.count, text[position] == "[" else { return nil }

        var searchPos = position + 1
        var bracketDepth = 1
        // Find closing ] respecting nested brackets
        while searchPos < text.count, bracketDepth > 0 {
            if text[searchPos] == "[" { bracketDepth += 1 }
            if text[searchPos] == "]" { bracketDepth -= 1 }
            if bracketDepth > 0 { searchPos += 1 }
        }
        guard searchPos < text.count, bracketDepth == 0 else { return nil }
        guard searchPos + 1 < text.count, text[searchPos + 1] == "(" else { return nil }

        let linkText = String(text[position + 1 ..< searchPos])
        let urlStart = searchPos + 2
        var urlEnd = urlStart
        var parenDepth = 1
        while urlEnd < text.count, parenDepth > 0 {
            if text[urlEnd] == "(" { parenDepth += 1 }
            if text[urlEnd] == ")" { parenDepth -= 1 }
            if parenDepth > 0 { urlEnd += 1 }
        }
        guard urlEnd < text.count, parenDepth == 0 else { return nil }

        let url = String(text[urlStart ..< urlEnd])
        position = urlEnd + 1
        return (linkText, url)
    }

    /// Try to scan a bare URL starting with http:// or https://.
    func scanBareURL() -> String? {
        // Check for http:// or https:// at current position
        let remaining = String(text[position...])
        let prefixes = ["https://", "http://"]
        guard prefixes.contains(where: { remaining.hasPrefix($0) }) else { return nil }

        // Consume characters valid in a URL until we hit whitespace, end, or trailing punctuation
        let urlTerminators: Set<Character> = [" ", "\t", "\n", "\r", "<", ">", "\"", "'"]
        var end = position
        while end < text.count, !urlTerminators.contains(text[end]) {
            end += 1
        }

        // Strip common trailing punctuation that's probably not part of the URL
        let trailingPunctuation: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "]"]
        while end > position, trailingPunctuation.contains(text[end - 1]) {
            // Keep ) if there's a matching ( in the URL (common in Wikipedia links)
            if text[end - 1] == ")" {
                let slice = text[position ..< end]
                if slice.count(where: { $0 == "(" }) >= slice.count(where: { $0 == ")" }) {
                    break
                }
            }
            end -= 1
        }

        let url = String(text[position ..< end])
        guard url.count > 8 else { return nil } // must have more than just the scheme
        position = end
        return url
    }

    /// Advance one character and return it.
    @discardableResult
    func advance() -> Character {
        let char = text[position]
        position += 1
        return char
    }

    private func hasPrefix(_ chars: [Character]) -> Bool {
        guard position + chars.count <= text.count else { return false }
        return Array(text[position ..< position + chars.count]) == chars
    }
}
