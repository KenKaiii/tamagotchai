import Foundation

/// A reusable skill/prompt template that can be invoked by the agent.
struct Skill: Codable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var description: String
    var content: String
    var source: SkillSource
    var createdAt: Date
    var updatedAt: Date

    enum SkillSource: String, Codable, Sendable {
        case global
        case project
    }
}

/// Parser for skill Markdown files with optional YAML frontmatter.
enum SkillParser {
    /// Parse a skill file with optional frontmatter.
    /// Supports simple key: value frontmatter between --- delimiters.
    static func parse(content: String, source: Skill.SkillSource, filename: String) -> Skill {
        var name = ""
        var description = ""
        var skillContent = content

        // Check for frontmatter
        if content.hasPrefix("---") {
            if let endIndex = content.index(content.startIndex, offsetBy: 3, limitedBy: content.endIndex) {
                let searchStart = content.index(endIndex, offsetBy: 0)
                if let endRange = content[searchStart...].range(of: "---") {
                    let frontmatter = String(content[searchStart ..< endRange.lowerBound])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    skillContent = String(content[endRange.upperBound...])
                        .trimmingCharacters(in: .whitespacesAndNewlines)

                    for line in frontmatter.components(separatedBy: "\n") {
                        if let colonIndex = line.firstIndex(of: ":") {
                            let key = String(line[..<colonIndex]).trimmingCharacters(in: .whitespaces).lowercased()
                            let value = String(line[line.index(after: colonIndex)...])
                                .trimmingCharacters(in: .whitespaces)
                            if key == "name" {
                                name = value
                            } else if key == "description" {
                                description = value
                            }
                        }
                    }
                }
            }
        }

        // Fall back to filename if no name in frontmatter
        if name.isEmpty {
            name = filename.replacingOccurrences(of: ".md", with: "")
        }

        return Skill(
            id: UUID(),
            name: name,
            description: description,
            content: skillContent,
            source: source,
            createdAt: Date(),
            updatedAt: Date()
        )
    }
}
