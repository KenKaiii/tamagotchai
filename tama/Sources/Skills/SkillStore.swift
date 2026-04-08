import Foundation
import os

private let logger = Logger(
    subsystem: "com.unstablemind.tama",
    category: "skills"
)

/// Manages loading, saving, and discovering skills from the .gg/skills directory.
@MainActor
final class SkillStore {
    static let shared = SkillStore()

    private(set) var skills: [Skill] = []

    private init() {
        loadAll()
    }

    /// Loads all skills from the global skills directory.
    func loadAll() {
        logger.debug("Loading skills from disk...")
        do {
            let dir = try Self.skillsDirectory()
            let fm = FileManager.default
            guard fm.fileExists(atPath: dir.path) else {
                logger.info("No skills directory yet — creating it")
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
                skills = []
                return
            }

            let files = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "md" }

            var loaded: [Skill] = []
            for file in files {
                do {
                    let content = try String(contentsOf: file, encoding: .utf8)
                    let skill = SkillParser.parse(
                        content: content,
                        source: .global,
                        filename: file.lastPathComponent
                    )
                    loaded.append(skill)
                } catch {
                    logger.error("Failed to load skill \(file.lastPathComponent): \(error.localizedDescription)")
                }
            }

            skills = loaded.sorted { $0.name.lowercased() < $1.name.lowercased() }
            let count = skills.count
            logger.info("Loaded \(count) skills from disk")
        } catch {
            logger.error("Failed to load skills: \(error.localizedDescription)")
            skills = []
        }
    }

    /// Saves a skill to disk as a Markdown file with frontmatter.
    func save(skill: Skill) {
        do {
            let dir = try Self.skillsDirectory()
            let filename = "\(skill.name).md"
            let url = dir.appendingPathComponent(filename)

            var lines: [String] = []
            lines.append("---")
            lines.append("name: \(skill.name)")
            lines.append("description: \(skill.description)")
            lines.append("---")
            lines.append("")
            lines.append(skill.content)

            let fileContent = lines.joined(separator: "\n")
            try fileContent.write(to: url, atomically: true, encoding: .utf8)

            // Update in-memory list
            if let idx = skills.firstIndex(where: { $0.id == skill.id }) {
                skills[idx] = skill
            } else {
                skills.append(skill)
                skills.sort { $0.name.lowercased() < $1.name.lowercased() }
            }

            logger.debug("Saved skill '\(skill.name)'")
        } catch {
            logger.error("Failed to save skill: \(error.localizedDescription)")
        }
    }

    /// Deletes a skill from disk and memory.
    func delete(id: UUID) {
        guard let skill = skills.first(where: { $0.id == id }) else { return }
        do {
            let dir = try Self.skillsDirectory()
            let filename = "\(skill.name).md"
            let url = dir.appendingPathComponent(filename)
            try FileManager.default.removeItem(at: url)
            skills.removeAll { $0.id == id }
            logger.info("Deleted skill \(skill.name)")
        } catch {
            logger.error("Failed to delete skill \(skill.name): \(error.localizedDescription)")
        }
    }

    /// Returns a skill by ID.
    func skill(for id: UUID) -> Skill? {
        skills.first { $0.id == id }
    }

    /// Returns a skill by name (case-insensitive).
    func skill(named name: String) -> Skill? {
        skills.first { $0.name.lowercased() == name.lowercased() }
    }

    /// Searches skills by name or description.
    func search(query: String) -> [Skill] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return skills }
        return skills.filter {
            $0.name.lowercased().contains(trimmed) ||
                $0.description.lowercased().contains(trimmed)
        }
    }

    /// Formats skills as a summary list for the system prompt.
    func formatForPrompt() -> String {
        let skillsList: String = if skills.isEmpty {
            "_No skills installed yet._"
        } else {
            skills
                .map { "- **\($0.name)**\($0.description.isEmpty ? "" : ": \($0.description)")" }
                .joined(separator: "\n")
        }

        return """
        ## Skills

        Skills are reusable prompt templates stored as Markdown files in `~/Documents/Tama/.gg/skills/`.

        **Installing skills:** If a user wants to add a skill from GitHub or elsewhere, create a `.md` file
        in that folder with YAML frontmatter (name, description) followed by the skill instructions.

        **Available skills:** Use the **skill** tool to invoke one.

        \(skillsList)
        """
    }

    /// Returns the path to the skills directory: ~/Documents/Tama/.gg/skills
    private static func skillsDirectory() throws -> URL {
        let documents = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = documents
            .appendingPathComponent("Tama", isDirectory: true)
            .appendingPathComponent(".gg", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
