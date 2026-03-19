import Foundation
import SwiftUI
import SwiftData

@MainActor
@Observable
class FocusViewModel {
    var messages: [ChatMessage] = []
    var isStreaming = false
    var errorMessage: String?
    var toolActivity: String?

    // Focus state — always visible, no phase transitions
    var focusItems: [FocusItem] = []
    var userName: String = ""

    // Latest AI response (shown as card above input, auto-dismissed)
    var latestResponse: String = ""

    private var modelContext: ModelContext
    private var ideasViewModel: IdeasViewModel?
    private let maxToolIterations = 10

    struct FocusItem: Identifiable {
        let id = UUID()
        let idea: Idea
        var subtasks: [(text: String, isDone: Bool)]
        var isCompleted: Bool

        init(idea: Idea) {
            self.idea = idea
            self.subtasks = idea.parsedSubtasks.map { (text: $0.text, isDone: $0.isDone) }
            self.isCompleted = idea.isDone
        }
    }

    private static let focusDateKey = "focus_date"
    private static let focusIdeaTextsKey = "focus_idea_ids"

    private static let promptDateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm a"
        return fmt
    }()

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        loadUserName()
        restoreFocus()
    }

    func setIdeasViewModel(_ vm: IdeasViewModel?) {
        self.ideasViewModel = vm
    }

    private func loadUserName() {
        let descriptor = FetchDescriptor<UserProfile>()
        if let profile = (try? modelContext.fetch(descriptor))?.first, !profile.bio.isEmpty {
            let bio = profile.bio.trimmingCharacters(in: .whitespacesAndNewlines)
            if let range = bio.range(of: #"(?:I'm|I am|my name is|name is|i'm)\s+(\w+)"#, options: [.regularExpression, .caseInsensitive]) {
                let match = bio[range]
                let words = match.split(separator: " ")
                if let last = words.last {
                    userName = String(last).lowercased()
                    return
                }
            }
            let firstWord = bio.split(separator: " ").first.map(String.init) ?? ""
            if firstWord.count <= 15 && !firstWord.isEmpty {
                userName = firstWord.lowercased()
            }
        }
    }

    // MARK: - Focus Item Management

    func addFocusItem(_ idea: Idea) {
        guard !focusItems.contains(where: { $0.idea.persistentModelID == idea.persistentModelID }) else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            focusItems.append(FocusItem(idea: idea))
        }
        saveFocus()
    }

    func addFocusItems(_ ideas: [Idea]) {
        for idea in ideas {
            if !focusItems.contains(where: { $0.idea.persistentModelID == idea.persistentModelID }) {
                focusItems.append(FocusItem(idea: idea))
            }
        }
        saveFocus()
    }

    func removeFocusItem(_ item: FocusItem) {
        withAnimation(.easeOut(duration: 0.2)) {
            focusItems.removeAll { $0.id == item.id }
        }
        saveFocus()
    }

    func resetFocus() {
        withAnimation(.easeInOut(duration: 0.3)) {
            focusItems = []
            messages = []
            latestResponse = ""
        }
        UserDefaults.standard.removeObject(forKey: Self.focusDateKey)
        UserDefaults.standard.removeObject(forKey: Self.focusIdeaTextsKey)
    }

    func toggleItem(_ item: FocusItem) {
        guard let idx = focusItems.firstIndex(where: { $0.id == item.id }) else { return }
        focusItems[idx].isCompleted.toggle()
        focusItems[idx].idea.isDone = focusItems[idx].isCompleted
        try? modelContext.save()
    }

    func toggleSubtask(item: FocusItem, subtaskIndex: Int) {
        guard let idx = focusItems.firstIndex(where: { $0.id == item.id }) else { return }
        focusItems[idx].subtasks[subtaskIndex].isDone.toggle()
        focusItems[idx].idea.toggleSubtask(at: subtaskIndex)
        try? modelContext.save()
    }

    var completedCount: Int {
        focusItems.filter { $0.isCompleted }.count
    }

    var totalCount: Int {
        focusItems.count
    }

    // MARK: - Persistence (per-day)

    private func saveFocus() {
        let today = Calendar.current.startOfDay(for: Date())
        UserDefaults.standard.set(today, forKey: Self.focusDateKey)
        let texts = focusItems.map { $0.idea.text }
        UserDefaults.standard.set(texts, forKey: Self.focusIdeaTextsKey)
    }

    private func restoreFocus() {
        guard let savedDate = UserDefaults.standard.object(forKey: Self.focusDateKey) as? Date,
              Calendar.current.isDate(savedDate, inSameDayAs: Date()) else {
            UserDefaults.standard.removeObject(forKey: Self.focusDateKey)
            UserDefaults.standard.removeObject(forKey: Self.focusIdeaTextsKey)
            return
        }

        guard let texts = UserDefaults.standard.stringArray(forKey: Self.focusIdeaTextsKey),
              !texts.isEmpty else { return }

        let descriptor = FetchDescriptor<Idea>()
        guard let allIdeas = try? modelContext.fetch(descriptor) else { return }

        var matched: [Idea] = []
        for text in texts {
            if let idea = allIdeas.first(where: { $0.text == text }) {
                matched.append(idea)
            }
        }

        if !matched.isEmpty {
            focusItems = matched.map { FocusItem(idea: $0) }
        }
    }

    // MARK: - Send Message

    func sendMessage(_ text: String, model: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard let apiKey = fetchAPIKey(), !apiKey.isEmpty else {
            errorMessage = "add your ai api key in settings"
            return
        }

        messages.append(ChatMessage(role: .user, content: trimmed))
        isStreaming = true
        errorMessage = nil
        latestResponse = ""

        await runAgenticLoop(apiKey: apiKey, model: model)

        isStreaming = false
        toolActivity = nil
    }

    // MARK: - Agentic Loop

    private func runAgenticLoop(apiKey: String, model: String) async {
        for _ in 0..<maxToolIterations {
            let apiMessages = buildAPIMessages()
            let (text, toolCalls) = await streamResponse(apiKey: apiKey, model: model, messages: apiMessages)

            if let toolCalls, !toolCalls.isEmpty {
                var assistantMsg = ChatMessage(role: .assistant, content: text ?? "")
                assistantMsg.toolCalls = toolCalls
                messages.append(assistantMsg)

                for tc in toolCalls {
                    toolActivity = toolActivityLabel(for: tc.name)

                    if tc.name == "confirm_focus" {
                        let result = executeConfirmFocus(arguments: tc.arguments)
                        messages.append(ChatMessage(toolResult: result, toolCallId: tc.id, toolName: tc.name))
                    } else {
                        let result = await IdeaTools.execute(
                            name: tc.name,
                            arguments: tc.arguments,
                            modelContext: modelContext,
                            ideasViewModel: ideasViewModel
                        )
                        messages.append(ChatMessage(toolResult: result, toolCallId: tc.id, toolName: tc.name))
                    }
                }

                toolActivity = nil
                continue
            } else {
                // Store latest AI text response for the card display
                if let text, !text.isEmpty {
                    latestResponse = text
                }
                break
            }
        }
    }

    // MARK: - Confirm Focus Tool

    private func executeConfirmFocus(arguments: String) -> String {
        guard let data = arguments.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let searches = args["ideas"] as? [String]
        else { return "{\"error\": \"missing 'ideas' array\"}" }

        let descriptor = FetchDescriptor<Idea>()
        guard let allIdeas = try? modelContext.fetch(descriptor) else {
            return "{\"error\": \"could not fetch ideas\"}"
        }

        var matched: [Idea] = []
        for search in searches {
            let lc = search.lowercased()
            if let idea = allIdeas.first(where: { $0.text.lowercased().contains(lc) }) {
                if !matched.contains(where: { $0.persistentModelID == idea.persistentModelID }) {
                    matched.append(idea)
                }
            }
        }

        if matched.isEmpty {
            return "{\"error\": \"no matching ideas found\"}"
        }

        addFocusItems(matched)

        let names = matched.map { $0.text }
        return IdeaTools.jsonResult(["success": true, "message": "Added \(matched.count) tasks to focus list", "tasks": names])
    }

    // MARK: - Stream Response

    private func streamResponse(
        apiKey: String,
        model: String,
        messages apiMessages: [OpenAIService.Message]
    ) async -> (String?, [ChatMessage.ToolCall]?) {
        messages.append(ChatMessage(role: .assistant, content: ""))
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
                ChatMessage.ToolCall(id: v.id, name: v.name, arguments: v.arguments)
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
            case .user:
                apiMessages.append(OpenAIService.Message(role: "user", content: msg.content))
            case .assistant:
                if let toolCalls = msg.toolCalls, !toolCalls.isEmpty {
                    var m = OpenAIService.Message(role: "assistant", content: msg.content.isEmpty ? "" : msg.content)
                    m.toolCalls = toolCalls.map { tc in
                        ["id": tc.id, "type": "function", "function": ["name": tc.name, "arguments": tc.arguments]] as [String: Any]
                    }
                    apiMessages.append(m)
                } else if !msg.content.isEmpty {
                    apiMessages.append(OpenAIService.Message(role: "assistant", content: msg.content))
                }
            case .tool:
                if let toolCallId = msg.toolCallId {
                    apiMessages.append(OpenAIService.Message(toolResult: msg.content, toolCallId: toolCallId))
                }
            }
        }

        return apiMessages
    }

    // MARK: - System Prompt

    private func buildSystemPrompt() -> String {
        var parts: [String] = []

        let profileDesc = FetchDescriptor<UserProfile>()
        if let profile = (try? modelContext.fetch(profileDesc))?.first, !profile.bio.isEmpty {
            parts.append("USER BIO: \(profile.bio)")
        }

        let ideasDescriptor = FetchDescriptor<Idea>(sortBy: [SortDescriptor(\Idea.createdAt, order: .reverse)])
        if let ideas = try? modelContext.fetch(ideasDescriptor) {
            let valid = ideas.filter { $0.modelContext != nil && !$0.isDone }
            if !valid.isEmpty {
                let summaries = valid.prefix(50).map { idea in
                    var s = "- \(idea.text)"
                    if !idea.tags.isEmpty { s += " [tags: \(idea.tags.joined(separator: ", "))]" }
                    if !idea.category.isEmpty { s += " [category: \(idea.category)]" }
                    if let due = idea.formattedDueDate { s += " [due: \(due)]" }
                    if idea.priority > 0 { s += " [priority: \(idea.priorityLevel.label)]" }
                    if !idea.subtasks.isEmpty {
                        let progress = idea.subtaskProgress
                        s += " [subtasks: \(progress.done)/\(progress.total)]"
                    }
                    if let folder = idea.folder { s += " [folder: \(folder.breadcrumb)]" }
                    return s
                }.joined(separator: "\n")
                parts.append("ACTIVE IDEAS (\(valid.count) total):\n\(summaries)")
            }
        }

        // Current focus items
        if !focusItems.isEmpty {
            let focusList = focusItems.map { item in
                "- \(item.idea.text)\(item.isCompleted ? " [done]" : "")"
            }.joined(separator: "\n")
            parts.append("CURRENT FOCUS LIST:\n\(focusList)")
        }

        let folderDescriptor = FetchDescriptor<Folder>()
        if let allFolders = try? modelContext.fetch(folderDescriptor), !allFolders.isEmpty {
            let roots = allFolders.filter { $0.parent == nil }.sorted { $0.name < $1.name }
            func tree(_ folder: Folder, indent: String = "") -> String {
                var s = "\(indent)- \(folder.name) (\(folder.ideas.count) ideas)"
                for child in folder.sortedChildren { s += "\n" + tree(child, indent: indent + "  ") }
                return s
            }
            parts.append("FOLDERS:\n\(roots.map { tree($0) }.joined(separator: "\n"))")
        }

        let now = Date()
        parts.append("NOW: \(Self.promptDateFormatter.string(from: now))")

        parts.append("""
        You are a focus coach helping the user plan their day. The user always sees their focus task list and today's schedule side by side. You can add tasks to their focus list, suggest priorities, and create new ideas.

        YOUR APPROACH:
        1. Listen to what the user wants to focus on or help with.
        2. Use the read tool to search for relevant ideas if needed. You already have the full list above, so only search if you need more detail.
        3. When you know which ideas they want to work on, call confirm_focus to add them to the focus list.
        4. If the user mentions tasks that don't exist, create them first using the create tool, then add to focus.
        5. You can also give advice on prioritization, time management, and task breakdown.

        RULES:
        - Be warm but concise. This is a quick planning conversation.
        - The user can also manually add items via the + button, so don't over-explain.
        - When you have enough info, call confirm_focus immediately. Don't ask "shall I add these?" — just do it.
        - Keep focus lists to 3-7 items. If the user wants more, gently suggest prioritizing.
        - The confirm_focus tool ADDS to the existing focus list (it doesn't replace it).
        """)

        return parts.joined(separator: "\n\n")
    }

    // MARK: - Tool Definitions

    static let toolDefinitions: [[String: Any]] = {
        var tools = IdeaTools.definitions
        tools.append([
            "type": "function",
            "function": [
                "name": "confirm_focus",
                "description": "Add ideas to the user's focus list for today. Call this when you know which tasks they want to work on. Items are added to the existing list (not replaced).",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "ideas": ["type": "array", "items": ["type": "string"], "description": "Array of idea text strings to match against the database. Use the exact or near-exact idea text."]
                    ] as [String: Any],
                    "required": ["ideas"]
                ] as [String: Any]
            ] as [String: Any]
        ])
        return tools
    }()

    // MARK: - Helpers

    private func fetchAPIKey() -> String? {
        let apiKey = AIProviderKeychain.apiKey()
        return apiKey.isEmpty ? nil : apiKey
    }

    private func toolActivityLabel(for name: String) -> String {
        switch name {
        case "confirm_focus": return "adding to focus..."
        case "create": return "creating..."
        case "read": return "searching..."
        case "update": return "updating..."
        case "delete": return "deleting..."
        default: return "working..."
        }
    }
}
