import SwiftUI
import SwiftData

// MARK: - Persisted Chat Message

struct IdeaChatMessage: Codable, Identifiable {
    let id: UUID
    let role: String // "user", "assistant", "tool"
    var content: String
    let timestamp: Date
    var toolCallId: String?
    var toolName: String?
    var toolCalls: [IdeaToolCall]?

    struct IdeaToolCall: Codable, Identifiable {
        let id: String
        let name: String
        let arguments: String

        var displayName: String {
            switch name {
            case "write_notes": return "writing notes"
            case "append_notes": return "appending to notes"
            case "edit_title": return "editing title"
            case "add_subtasks": return "adding subtasks"
            case "toggle_subtask": return "toggling subtask"
            case "set_priority": return "setting priority"
            case "set_due_date": return "setting due date"
            case "add_update": return "adding update"
            default: return name
            }
        }
    }

    init(role: String, content: String) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.timestamp = Date()
    }

    init(toolResult: String, toolCallId: String, toolName: String) {
        self.id = UUID()
        self.role = "tool"
        self.content = toolResult
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.timestamp = Date()
    }
}

// MARK: - View Model

@MainActor
@Observable
class IdeaChatViewModel {
    var messages: [IdeaChatMessage] = []
    var isStreaming = false
    var toolActivity: String?
    var errorMessage: String?

    private let maxToolIterations = 8
    private var idea: Idea
    private var modelContext: ModelContext
    var onNotesChanged: (() -> Void)?
    var suggestedReplies: [String] = []

    init(idea: Idea, modelContext: ModelContext) {
        self.idea = idea
        self.modelContext = modelContext
        loadMessages()
    }

    // MARK: - Auto-Kickstart

    func kickstartIfNeeded(model: String) async {
        guard messages.isEmpty else { return }
        guard let apiKey = fetchAPIKey(), !apiKey.isEmpty else {
            errorMessage = "add your ai api key in settings"
            return
        }

        // Send a synthetic user message that the AI responds to proactively
        messages.append(IdeaChatMessage(role: "user", content: "[auto] I just opened this idea. Help me develop it."))
        isStreaming = true
        errorMessage = nil

        await runAgenticLoop(apiKey: apiKey, model: model)

        isStreaming = false
        toolActivity = nil
        saveMessages()
    }

    // MARK: - Persistence

    private func loadMessages() {
        guard !idea.chatData.isEmpty else { return }
        messages = (try? JSONDecoder().decode([IdeaChatMessage].self, from: idea.chatData)) ?? []
    }

    private func saveMessages() {
        idea.chatData = (try? JSONEncoder().encode(messages)) ?? Data()
    }

    func clearChat() {
        messages.removeAll()
        idea.chatData = Data()
        errorMessage = nil
        toolActivity = nil
        suggestedReplies = []
    }

    // MARK: - Send Message

    func sendMessage(_ text: String, model: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard let apiKey = fetchAPIKey(), !apiKey.isEmpty else {
            errorMessage = "add your ai api key in settings"
            return
        }

        messages.append(IdeaChatMessage(role: "user", content: trimmed))
        isStreaming = true
        errorMessage = nil
        suggestedReplies = []

        await runAgenticLoop(apiKey: apiKey, model: model)

        isStreaming = false
        toolActivity = nil
        saveMessages()
    }

    // MARK: - Agentic Loop

    private func runAgenticLoop(apiKey: String, model: String) async {
        for _ in 0..<maxToolIterations {
            let apiMessages = buildAPIMessages()
            let (text, toolCalls) = await streamResponse(apiKey: apiKey, model: model, messages: apiMessages)

            if let toolCalls, !toolCalls.isEmpty {
                var assistantMsg = IdeaChatMessage(role: "assistant", content: text ?? "")
                assistantMsg.toolCalls = toolCalls
                messages.append(assistantMsg)

                for tc in toolCalls {
                    toolActivity = tc.displayName
                    let result = executeIdeaTool(name: tc.name, arguments: tc.arguments)
                    messages.append(IdeaChatMessage(toolResult: result, toolCallId: tc.id, toolName: tc.name))
                }

                toolActivity = nil
                continue
            } else {
                // Parse suggested replies from the final assistant message
                parseSuggestedReplies()
                break
            }
        }
    }

