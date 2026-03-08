import SwiftUI
import SwiftData

@MainActor
@Observable
class ChatViewModel {
    private var modelContext: ModelContext
    var ideasViewModel: IdeasViewModel?
    var messages: [ChatMessage] = []
    var isStreaming = false
    var errorMessage: String?
    var toolActivity: String?
    var silentResponseText: String = ""

    private let maxToolIterations = 10

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func sendMessage(_ text: String, model: String = "anthropic/claude-haiku-4.5", imageData: Data? = nil) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard let apiKey = fetchAPIKey(), !apiKey.isEmpty else {
            errorMessage = "add your openrouter api key in settings"
            return
        }

        // Add user message
        messages.append(ChatMessage(role: .user, content: trimmed, imageData: imageData))

        isStreaming = true
        errorMessage = nil

        await runAgenticLoop(apiKey: apiKey, model: model)

        isStreaming = false
        toolActivity = nil
    }

    func clearChat() {
        messages.removeAll()
        errorMessage = nil
        toolActivity = nil
    }

    /// Silently execute an AI command — runs the agentic loop without adding to visible chat.
    /// Returns the final assistant text response (if any).
    @discardableResult
    func sendSilent(_ text: String, model: String = "anthropic/claude-haiku-4.5") async -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        guard let apiKey = fetchAPIKey(), !apiKey.isEmpty else {
            errorMessage = "add your openrouter api key in settings"
            return nil
        }

        errorMessage = nil
        silentResponseText = ""
        toolActivity = "thinking..."

        // Use a separate message list so visible chat is untouched
        let systemPrompt = buildSystemPrompt()
        var silentMessages: [OpenAIService.Message] = [
            OpenAIService.Message(role: "system", content: systemPrompt),
            OpenAIService.Message(role: "user", content: trimmed)
        ]

        for _ in 0..<maxToolIterations {
            let result = await silentCompletion(apiKey: apiKey, model: model, messages: silentMessages)

            if let toolCalls = result.toolCalls, !toolCalls.isEmpty {
                // Add assistant message with tool calls
                var assistantMsg = OpenAIService.Message(role: "assistant", content: result.text ?? "")
                assistantMsg.toolCalls = toolCalls.map { tc in
                    [
                        "id": tc.id,
                        "type": "function",
                        "function": [
                            "name": tc.name,
                            "arguments": tc.arguments
                        ]
                    ] as [String: Any]
                }
                silentMessages.append(assistantMsg)

                // Execute tools
                for tc in toolCalls {
                    toolActivity = toolActivityLabel(for: tc.name)
                    let toolResult = await IdeaTools.execute(
                        name: tc.name,
                        arguments: tc.arguments,
                        modelContext: modelContext,
                        ideasViewModel: ideasViewModel
                    )
                    silentMessages.append(OpenAIService.Message(
                        toolResult: toolResult,
                        toolCallId: tc.id
                    ))
                }
                toolActivity = "thinking..."
                continue
            } else {
                toolActivity = nil
                return result.text
            }
        }
        toolActivity = nil
        return nil
    }

    /// Non-streaming completion for silent mode.
    private func silentCompletion(
        apiKey: String,
        model: String,
        messages: [OpenAIService.Message]
    ) async -> (text: String?, toolCalls: [ChatMessage.ToolCall]?) {
        var toolCallAccumulators: [Int: (id: String, name: String, arguments: String)] = [:]
        var text = ""

        do {
            let stream = OpenAIService.streamCompletionWithTools(
                apiKey: apiKey,
                model: model,
                messages: messages,
                tools: IdeaTools.definitions
            )

            for try await event in stream {
                switch event {
                case .textDelta(let delta):
                    text += delta
                    silentResponseText += delta
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
            return (nil, nil)
        }

        if !toolCallAccumulators.isEmpty {
            let toolCalls = toolCallAccumulators.sorted(by: { $0.key < $1.key }).map { (_, v) in
                ChatMessage.ToolCall(id: v.id, name: v.name, arguments: v.arguments)
            }
            return (text.isEmpty ? nil : text, toolCalls)
        }

        return (text.isEmpty ? nil : text, nil)
    }

    // MARK: - Agentic Loop

    private func runAgenticLoop(apiKey: String, model: String) async {
        for _ in 0..<maxToolIterations {
            // Build API messages from conversation history
            let apiMessages = buildAPIMessages()

            // Stream response
            let (text, toolCalls) = await streamResponse(
                apiKey: apiKey,
                model: model,
                messages: apiMessages
            )

            if let toolCalls, !toolCalls.isEmpty {
                // Append assistant message with tool calls (content may be empty)
                var assistantMsg = ChatMessage(role: .assistant, content: text ?? "")
                assistantMsg.toolCalls = toolCalls
                messages.append(assistantMsg)

                // Execute each tool and append results
                for tc in toolCalls {
                    toolActivity = toolActivityLabel(for: tc.name)

                    let result = await IdeaTools.execute(
                        name: tc.name,
                        arguments: tc.arguments,
                        modelContext: modelContext,
                        ideasViewModel: ideasViewModel
                    )

                    messages.append(ChatMessage(
                        toolResult: result,
                        toolCallId: tc.id,
                        toolName: tc.name
                    ))
                }

                toolActivity = nil
                // Loop — send tool results back to the model
                continue
            } else {
                // Pure text response — we're done
                // The assistant message was already appended during streaming
                break
            }
        }
    }

    /// Streams a response, returning accumulated text and any tool calls.
    private func streamResponse(
        apiKey: String,
        model: String,
        messages apiMessages: [OpenAIService.Message]
    ) async -> (String?, [ChatMessage.ToolCall]?) {
        // Add empty assistant placeholder for streaming text
        messages.append(ChatMessage(role: .assistant, content: ""))
        let assistantIndex = messages.count - 1

        // Accumulate tool calls by index
        var toolCallAccumulators: [Int: (id: String, name: String, arguments: String)] = [:]
        do {
            let stream = OpenAIService.streamCompletionWithTools(
                apiKey: apiKey,
                model: model,
                messages: apiMessages,
                tools: IdeaTools.definitions
            )

            for try await event in stream {
                switch event {
                case .textDelta(let delta):
                    messages[assistantIndex].content += delta

                case .toolCallDelta(let index, let id, let name, let argsDelta):
                    if toolCallAccumulators[index] == nil {
                        toolCallAccumulators[index] = (id: id ?? "", name: name ?? "", arguments: "")
                    }
                    if let id, !id.isEmpty {
                        toolCallAccumulators[index]?.id = id
                    }
                    if let name, !name.isEmpty {
                        toolCallAccumulators[index]?.name = name
                    }
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

        // Convert accumulators to ToolCall array
        if !toolCallAccumulators.isEmpty {
            let toolCalls = toolCallAccumulators.sorted(by: { $0.key < $1.key }).map { (_, value) in
                ChatMessage.ToolCall(id: value.id, name: value.name, arguments: value.arguments)
            }
            // Remove the streaming placeholder — we'll re-add a proper message with tool_calls
            let accumulatedText = messages[assistantIndex].content
            messages.remove(at: assistantIndex)
            return (accumulatedText.isEmpty ? nil : accumulatedText, toolCalls)
        }

        // Pure text response — placeholder already has the content
        return (messages[assistantIndex].content, nil)
    }

    // MARK: - Build API Messages

    private func buildAPIMessages() -> [OpenAIService.Message] {
        var apiMessages: [OpenAIService.Message] = []

        // System prompt
        let systemPrompt = buildSystemPrompt()
        apiMessages.append(OpenAIService.Message(role: "system", content: systemPrompt))

        // Conversation history
        for msg in messages {
            switch msg.role {
            case .user:
                if let imageData = msg.imageData {
                    let base64 = imageData.base64EncodedString()
                    var m = OpenAIService.Message(role: "user", content: msg.content)
                    m.imageBase64 = base64
                    apiMessages.append(m)
                } else {
                    apiMessages.append(OpenAIService.Message(role: "user", content: msg.content))
                }

            case .assistant:
                if let toolCalls = msg.toolCalls, !toolCalls.isEmpty {
                    // Assistant message with tool calls
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

            case .tool:
                if let toolCallId = msg.toolCallId {
                    apiMessages.append(OpenAIService.Message(
                        toolResult: msg.content,
                        toolCallId: toolCallId
                    ))
                }
            }
        }

        return apiMessages
    }

    // MARK: - Private Helpers

    private func fetchAPIKey() -> String? {
        let descriptor = FetchDescriptor<UserProfile>()
        return (try? modelContext.fetch(descriptor))?.first?.openaiAPIKey
    }

    private func buildSystemPrompt() -> String {
        var parts: [String] = []

        // Profile context
        let descriptor = FetchDescriptor<UserProfile>()
        if let profile = (try? modelContext.fetch(descriptor))?.first {
            if !profile.bio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parts.append("USER BIO: \(profile.bio)")
            }
            if !profile.verifiedTags.isEmpty {
                parts.append("SAVED PROFILE TAGS (master tag list from settings, used for categorization): [\(profile.verifiedTags.joined(separator: ", "))]")
            } else {
                parts.append("SAVED PROFILE TAGS: none set yet")
            }
        }

        // Ideas context — full database dump
        let ideasDescriptor = FetchDescriptor<Idea>(
            sortBy: [SortDescriptor(\Idea.createdAt, order: .reverse)]
        )
        if let ideas = try? modelContext.fetch(ideasDescriptor) {
            // Filter out detached/deleted objects to prevent faulting crashes
            let validIdeas = ideas.filter { $0.modelContext != nil }
            parts.append("TOTAL IDEAS IN DATABASE: \(validIdeas.count)")
            if !validIdeas.isEmpty {
                // Collect all unique tags across all ideas
                let allTags = Set(validIdeas.flatMap { $0.tags })
                if !allTags.isEmpty {
                    parts.append("ALL TAGS IN USE ACROSS IDEAS: [\(allTags.sorted().joined(separator: ", "))]")
                }
                // Collect all unique categories
                let allCategories = Set(validIdeas.compactMap { $0.category.isEmpty ? nil : $0.category })
                if !allCategories.isEmpty {
                    parts.append("ALL CATEGORIES IN USE: [\(allCategories.sorted().joined(separator: ", "))]")
                }

                let summaries = validIdeas.prefix(50).map { idea in
                    var s = "- \(idea.text)"
                    if !idea.tags.isEmpty { s += " [tags: \(idea.tags.joined(separator: ", "))]" }
                    if !idea.category.isEmpty { s += " [category: \(idea.category)]" }
                    s += " [links: \(idea.allLinks.count)]"
                    if let due = idea.formattedDueDate { s += " [due: \(due)]" }
                    if let r = idea.recurringPattern { s += " [repeats: \(r)]" }
                    if !idea.updates.isEmpty { s += " [updates: \(idea.updates.count)]" }
                    if !idea.subtasks.isEmpty {
                        let progress = idea.subtaskProgress
                        s += " [subtasks: \(progress.done)/\(progress.total)]"
                    }
                    if idea.priority > 0 { s += " [priority: \(idea.priorityLevel.label)]" }
                    return s
                }.joined(separator: "\n")
                parts.append("IDEAS (most recent first):\n\(summaries)")
            }
        }

        let now = Date()
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "EEEE, MMMM d, yyyy"
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "h:mm a"
        let tz = TimeZone.current
        parts.append("CURRENT DATE AND TIME: \(dateFmt.string(from: now)) at \(timeFmt.string(from: now)) (\(tz.identifier), UTC\(tz.secondsFromGMT() >= 0 ? "+" : "")\(tz.secondsFromGMT() / 3600))")

        parts.append("""
        You are a helpful thinking partner embedded in an app called "ideas". \
        You have FULL knowledge of the user's database shown above — their profile, saved tags, all ideas, tags, categories, and connections. \
        When the user asks about their data, answer from the context above. Use the search tool for precise queries. \
        You can create, search, update, delete ideas, and add updates to ideas using your tools. \
        You can set due dates (YYYY-MM-DD), due times (HH:mm), and recurring patterns (daily/weekly/monthly/weekdays/yearly) on ideas. \
        Pass "none" to clear a due date, time, or recurring pattern. \
        When the user says things like "by Friday" or "next Tuesday", convert to the correct YYYY-MM-DD date. \
        Use add_update when the user reports progress or changes on an idea — this adds a timestamped note that appears in the idea's update log. \
        Use add_subtask to break ideas into actionable steps. Use toggle_subtask to mark subtasks done/undone, and remove_subtask to delete them. \
        You can set priority levels (urgent/high/medium/low/none) on ideas via update_idea. When the user gives context like "focus on school this week" or "exams coming up", call update_idea for each relevant idea to set appropriate priorities. \
        You can read and write markdown notes on any idea using read_notes and write_notes. Use these to help users develop detailed notes, outlines, and structured content for their ideas. \
        Be concise and thoughtful. Reference specific ideas when relevant.
        """)

        return parts.joined(separator: "\n\n")
    }

    private func toolActivityLabel(for toolName: String) -> String {
        switch toolName {
        case "create_idea": return "creating idea..."
        case "search_ideas": return "searching ideas..."
        case "update_idea": return "updating idea..."
        case "delete_idea": return "deleting idea..."
        case "add_update": return "adding update..."
        case "add_subtask": return "adding subtasks..."
        case "toggle_subtask": return "toggling subtask..."
        case "remove_subtask": return "removing subtask..."
        case "write_notes": return "writing notes..."
        case "read_notes": return "reading notes..."
        default: return "working..."
        }
    }
}
