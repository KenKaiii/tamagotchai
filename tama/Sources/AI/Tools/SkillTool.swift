import Foundation
import os

private let logger = Logger(
    subsystem: "com.unstablemind.tama",
    category: "tool.skill"
)

/// A tool that allows the agent to invoke skills by name.
/// Skills are reusable prompt templates stored in ~/Documents/Tama/.gg/skills/
struct SkillTool: AgentTool {
    let name = "skill"
    let description = """
    Invoke a skill by name to get specialized instructions for a task.
    Use this when the user asks you to use a specific skill or when a skill's
    expertise would help complete the task better.

    To see available skills, ask the user to check the Skills tab (⌥Space → Skills)
    or ask them what skills they have available.
    """

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "skill": [
                    "type": "string",
                    "description": "The name of the skill to invoke",
                ],
                "args": [
                    "type": "string",
                    "description": "Optional arguments or context for the skill",
                ],
            ],
            "required": ["skill"],
        ]
    }

    func execute(args: [String: Any]) async throws -> ToolOutput {
        guard let skillName = args["skill"] as? String else {
            throw SkillToolError.missingSkillName
        }
        let context = args["args"] as? String

        // Access SkillStore on MainActor
        let result: SkillResult = await MainActor.run {
            // Reload skills to ensure we have the latest
            SkillStore.shared.loadAll()

            guard let skill = SkillStore.shared.skill(named: skillName) else {
                let available = SkillStore.shared.skills.map(\.name).joined(separator: ", ")
                return SkillResult(
                    skill: nil,
                    error: "Error: Skill '\(skillName)' not found. Available skills: \(available.isEmpty ? "none" : available)"
                )
            }

            logger.info("Invoking skill: \(skill.name)")
            return SkillResult(skill: skill, error: nil)
        }

        if let error = result.error {
            return ToolOutput(text: error)
        }

        guard let skill = result.skill else {
            return ToolOutput(text: "Error: Could not load skill")
        }

        var parts: [String] = []
        parts.append("<skill_content name=\"\(skill.name)\">\(skill.content)</skill_content>")

        if let context, !context.isEmpty {
            parts.append("User context: \(context)")
        }

        parts.append("Treat the above skill instructions as authoritative. Follow them to complete the task.")

        return ToolOutput(text: parts.joined(separator: "\n\n"))
    }
}

/// Helper struct for returning skill lookup results from MainActor
private struct SkillResult {
    let skill: Skill?
    let error: String?
}

enum SkillToolError: LocalizedError {
    case missingSkillName

    var errorDescription: String? {
        switch self {
        case .missingSkillName:
            "Missing required 'skill' parameter"
        }
    }
}