    // MARK: - Suggested Replies

    private func parseSuggestedReplies() {
        guard let lastMsg = messages.last, lastMsg.role == "assistant" else {
            suggestedReplies = []
            return
        }

        // Look for lines starting with ">" at the end of the message as suggestions
        let lines = lastMsg.content.components(separatedBy: "\n")
        var suggestions: [String] = []
        var foundSuggestions = false

        for line in lines.reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("> ") {
                suggestions.insert(String(trimmed.dropFirst(2)), at: 0)
                foundSuggestions = true
            } else if foundSuggestions {
                break
            } else if trimmed.isEmpty {
                continue
            } else {
                break
            }
        }

        if !suggestions.isEmpty {
            // Remove the suggestion lines from the message content
            let contentLines = lines.filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !suggestions.contains(where: { "> \($0)" == trimmed })
            }
            let lastIndex = messages.count - 1
            messages[lastIndex].content = contentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        suggestedReplies = suggestions
    }

    // MARK: - Stream Response

    private func streamResponse(
        apiKey: String,
        model: String,
        messages apiMessages: [OpenAIService.Message]
    ) async -> (String?, [IdeaChatMessage.IdeaToolCall]?) {
        messages.append(IdeaChatMessage(role: "assistant", content: ""))
        let assistantIndex = messages.count - 1

        var toolCallAccumulators: [Int: (id: String, name: String, arguments: String)] = [:]

        do {
            let stream = OpenAIService.streamCompletionWithTools(
                apiKey: apiKey,
                model: model,
                messages: apiMessages,
                tools: Self.toolDefinitions
            )

            for try await event in stream {
                switch event {
                case .textDelta(let delta):
                    messages[assistantIndex].content += delta
                case .toolCallDelta(let index, let id, let name, let argsDelta):
                    if toolCallAccumulators[index] == nil {
                        toolCallAccumulators[index] = (id: id ?? "", name: name ?? "", arguments: "")
                    }
                    if let id, !id.isEmpty { toolCallAccumulators[index]?.id = id }
                    if let name, !name.isEmpty { toolCallAccumulators[index]?.name = name }
                    toolCallAccumulators[index]?.arguments += argsDelta
                case .done:
                    break
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            if messages[assistantIndex].content.isEmpty {
                messages.remove(at: assistantIndex)
            }
            return (nil, nil)
        }

        if !toolCallAccumulators.isEmpty {
            let toolCalls = toolCallAccumulators.sorted(by: { $0.key < $1.key }).map { (_, v) in
                IdeaChatMessage.IdeaToolCall(id: v.id, name: v.name, arguments: v.arguments)
            }
            let text = messages[assistantIndex].content
            messages.remove(at: assistantIndex)
            return (text.isEmpty ? nil : text, toolCalls)
        }

        return (messages[assistantIndex].content, nil)
    }

    // MARK: - Build API Messages

    private func buildAPIMessages() -> [OpenAIService.Message] {
        var apiMessages: [OpenAIService.Message] = []
        apiMessages.append(OpenAIService.Message(role: "system", content: buildSystemPrompt()))

        for msg in messages {
            switch msg.role {
            case "user":
                apiMessages.append(OpenAIService.Message(role: "user", content: msg.content))
            case "assistant":
                if let toolCalls = msg.toolCalls, !toolCalls.isEmpty {
                    var m = OpenAIService.Message(role: "assistant", content: msg.content.isEmpty ? "" : msg.content)
                    m.toolCalls = toolCalls.map { tc in
                        [
                            "id": tc.id,
                            "type": "function",
                            "function": [
                                "name": tc.name,
                                "arguments": tc.arguments
                            ]
                        ] as [String: Any]
                    }
                    apiMessages.append(m)
                } else if !msg.content.isEmpty {
                    apiMessages.append(OpenAIService.Message(role: "assistant", content: msg.content))
                }
            case "tool":
                if let toolCallId = msg.toolCallId {
                    apiMessages.append(OpenAIService.Message(toolResult: msg.content, toolCallId: toolCallId))
                }
            default:
                break
            }
        }

        return apiMessages
    }

    // MARK: - System Prompt

    private func buildSystemPrompt() -> String {
        var parts: [String] = []

        parts.append("IDEA TITLE: \(idea.text)")
        parts.append("TAGS: \(idea.tags.isEmpty ? "none" : idea.tags.joined(separator: ", "))")
        parts.append("CATEGORY: \(idea.category.isEmpty ? "none" : idea.category)")
        parts.append("STATUS: \(idea.isDone ? "done" : "in progress")")
        parts.append("PRIORITY: \(idea.priorityLevel.label)")

        if let due = idea.formattedDueDate {
            parts.append("DUE: \(due)")
        }
        if let r = idea.recurringPattern {
            parts.append("RECURRING: \(r)")
        }

        let notesText = String(idea.attributedNotes.characters)
        if !notesText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("CURRENT NOTES:\n\(notesText)")
        } else {
            parts.append("CURRENT NOTES: (empty)")
        }

        if !idea.subtasks.isEmpty {
            let subtaskList = idea.parsedSubtasks.map { ($0.isDone ? "[x]" : "[ ]") + " " + $0.text }.joined(separator: "\n")
            parts.append("SUBTASKS:\n\(subtaskList)")
        }

        if !idea.updates.isEmpty {
            let updateList = idea.parsedUpdates.map {
                "\($0.date.formatted(.dateTime.month(.abbreviated).day())): \($0.text)"
            }.joined(separator: "\n")
            parts.append("UPDATES:\n\(updateList)")
        }

        if let folder = idea.folder {
            parts.append("FOLDER: \(folder.breadcrumb)")
        }

        let connections = idea.allLinks.map { $0.text }
        if !connections.isEmpty {
            parts.append("CONNECTED IDEAS: \(connections.joined(separator: ", "))")
        }

        let descriptor = FetchDescriptor<UserProfile>()
        if let profile = (try? modelContext.fetch(descriptor))?.first, !profile.bio.isEmpty {
            parts.append("USER BIO: \(profile.bio)")
        }

        let now = Date()
        let fmt = DateFormatter()
        fmt.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm a"
        parts.append("NOW: \(fmt.string(from: now))")

        parts.append("""
        You are a proactive AI note-writing partner for this idea. You work like an agent — you don't just answer questions, you actively help build out this idea by writing notes, asking clarifying questions, and driving the conversation forward.

        YOUR APPROACH:
        - Be a co-writer. When the user shares a thought, don't just acknowledge it — write something into the notes, then ask a follow-up question to go deeper.
        - Always be doing two things: (1) capturing and structuring what you learn into the notes using your tools, and (2) asking the next question to develop the idea further.
        - Write notes progressively. Start with what you know, then refine and expand as the conversation continues. Use append_notes to build up incrementally rather than rewriting everything.
        - Ask ONE focused question at a time. Don't overwhelm with multiple questions. Each question should help you write better notes.
        - Be opinionated and suggest structure. If the idea is vague, propose a framework or outline and write it into the notes, then ask if it resonates.
        - Keep your chat messages SHORT (1-3 sentences max). The real work goes into the notes. Your chat messages are just quick updates on what you wrote and your next question.
        - If this is the start of a conversation, introduce yourself briefly, look at what exists, and ask the FIRST question that would help you start writing useful notes.
        - NEVER put questions or "need to clarify" placeholders in the notes. Notes should be CLEAN, finalized content. If you have questions, ask them in the chat and use the answers to write better notes.
        - Write notes in markdown format — use **bold**, *italic*, `code`, headings (## / ###), bullet lists (- item), etc. The notes editor renders markdown formatting.

        TOOLS: You have 3 CRUD tools — create, update, delete — each with a "type" parameter. Use create(type="note") to write notes, create(type="subtask") to add subtasks, create(type="update") for progress logs. Use update(type="title/note/priority/due_date/folder/subtask/status") to modify things. Use delete(type="subtask/note") to remove things. USE THEM PROACTIVELY — don't ask permission, just do it and show the user what you did.

        IMPORTANT — SUGGESTED REPLIES: At the end of EVERY message, include 2-3 short suggested replies the user might want to say next. Format them as lines starting with "> ". These should be natural continuations of the conversation — answers to your question, directions to explore, or requests. Make them specific and useful, not generic. Examples:
        > Yes, it's mainly for mobile users
        > Actually let me explain the backstory first
        > Skip that, focus on the technical approach
        """)

        return parts.joined(separator: "\n\n")
    }

    // MARK: - Helpers

    private func fetchAPIKey() -> String? {
        let apiKey = AIProviderKeychain.apiKey()
        return apiKey.isEmpty ? nil : apiKey
    }

    // MARK: - Tool Definitions (3 CRUD tools scoped to this idea)

    static let toolDefinitions: [[String: Any]] = [
        [
            "type": "function",
            "function": [
                "name": "create",
                "description": """
                Create something on this idea. Use type to specify:
                - "note": Write/replace the idea's notes (overwrites). Params: content (markdown)
                - "subtask": Add subtasks. Params: subtasks (array of texts)
                - "update": Add a timestamped progress note. Params: text
                """,
                "parameters": [
                    "type": "object",
                    "properties": [
                        "type": ["type": "string", "enum": ["note", "subtask", "update"], "description": "What to create"],
                        "content": ["type": "string", "description": "Markdown content (note)"],
                        "subtasks": ["type": "array", "items": ["type": "string"], "description": "Subtask texts (subtask)"],
                        "text": ["type": "string", "description": "Update text (update)"]
                    ] as [String: Any],
                    "required": ["type"]
                ] as [String: Any]
            ] as [String: Any]
        ],
        [
            "type": "function",
            "function": [
                "name": "update",
                "description": """
                Update this idea's properties. Use type to specify:
                - "title": Change the title. Params: title
                - "note": Append to existing notes. Params: content
                - "priority": Set priority. Params: priority (urgent/high/medium/low/none)
                - "due_date": Set due date. Params: date (YYYY-MM-DD or 'none'), time (HH:mm or 'none'), recurring (daily/weekly/monthly/weekdays/yearly/none)
                - "folder": Move to folder. Params: folder (name or 'none')
                - "subtask": Toggle a subtask done/todo. Params: subtask (text match)
                - "status": Mark done/undone. Params: done (true/false)
                """,
                "parameters": [
                    "type": "object",
                    "properties": [
                        "type": ["type": "string", "enum": ["title", "note", "priority", "due_date", "folder", "subtask", "status"], "description": "What to update"],
                        "title": ["type": "string", "description": "New title (title)"],
                        "content": ["type": "string", "description": "Text to append (note)"],
                        "priority": ["type": "string", "enum": ["urgent", "high", "medium", "low", "none"], "description": "Priority level (priority)"],
                        "date": ["type": "string", "description": "Due date YYYY-MM-DD or 'none' (due_date)"],
                        "time": ["type": "string", "description": "Due time HH:mm or 'none' (due_date)"],
                        "recurring": ["type": "string", "enum": ["daily", "weekly", "monthly", "weekdays", "yearly", "none"], "description": "Recurring pattern (due_date)"],
                        "folder": ["type": "string", "description": "Folder name or full path like 'School / Projects', or 'none' (folder)"],
                        "subtask": ["type": "string", "description": "Subtask text to toggle (subtask)"],
                        "done": ["type": "boolean", "description": "Mark done/undone (status)"]
                    ] as [String: Any],
                    "required": ["type"]
                ] as [String: Any]
            ] as [String: Any]
        ],
        [
            "type": "function",
            "function": [
                "name": "read",
                "description": """
                Read data. Use type to specify:
                - "ideas": Search all ideas by keyword. Params: query, folder (optional filter)
                - "folders": List all folders and hierarchy.
                """,
                "parameters": [
                    "type": "object",
                    "properties": [
                        "type": ["type": "string", "enum": ["ideas", "folders"], "description": "What to read"],
                        "query": ["type": "string", "description": "Search keyword (ideas)"],
                        "folder": ["type": "string", "description": "Folder to search within (ideas)"]
                    ] as [String: Any],
                    "required": ["type"]
                ] as [String: Any]
            ] as [String: Any]
        ],
        [
            "type": "function",
            "function": [
                "name": "delete",
                "description": """
                Delete something from this idea. Use type to specify:
                - "subtask": Remove a subtask. Params: subtask (text match)
                - "note": Clear all notes.
                """,
                "parameters": [
                    "type": "object",
                    "properties": [
                        "type": ["type": "string", "enum": ["subtask", "note"], "description": "What to delete"],
                        "subtask": ["type": "string", "description": "Subtask text to remove (subtask)"]
                    ] as [String: Any],
                    "required": ["type"]
                ] as [String: Any]
            ] as [String: Any]
        ]
    ]

    // MARK: - Tool Execution

    private func executeIdeaTool(name: String, arguments: String) -> String {
        guard let data = arguments.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return "{\"error\": \"invalid arguments\"}" }

        guard let type = args["type"] as? String else {
            return executeLegacyIdeaTool(name: name, args: args)
        }

        switch name {
        case "create":
            return executeIdeaCreate(type: type, args: args)
        case "read":
            return executeIdeaRead(type: type, args: args)
        case "update":
            return executeIdeaUpdate(type: type, args: args)
        case "delete":
            return executeIdeaDelete(type: type, args: args)
        default:
            return executeLegacyIdeaTool(name: name, args: args)
        }
    }

    // MARK: - Create (idea-scoped)

    private func executeIdeaCreate(type: String, args: [String: Any]) -> String {
        switch type {
        case "note":
            guard let content = args["content"] as? String else { return "{\"error\": \"missing content\"}" }
            idea.attributedNotes = AttributedString(content)
            try? modelContext.save()
            onNotesChanged?()
            return "{\"success\": true, \"message\": \"Notes written (\(content.count) chars)\"}"
        case "subtask":
            guard let subtasks = args["subtasks"] as? [String] else { return "{\"error\": \"missing subtasks\"}" }
            for s in subtasks { idea.addSubtask(s) }
            try? modelContext.save()
            return "{\"success\": true, \"message\": \"Added \(subtasks.count) subtask(s)\"}"
        case "update":
            guard let text = args["text"] as? String else { return "{\"error\": \"missing text\"}" }
            idea.addUpdate(text)
            try? modelContext.save()
            return "{\"success\": true, \"message\": \"Update added\"}"
        default:
            return "{\"error\": \"unknown create type: \(type). Use: note, subtask, update\"}"
        }
    }

    // MARK: - Read (idea-scoped, delegates to IdeaTools)

    private func executeIdeaRead(type: String, args: [String: Any]) -> String {
        switch type {
        case "ideas":
            return IdeaTools.readIdeas(args: args, modelContext: modelContext)
        case "folders":
            return IdeaTools.readFolders(modelContext: modelContext)
        default:
            return "{\"error\": \"unknown read type: \(type). Use: ideas, folders\"}"
        }
    }

    // MARK: - Update (idea-scoped)

    private func executeIdeaUpdate(type: String, args: [String: Any]) -> String {
        switch type {
        case "title":
            guard let title = args["title"] as? String else { return "{\"error\": \"missing title\"}" }
            idea.text = title
            try? modelContext.save()
            return "{\"success\": true, \"message\": \"Title updated to: \(title)\"}"

        case "note":
            guard let content = args["content"] as? String else { return "{\"error\": \"missing content\"}" }
            var current = idea.attributedNotes
            current.append(AttributedString("\n\n" + content))
            idea.attributedNotes = current
            try? modelContext.save()
            onNotesChanged?()
            return "{\"success\": true, \"message\": \"Appended to notes\"}"

        case "priority":
            guard let p = args["priority"] as? String, let priority = Idea.Priority(fromString: p) else {
                return "{\"error\": \"invalid priority\"}"
            }
            idea.priorityLevel = priority
            try? modelContext.save()
            return "{\"success\": true, \"message\": \"Priority set to \(priority.label)\"}"

        case "due_date":
            guard let dateStr = args["date"] as? String else { return "{\"error\": \"missing date\"}" }
            idea.dueDate = dateStr.lowercased() == "none" ? nil : IdeaTools.parseDateString(dateStr)
            if let t = args["time"] as? String { idea.dueTime = t.lowercased() == "none" ? nil : t }
            if let r = args["recurring"] as? String { idea.recurringPattern = r.lowercased() == "none" ? nil : r }
            try? modelContext.save()
            return "{\"success\": true, \"message\": \"Due date updated\"}"

        case "folder":
            guard let folderStr = args["folder"] as? String else { return "{\"error\": \"missing folder\"}" }
            if folderStr.lowercased() == "none" {
                idea.folder = nil
                try? modelContext.save()
                return "{\"success\": true, \"message\": \"Removed from folder\"}"
            }
            guard let folder = IdeaTools.findFolder(matching: folderStr, in: modelContext) else {
                let available = (try? modelContext.fetch(FetchDescriptor<Folder>()))?.map { $0.breadcrumb } ?? []
                return IdeaTools.jsonResult(["error": "folder '\(folderStr)' not found", "availableFolders": available])
            }
            idea.folder = folder
            try? modelContext.save()
            return "{\"success\": true, \"message\": \"Moved to folder: \(folder.breadcrumb)\"}"

        case "subtask":
            guard let query = args["subtask"] as? String else { return "{\"error\": \"missing subtask\"}" }
            let lc2 = query.lowercased()
            guard let idx = idea.subtasks.firstIndex(where: { $0.lowercased().contains(lc2) }) else {
                return "{\"error\": \"subtask not found matching '\(query)'\"}"
            }
            idea.toggleSubtask(at: idx)
            try? modelContext.save()
            let parsed = idea.parsedSubtasks[idx]
            return "{\"success\": true, \"message\": \"Toggled '\(parsed.text)' to \(parsed.isDone ? "done" : "todo")\"}"

        case "status":
            guard let done = args["done"] as? Bool else { return "{\"error\": \"missing done\"}" }
            idea.isDone = done
            try? modelContext.save()
            return "{\"success\": true, \"message\": \"Marked \(done ? "done" : "active")\"}"

        default:
            return "{\"error\": \"unknown update type: \(type). Use: title, note, priority, due_date, folder, subtask, status\"}"
        }
    }

    // MARK: - Delete (idea-scoped)

    private func executeIdeaDelete(type: String, args: [String: Any]) -> String {
        switch type {
        case "subtask":
            guard let query = args["subtask"] as? String else { return "{\"error\": \"missing subtask\"}" }
            let lc = query.lowercased()
            guard let idx = idea.subtasks.firstIndex(where: { $0.lowercased().contains(lc) }) else {
                return "{\"error\": \"subtask not found matching '\(query)'\"}"
            }
            let text = idea.parsedSubtasks[idx].text
            idea.removeSubtask(at: idx)
            try? modelContext.save()
            return "{\"success\": true, \"message\": \"Removed subtask '\(text)'\"}"
        case "note":
            idea.attributedNotes = AttributedString("")
            try? modelContext.save()
            onNotesChanged?()
            return "{\"success\": true, \"message\": \"Notes cleared\"}"
        default:
            return "{\"error\": \"unknown delete type: \(type). Use: subtask, note\"}"
        }
    }

    // MARK: - Legacy Tool Compat

    private func executeLegacyIdeaTool(name: String, args: [String: Any]) -> String {
        switch name {
        case "write_notes":
            return executeIdeaCreate(type: "note", args: args)
        case "append_notes":
            return executeIdeaUpdate(type: "note", args: args)
        case "edit_title":
            var remapped = args
            remapped["title"] = args["title"]
            return executeIdeaUpdate(type: "title", args: remapped)
        case "add_subtasks":
            return executeIdeaCreate(type: "subtask", args: args)
        case "toggle_subtask":
            return executeIdeaUpdate(type: "subtask", args: args)
        case "set_priority":
            return executeIdeaUpdate(type: "priority", args: args)
        case "set_due_date":
            return executeIdeaUpdate(type: "due_date", args: args)
        case "add_update":
            var remapped = args
            if let u = args["update"] as? String { remapped["text"] = u }
            return executeIdeaCreate(type: "update", args: remapped)
        case "set_folder":
            return executeIdeaUpdate(type: "folder", args: args)
        default:
            return "{\"error\": \"unknown tool: \(name)\"}"
        }
    }
}
