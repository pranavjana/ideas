import Foundation

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: Role
    var content: String
    let timestamp: Date
    var toolCallId: String?
    var toolName: String?
    var toolCalls: [ToolCall]?

    enum Role {
        case user
        case assistant
        case tool
    }

    struct ToolCall: Identifiable {
        let id: String
        let name: String
        let arguments: String

        var displayName: String {
            switch name {
            case "create_idea": return "create idea"
            case "search_ideas": return "search ideas"
            case "update_idea": return "update idea"
            case "delete_idea": return "delete idea"
            default: return name
            }
        }

        var icon: String {
            switch name {
            case "create_idea": return "plus.circle"
            case "search_ideas": return "magnifyingglass"
            case "update_idea": return "pencil.circle"
            case "delete_idea": return "trash.circle"
            default: return "wrench"
            }
        }

        /// Extract a short summary from the arguments JSON
        var summary: String? {
            guard let data = arguments.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }

            if let text = json["text"] as? String {
                return text.count > 60 ? String(text.prefix(60)) + "..." : text
            }
            if let query = json["query"] as? String {
                return "\"\(query)\""
            }
            if let search = json["search"] as? String {
                return "\"\(search)\""
            }
            return nil
        }
    }

    /// For tool result messages, parse the result to get a short status
    var toolResultStatus: (success: Bool, message: String)? {
        guard role == .tool else { return nil }
        guard let data = content.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        if let error = json["error"] as? String {
            return (false, error)
        }
        if let message = json["message"] as? String {
            return (true, message)
        }
        if let count = json["count"] as? Int {
            return (true, "\(count) result\(count == 1 ? "" : "s") found")
        }
        return (true, "done")
    }

    init(role: Role, content: String) {
        self.role = role
        self.content = content
        self.timestamp = Date()
    }

    init(toolResult: String, toolCallId: String, toolName: String) {
        self.role = .tool
        self.content = toolResult
        self.timestamp = Date()
        self.toolCallId = toolCallId
        self.toolName = toolName
    }
}
