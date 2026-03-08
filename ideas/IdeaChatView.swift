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
            errorMessage = "add your openrouter api key in settings"
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
            errorMessage = "add your openrouter api key in settings"
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

        TOOLS: You can directly edit notes (write_notes, append_notes), title (edit_title), subtasks (add_subtasks), priority (set_priority), due date (set_due_date), and log updates (add_update). USE THEM PROACTIVELY — don't ask permission to write, just write and show the user what you did.

        IMPORTANT — SUGGESTED REPLIES: At the end of EVERY message, include 2-3 short suggested replies the user might want to say next. Format them as lines starting with "> ". These should be natural continuations of the conversation — answers to your question, directions to explore, or requests. Make them specific and useful, not generic. Examples:
        > Yes, it's mainly for mobile users
        > Actually let me explain the backstory first
        > Skip that, focus on the technical approach
        """)

        return parts.joined(separator: "\n\n")
    }

    // MARK: - Helpers

    private func fetchAPIKey() -> String? {
        let descriptor = FetchDescriptor<UserProfile>()
        return (try? modelContext.fetch(descriptor))?.first?.openaiAPIKey
    }

    // MARK: - Tool Definitions

    static let toolDefinitions: [[String: Any]] = [
        [
            "type": "function",
            "function": [
                "name": "write_notes",
                "description": "Replace the idea's notes with new content. Use markdown formatting. This overwrites existing notes entirely.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "content": ["type": "string", "description": "The new notes content (plain text, supports markdown)"]
                    ],
                    "required": ["content"]
                ] as [String: Any]
            ] as [String: Any]
        ],
        [
            "type": "function",
            "function": [
                "name": "append_notes",
                "description": "Append text to the end of the existing notes. Adds a newline separator before the new content.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "content": ["type": "string", "description": "Text to append to notes"]
                    ],
                    "required": ["content"]
                ] as [String: Any]
            ] as [String: Any]
        ],
        [
            "type": "function",
            "function": [
                "name": "edit_title",
                "description": "Update the idea's title.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string", "description": "New title for the idea"]
                    ],
                    "required": ["title"]
                ] as [String: Any]
            ] as [String: Any]
        ],
        [
            "type": "function",
            "function": [
                "name": "add_subtasks",
                "description": "Add one or more subtasks to the idea.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "subtasks": ["type": "array", "items": ["type": "string"], "description": "Subtask texts to add"]
                    ],
                    "required": ["subtasks"]
                ] as [String: Any]
            ] as [String: Any]
        ],
        [
            "type": "function",
            "function": [
                "name": "toggle_subtask",
                "description": "Toggle a subtask's done/todo status by partial text match.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "subtask": ["type": "string", "description": "Partial text of the subtask to toggle"]
                    ],
                    "required": ["subtask"]
                ] as [String: Any]
            ] as [String: Any]
        ],
        [
            "type": "function",
            "function": [
                "name": "set_priority",
                "description": "Set the idea's priority level.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "priority": ["type": "string", "enum": ["urgent", "high", "medium", "low", "none"], "description": "Priority level"]
                    ],
                    "required": ["priority"]
                ] as [String: Any]
            ] as [String: Any]
        ],
        [
            "type": "function",
            "function": [
                "name": "set_due_date",
                "description": "Set or clear the idea's due date and optionally time and recurring pattern.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "date": ["type": "string", "description": "Due date YYYY-MM-DD, or 'none' to clear"],
                        "time": ["type": "string", "description": "Due time HH:mm, or 'none' to clear"],
                        "recurring": ["type": "string", "enum": ["daily", "weekly", "monthly", "weekdays", "yearly", "none"], "description": "Recurring pattern"]
                    ] as [String: Any],
                    "required": ["date"]
                ] as [String: Any]
            ] as [String: Any]
        ],
        [
            "type": "function",
            "function": [
                "name": "add_update",
                "description": "Add a timestamped progress update to the idea's update log.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "update": ["type": "string", "description": "Update text"]
                    ],
                    "required": ["update"]
                ] as [String: Any]
            ] as [String: Any]
        ]
    ]

    // MARK: - Markdown Parser

    // MARK: - Markdown Parser (stores plain text, rendering done by MarkdownNotesView)

    // MARK: - Tool Execution

    private func executeIdeaTool(name: String, arguments: String) -> String {
        guard let data = arguments.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return "{\"error\": \"invalid arguments\"}" }

        switch name {
        case "write_notes":
            guard let content = args["content"] as? String else {
                return "{\"error\": \"missing content\"}"
            }
            idea.attributedNotes = AttributedString(content)
            onNotesChanged?()
            return "{\"success\": true, \"message\": \"Notes updated (\(content.count) chars)\"}"

        case "append_notes":
            guard let content = args["content"] as? String else {
                return "{\"error\": \"missing content\"}"
            }
            var current = idea.attributedNotes
            current.append(AttributedString("\n\n" + content))
            idea.attributedNotes = current
            onNotesChanged?()
            return "{\"success\": true, \"message\": \"Appended to notes\"}"

        case "edit_title":
            guard let title = args["title"] as? String else {
                return "{\"error\": \"missing title\"}"
            }
            idea.text = title
            return "{\"success\": true, \"message\": \"Title updated to: \(title)\"}"

        case "add_subtasks":
            guard let subtasks = args["subtasks"] as? [String] else {
                return "{\"error\": \"missing subtasks\"}"
            }
            for s in subtasks { idea.addSubtask(s) }
            return "{\"success\": true, \"message\": \"Added \(subtasks.count) subtask(s)\"}"

        case "toggle_subtask":
            guard let query = args["subtask"] as? String else {
                return "{\"error\": \"missing subtask\"}"
            }
            let lc = query.lowercased()
            guard let idx = idea.subtasks.firstIndex(where: { $0.lowercased().contains(lc) }) else {
                return "{\"error\": \"subtask not found matching '\(query)'\"}"
            }
            idea.toggleSubtask(at: idx)
            let parsed = idea.parsedSubtasks[idx]
            return "{\"success\": true, \"message\": \"Toggled '\(parsed.text)' to \(parsed.isDone ? "done" : "todo")\"}"

        case "set_priority":
            guard let p = args["priority"] as? String,
                  let priority = Idea.Priority(fromString: p) else {
                return "{\"error\": \"invalid priority\"}"
            }
            idea.priorityLevel = priority
            return "{\"success\": true, \"message\": \"Priority set to \(priority.label)\"}"

        case "set_due_date":
            guard let dateStr = args["date"] as? String else {
                return "{\"error\": \"missing date\"}"
            }
            if dateStr.lowercased() == "none" {
                idea.dueDate = nil
            } else {
                let fmt = DateFormatter()
                fmt.dateFormat = "yyyy-MM-dd"
                fmt.locale = Locale(identifier: "en_US_POSIX")
                idea.dueDate = fmt.date(from: dateStr).map { Calendar.current.startOfDay(for: $0) }
            }
            if let timeStr = args["time"] as? String {
                idea.dueTime = timeStr.lowercased() == "none" ? nil : timeStr
            }
            if let recurStr = args["recurring"] as? String {
                idea.recurringPattern = recurStr.lowercased() == "none" ? nil : recurStr
            }
            return "{\"success\": true, \"message\": \"Due date updated\"}"

        case "add_update":
            guard let update = args["update"] as? String else {
                return "{\"error\": \"missing update\"}"
            }
            idea.addUpdate(update)
            return "{\"success\": true, \"message\": \"Update added\"}"

        default:
            return "{\"error\": \"unknown tool: \(name)\"}"
        }
    }
}

// MARK: - Chat View

struct IdeaChatView: View {
    @Bindable var idea: Idea
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel: IdeaChatViewModel?
    @State private var inputText = ""
    @State private var selectedModel: AIModel = AIModel.available[0]
    @FocusState private var isInputFocused: Bool
    var onNotesChanged: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    if let vm = viewModel {
                        if vm.messages.isEmpty {
                            emptyState
                        } else {
                            LazyVStack(alignment: .leading, spacing: 12) {
                                ForEach(vm.messages.filter { $0.role != "tool" && !$0.content.hasPrefix("[auto]") }) { message in
                                    ideaChatBubble(message)
                                        .id(message.id)
                                }

                                // Suggested reply chips
                                if !vm.suggestedReplies.isEmpty && !vm.isStreaming {
                                    suggestedRepliesView(vm: vm)
                                        .id("suggestions")
                                }
                            }
                            .padding(.top, 12)
                            .padding(.bottom, 16)
                        }
                    }
                }
                .scrollDismissesKeyboard(.interactively)
                .defaultScrollAnchor(.bottom)
                .onChange(of: viewModel?.messages.count) {
                    if let last = viewModel?.messages.filter({ $0.role != "tool" }).last {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            if let activity = viewModel?.toolActivity {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 12, height: 12)
                    Text(activity)
                        .font(.custom("Switzer-Light", size: 11))
                        .foregroundStyle(Color.white.opacity(0.3))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 4)
            }

            if let error = viewModel?.errorMessage {
                Text(error)
                    .font(.custom("Switzer-Regular", size: 11))
                    .foregroundStyle(Color.red.opacity(0.7))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 4)
            }

            chatInput
        }
        .frame(minHeight: 300)
        .onAppear {
            if viewModel == nil {
                let vm = IdeaChatViewModel(idea: idea, modelContext: modelContext)
                vm.onNotesChanged = onNotesChanged
                viewModel = vm
            }
            isInputFocused = true
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            ProgressView()
                .scaleEffect(0.6)
            Text("thinking about this idea...")
                .font(.custom("Switzer-Light", size: 12))
                .foregroundStyle(Color.white.opacity(0.15))
            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 200)
        .onAppear {
            Task {
                await viewModel?.kickstartIfNeeded(model: selectedModel.id)
            }
        }
    }

    // MARK: - Suggested Replies

    private func suggestedRepliesView(vm: IdeaChatViewModel) -> some View {
        FlowLayout(spacing: 6) {
            ForEach(vm.suggestedReplies, id: \.self) { reply in
                Button {
                    inputText = ""
                    Task {
                        vm.suggestedReplies = []
                        await vm.sendMessage(reply, model: selectedModel.id)
                    }
                } label: {
                    Text(reply)
                        .font(.custom("Switzer-Regular", size: 12))
                        .foregroundStyle(Color.white.opacity(0.6))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color.white.opacity(0.04))
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Chat Input

    private var chatInput: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(AIModel.available) { model in
                    Button {
                        selectedModel = model
                    } label: {
                        HStack {
                            Text(model.name)
                            if model.id == selectedModel.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }

                Divider()

                if viewModel?.messages.isEmpty == false {
                    Button(role: .destructive) {
                        viewModel?.clearChat()
                    } label: {
                        Label("Clear chat", systemImage: "trash")
                    }
                }
            } label: {
                Image(systemName: "sparkle")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.25))
                    .frame(width: 28, height: 28)
                    .background(Color.white.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)

            TextField("think together...", text: $inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.custom("Switzer-Regular", size: 14))
                .foregroundStyle(Color.white.opacity(0.85))
                .lineLimit(1...5)
                .focused($isInputFocused)
                .onSubmit { send() }
                .disabled(viewModel?.isStreaming ?? false)

            if viewModel?.isStreaming ?? false {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 16, height: 16)
            } else if !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button { send() } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.03))
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    // MARK: - Message Bubble

    @ViewBuilder
    private func ideaChatBubble(_ message: IdeaChatMessage) -> some View {
        if message.role == "user" {
            HStack {
                Spacer()
                Text(message.content)
                    .font(.custom("Switzer-Regular", size: 14))
                    .foregroundStyle(Color.white.opacity(0.9))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color.white.opacity(0.08))
                    )
                    .textSelection(.enabled)
            }
        } else if message.role == "assistant" {
            if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    if !message.content.isEmpty {
                        Text(LocalizedStringKey(message.content))
                            .font(.custom("Switzer-Regular", size: 14))
                            .foregroundStyle(Color.white.opacity(0.75))
                            .lineSpacing(5)
                            .textSelection(.enabled)
                            .padding(.bottom, 4)
                    }
                    ForEach(toolCalls) { tc in
                        HStack(spacing: 5) {
                            Image(systemName: "gearshape")
                                .font(.system(size: 9))
                                .foregroundStyle(Color.white.opacity(0.2))
                            Text(tc.displayName)
                                .font(.custom("Switzer-Light", size: 11))
                                .foregroundStyle(Color.white.opacity(0.25))
                        }
                    }
                }
            } else if !message.content.isEmpty {
                Text(LocalizedStringKey(message.content))
                    .font(.custom("Switzer-Regular", size: 14))
                    .foregroundStyle(Color.white.opacity(0.75))
                    .lineSpacing(5)
                    .textSelection(.enabled)
            }
        }
    }

    private func send() {
        let text = inputText
        inputText = ""
        Task {
            await viewModel?.sendMessage(text, model: selectedModel.id)
        }
    }
}
