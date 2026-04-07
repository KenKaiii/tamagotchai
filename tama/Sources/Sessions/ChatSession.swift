import Foundation

/// A single message in a chat session, with Codable persistence.
struct ChatMessage: Codable, Identifiable {
    let id: UUID
    let role: MessageRole
    let content: [MessageContent]
    let timestamp: Date

    enum MessageRole: String, Codable { case user, assistant }
}

/// A content block within a message — mirrors the Claude API content types.
enum MessageContent: Codable {
    case text(String)
    case toolUse(id: String, name: String, input: Data)
    case toolResult(toolUseId: String, content: String)

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case type, text, id, name, input, toolUseId, content
    }

    private enum ContentType: String, Codable {
        case text, toolUse, toolResult
        // Legacy types from removed server-side web search — decoded as .text("") and filtered out.
        case serverToolUse, serverToolResult, serverToolResultError
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .text(text):
            try container.encode(ContentType.text, forKey: .type)
            try container.encode(text, forKey: .text)
        case let .toolUse(id, name, input):
            try container.encode(ContentType.toolUse, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            try container.encode(input, forKey: .input)
        case let .toolResult(toolUseId, content):
            try container.encode(ContentType.toolResult, forKey: .type)
            try container.encode(toolUseId, forKey: .toolUseId)
            try container.encode(content, forKey: .content)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(ContentType.self, forKey: .type)
        switch type {
        case .text:
            let text = try container.decode(String.self, forKey: .text)
            self = .text(text)
        case .toolUse:
            let id = try container.decode(String.self, forKey: .id)
            let name = try container.decode(String.self, forKey: .name)
            let input = try container.decode(Data.self, forKey: .input)
            self = .toolUse(id: id, name: name, input: input)
        case .toolResult:
            let toolUseId = try container.decode(String.self, forKey: .toolUseId)
            let content = try container.decode(String.self, forKey: .content)
            self = .toolResult(toolUseId: toolUseId, content: content)
        case .serverToolUse, .serverToolResult, .serverToolResultError:
            // Legacy server-side web search blocks — drop silently.
            self = .text("")
        }
    }
}

/// The type of session — chat (default), reminders, or routines.
enum SessionType: String, Codable {
    case chat
    case reminders
    case routines
}

/// A persisted chat session containing messages and metadata.
struct ChatSession: Codable, Identifiable {
    let id: UUID
    var title: String
    var messages: [ChatMessage]
    let createdAt: Date
    var updatedAt: Date
    /// The mood icon raw value assigned to this session for display in the session list.
    var moodIcon: String
    /// The type of session — regular chat, reminders, or routines.
    var sessionType: SessionType

    init(
        id: UUID,
        title: String,
        messages: [ChatMessage],
        createdAt: Date,
        updatedAt: Date,
        moodIcon: String = MenuBarMood.Mood.allCases.randomElement()!.rawValue,
        sessionType: SessionType = .chat
    ) {
        self.id = id
        self.title = title
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.moodIcon = moodIcon
        self.sessionType = sessionType
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        messages = try container.decode([ChatMessage].self, forKey: .messages)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        // Fall back to a deterministic mood based on session ID for legacy sessions
        moodIcon = try container.decodeIfPresent(String.self, forKey: .moodIcon)
            ?? Self.deterministicMood(for: container.decode(UUID.self, forKey: .id))
        sessionType = try container.decodeIfPresent(SessionType.self, forKey: .sessionType) ?? .chat
    }

    /// Picks a stable mood from the session's UUID so legacy sessions always get the same icon.
    private static func deterministicMood(for id: UUID) -> String {
        let moods = MenuBarMood.Mood.allCases
        let index = Int(id.uuid.0) % moods.count
        return moods[index].rawValue
    }
}

// MARK: - API Format Conversion

extension ChatMessage {
    /// Convert from a Claude API message dictionary to a `ChatMessage`.
    static func fromAPIFormat(_ dict: [String: Any]) -> ChatMessage? {
        guard let roleStr = dict["role"] as? String,
              let role = MessageRole(rawValue: roleStr)
        else { return nil }

        var blocks: [MessageContent] = []

        if let contentStr = dict["content"] as? String {
            blocks.append(.text(contentStr))
        } else if let contentArray = dict["content"] as? [[String: Any]] {
            for block in contentArray {
                guard let type = block["type"] as? String else { continue }
                switch type {
                case "text":
                    if let text = block["text"] as? String {
                        blocks.append(.text(text))
                    }
                case "tool_use":
                    if let id = block["id"] as? String,
                       let name = block["name"] as? String
                    {
                        let input = block["input"] as? [String: Any] ?? [:]
                        let data = (try? JSONSerialization.data(withJSONObject: input)) ?? Data()
                        blocks.append(.toolUse(id: id, name: name, input: data))
                    }
                case "tool_result":
                    if let toolUseId = block["tool_use_id"] as? String {
                        let content: String = if let str = block["content"] as? String {
                            str
                        } else if let arr = block["content"] as? [[String: Any]],
                                  let first = arr.first,
                                  let text = first["text"] as? String
                        {
                            text
                        } else {
                            ""
                        }
                        blocks.append(.toolResult(toolUseId: toolUseId, content: content))
                    }
                default:
                    break
                }
            }
        }

        guard !blocks.isEmpty else { return nil }
        return ChatMessage(id: UUID(), role: role, content: blocks, timestamp: Date())
    }

    /// Convert this message back to Claude API format `[String: Any]`.
    func toAPIFormat() -> [String: Any] {
        // Simple user text message
        if role == .user, content.count == 1, case let .text(text) = content[0] {
            return ["role": "user", "content": text]
        }

        let contentArray: [[String: Any]] = content.map { block in
            switch block {
            case let .text(text):
                return ["type": "text", "text": text]
            case let .toolUse(id, name, inputData):
                let input = (try? JSONSerialization.jsonObject(with: inputData) as? [String: Any]) ?? [:]
                return ["type": "tool_use", "id": id, "name": name, "input": input]
            case let .toolResult(toolUseId, content):
                return ["type": "tool_result", "tool_use_id": toolUseId, "content": content]
            }
        }

        return ["role": role.rawValue, "content": contentArray]
    }
}

// MARK: - Title Generation

extension ChatSession {
    /// Generates a title from the first user message text.
    static func generateTitle(from firstMessage: String) -> String {
        let maxLen = 50
        let trimmed = firstMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxLen else { return trimmed }

        let prefix = String(trimmed.prefix(maxLen))
        // Truncate at last word boundary
        if let lastSpace = prefix.lastIndex(of: " ") {
            return String(prefix[..<lastSpace]) + "…"
        }
        return prefix + "…"
    }
}
