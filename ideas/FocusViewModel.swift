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

    // Focus state
    var phase: FocusPhase = .chat
    var focusItems: [FocusItem] = []
    var userName: String = ""

    private var modelContext: ModelContext
    private var ideasViewModel: IdeasViewModel?
    private let maxToolIterations = 10

    enum FocusPhase {
        case chat       // User is telling AI what they want to focus on
        case confirmed  // Tasks are locked in, focus mode active
    }

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
    private static let focusIdeaIDsKey = "focus_idea_ids"

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
            // Try to extract first name from bio
            let bio = profile.bio.trimmingCharacters(in: .whitespacesAndNewlines)
            // Common patterns: "I'm Pranav", "My name is Pranav", or just take first word
            if let range = bio.range(of: #"(?:I'm|I am|my name is|name is|i'm)\s+(\w+)"#, options: [.regularExpression, .caseInsensitive]) {
                let match = bio[range]
                let words = match.split(separator: " ")
                if let last = words.last {
                    userName = String(last).lowercased()
                    return
                }
            }
            // Fallback: first word if short enough
            let firstWord = bio.split(separator: " ").first.map(String.init) ?? ""
            if firstWord.count <= 15 && !firstWord.isEmpty {
                userName = firstWord.lowercased()
            }
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

        await runAgenticLoop(apiKey: apiKey, model: model)

        isStreaming = false
        toolActivity = nil
    }

    // MARK: - Confirm Focus

    func confirmFocus(ideas: [Idea]) {
        focusItems = ideas.map { FocusItem(idea: $0) }
        withAnimation(.easeInOut(duration: 0.3)) {
            phase = .confirmed
        }
        saveFocus()
    }

    func resetFocus() {
        withAnimation(.easeInOut(duration: 0.3)) {
            phase = .chat
            focusItems = []
            messages = []
        }
        UserDefaults.standard.removeObject(forKey: Self.focusDateKey)
        UserDefaults.standard.removeObject(forKey: Self.focusIdeaIDsKey)
    }

    // MARK: - Persistence (per-day)

    private func saveFocus() {
        let today = Calendar.current.startOfDay(for: Date())
        UserDefaults.standard.set(today, forKey: Self.focusDateKey)
        let texts = focusItems.map { $0.idea.text }
        UserDefaults.standard.set(texts, forKey: Self.focusIdeaIDsKey)
    }

    private func restoreFocus() {
        guard let savedDate = UserDefaults.standard.object(forKey: Self.focusDateKey) as? Date,
              Calendar.current.isDate(savedDate, inSameDayAs: Date()) else {
            UserDefaults.standard.removeObject(forKey: Self.focusDateKey)
            UserDefaults.standard.removeObject(forKey: Self.focusIdeaIDsKey)
            return
        }

        guard let texts = UserDefaults.standard.stringArray(forKey: Self.focusIdeaIDsKey),
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
            phase = .confirmed
        }
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

        confirmFocus(ideas: matched)

        let names = matched.map { $0.text }
        return IdeaTools.jsonResult(["success": true, "message": "Focus mode activated with \(matched.count) tasks", "tasks": names])
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

        // User context
        let profileDesc = FetchDescriptor<UserProfile>()
        if let profile = (try? modelContext.fetch(profileDesc))?.first, !profile.bio.isEmpty {
            parts.append("USER BIO: \(profile.bio)")
        }

        // Full ideas context
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

        // Folder context
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

        // Date/time
        let now = Date()
        let fmt = DateFormatter()
        fmt.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm a"
        parts.append("NOW: \(fmt.string(from: now))")

        parts.append("""
        You are a focus coach helping the user plan their day. Your job is to understand what they want to focus on today, find the relevant ideas from their database, and help them commit to a focused task list.

        YOUR APPROACH:
        1. Listen to what the user wants to focus on today.
        2. Use the read tool to search for relevant ideas if needed. You already have the full list above, so only search if you need more detail.
        3. If the user's request is ambiguous (e.g., "study for my exam" but they have multiple chapters), ask a clarifying question. Ask ONE question at a time.
        4. Once you know exactly which ideas/tasks they want to focus on, call confirm_focus with the list of idea texts to match.

        RULES:
        - Be warm but concise. This is a quick planning conversation, not a long discussion.
        - Ask clarifying questions ONLY when truly needed — if they say "work on my project" and there's only one project, just confirm it.
        - When you have enough info, call confirm_focus immediately. Don't ask "shall I confirm?" — just do it.
        - The confirm_focus tool locks in the tasks and switches to focus mode. Only call it once you're confident about the task list.
        - If the user mentions tasks that don't exist as ideas, you can create them first using the create tool, then confirm.
        - Suggest a reasonable ordering if relevant (e.g., hardest first, deadlines first).
        - Keep it to 3-7 focus items. If the user wants more, gently suggest prioritizing.
        """)

        return parts.joined(separator: "\n\n")
    }

    // MARK: - Tool Definitions

    static let toolDefinitions: [[String: Any]] = {
        // Include standard CRUD tools plus the focus-specific confirm tool
        var tools = IdeaTools.definitions
        tools.append([
            "type": "function",
            "function": [
                "name": "confirm_focus",
                "description": "Lock in the user's focus tasks for today. Call this once you know which ideas they want to work on. This switches the UI to a focused task view.",
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
        case "confirm_focus": return "setting up focus..."
        case "create": return "creating..."
        case "read": return "searching..."
        case "update": return "updating..."
        case "delete": return "deleting..."
        default: return "working..."
        }
    }
}
