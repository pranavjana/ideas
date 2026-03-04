import Foundation
import SwiftData

struct IdeaTools {

    // MARK: - Tool Definitions (OpenAI function calling format)

    static let definitions: [[String: Any]] = [
        [
            "type": "function",
            "function": [
                "name": "create_idea",
                "description": "Create a new idea in the user's ideas database. The idea will be automatically tagged and connected to related ideas. Optionally set a due date, time, recurring pattern, and priority.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "text": ["type": "string", "description": "The idea text to save"],
                        "dueDate": ["type": "string", "description": "Optional due date in YYYY-MM-DD format"],
                        "dueTime": ["type": "string", "description": "Optional due time in HH:mm format (24-hour)"],
                        "recurring": ["type": "string", "enum": ["daily", "weekly", "monthly", "weekdays", "yearly"], "description": "Optional recurring pattern"],
                        "priority": ["type": "string", "enum": ["urgent", "high", "medium", "low", "none"], "description": "Optional priority level"]
                    ] as [String: Any],
                    "required": ["text"]
                ] as [String: Any]
            ] as [String: Any]
        ],
        [
            "type": "function",
            "function": [
                "name": "search_ideas",
                "description": "Search for ideas by keyword. Performs a case-insensitive search across idea text, tags, and category. Returns matching ideas with their metadata including due dates.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "Search keyword or phrase"]
                    ],
                    "required": ["query"]
                ] as [String: Any]
            ] as [String: Any]
        ],
        [
            "type": "function",
            "function": [
                "name": "update_idea",
                "description": "Update an existing idea. Find it by matching text content, then update its fields. Pass \"none\" for dueDate, dueTime, or recurring to clear that field.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "search": ["type": "string", "description": "Text to find the idea (partial match)"],
                        "newText": ["type": "string", "description": "New text for the idea"],
                        "newTags": ["type": "array", "items": ["type": "string"], "description": "New tags array"],
                        "newCategory": ["type": "string", "description": "New category"],
                        "dueDate": ["type": "string", "description": "Due date in YYYY-MM-DD format, or \"none\" to clear"],
                        "dueTime": ["type": "string", "description": "Due time in HH:mm format, or \"none\" to clear"],
                        "recurring": ["type": "string", "description": "Recurring pattern (daily/weekly/monthly/weekdays/yearly), or \"none\" to clear"],
                        "priority": ["type": "string", "enum": ["urgent", "high", "medium", "low", "none"], "description": "Priority level, or \"none\" to clear"]
                    ] as [String: Any],
                    "required": ["search"]
                ] as [String: Any]
            ] as [String: Any]
        ],
        [
            "type": "function",
            "function": [
                "name": "delete_idea",
                "description": "Delete an idea from the database. Find it by matching text content.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "Text to find the idea to delete (partial match)"]
                    ],
                    "required": ["query"]
                ] as [String: Any]
            ] as [String: Any]
        ],
        [
            "type": "function",
            "function": [
                "name": "add_update",
                "description": "Add a progress update or note to an existing idea. Use this when the user reports progress, changes, or any update about an idea.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "search": ["type": "string", "description": "Text to find the idea (partial match)"],
                        "update": ["type": "string", "description": "The update text to add"]
                    ] as [String: Any],
                    "required": ["search", "update"]
                ] as [String: Any]
            ] as [String: Any]
        ],
        [
            "type": "function",
            "function": [
                "name": "add_subtask",
                "description": "Add one or more subtasks to an existing idea. Use this to break an idea into actionable steps.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "search": ["type": "string", "description": "Text to find the idea (partial match)"],
                        "subtasks": ["type": "array", "items": ["type": "string"], "description": "List of subtask texts to add"]
                    ] as [String: Any],
                    "required": ["search", "subtasks"]
                ] as [String: Any]
            ] as [String: Any]
        ],
        [
            "type": "function",
            "function": [
                "name": "toggle_subtask",
                "description": "Toggle a subtask's done/todo status on an idea. Find the subtask by partial text match.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "search": ["type": "string", "description": "Text to find the idea (partial match)"],
                        "subtask": ["type": "string", "description": "Text of the subtask to toggle (partial match)"]
                    ] as [String: Any],
                    "required": ["search", "subtask"]
                ] as [String: Any]
            ] as [String: Any]
        ],
        [
            "type": "function",
            "function": [
                "name": "remove_subtask",
                "description": "Remove a subtask from an idea. Find the subtask by partial text match.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "search": ["type": "string", "description": "Text to find the idea (partial match)"],
                        "subtask": ["type": "string", "description": "Text of the subtask to remove (partial match)"]
                    ] as [String: Any],
                    "required": ["search", "subtask"]
                ] as [String: Any]
            ] as [String: Any]
        ]
    ]

    // MARK: - Tool Execution

    @MainActor
    static func execute(
        name: String,
        arguments: String,
        modelContext: ModelContext,
        ideasViewModel: IdeasViewModel?
    ) async -> String {
        guard let argsData = arguments.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any]
        else {
            return "{\"error\": \"invalid arguments\"}"
        }

        switch name {
        case "create_idea":
            return await executeCreate(args: args, modelContext: modelContext, ideasViewModel: ideasViewModel)
        case "search_ideas":
            return executeSearch(args: args, modelContext: modelContext)
        case "update_idea":
            return await executeUpdate(args: args, modelContext: modelContext, ideasViewModel: ideasViewModel)
        case "delete_idea":
            return executeDelete(args: args, modelContext: modelContext)
        case "add_update":
            return executeAddUpdate(args: args, modelContext: modelContext)
        case "add_subtask":
            return executeAddSubtask(args: args, modelContext: modelContext)
        case "toggle_subtask":
            return executeToggleSubtask(args: args, modelContext: modelContext)
        case "remove_subtask":
            return executeRemoveSubtask(args: args, modelContext: modelContext)
        default:
            return "{\"error\": \"unknown tool: \(name)\"}"
        }
    }

    // MARK: - Create

    @MainActor
    private static func executeCreate(
        args: [String: Any],
        modelContext: ModelContext,
        ideasViewModel: IdeasViewModel?
    ) async -> String {
        guard let text = args["text"] as? String, !text.isEmpty else {
            return "{\"error\": \"missing 'text' parameter\"}"
        }

        let idea = Idea(text: text)
        idea.positionX = 300 + Double.random(in: -100...100)
        idea.positionY = 400 + Double.random(in: -100...100)

        // Parse optional due date
        if let dueDateStr = args["dueDate"] as? String {
            idea.dueDate = parseDateString(dueDateStr)
        }
        if let dueTimeStr = args["dueTime"] as? String, isValidTime(dueTimeStr) {
            idea.dueTime = dueTimeStr
        }
        if let recurringStr = args["recurring"] as? String,
           Idea.RecurringPattern(rawValue: recurringStr) != nil {
            idea.recurringPattern = recurringStr
        }
        if let priorityStr = args["priority"] as? String,
           let p = Idea.Priority(fromString: priorityStr) {
            idea.priorityLevel = p
        }

        modelContext.insert(idea)
        try? modelContext.save()

        // tagIdea automatically refreshes connections when done
        if let vm = ideasViewModel {
            Task {
                await vm.tagIdea(idea)
            }
        }

        var msg = "Created idea: \(text)"
        if let formatted = idea.formattedDueDate { msg += " (due \(formatted))" }
        if let r = idea.recurringPattern { msg += " [repeats \(r)]" }
        return "{\"success\": true, \"message\": \"\(msg)\"}"
    }

    // MARK: - Search

    @MainActor
    private static func executeSearch(args: [String: Any], modelContext: ModelContext) -> String {
        guard let query = args["query"] as? String, !query.isEmpty else {
            return "{\"error\": \"missing 'query' parameter\"}"
        }

        let descriptor = FetchDescriptor<Idea>(
            sortBy: [SortDescriptor(\Idea.createdAt, order: .reverse)]
        )
        guard let allIdeas = try? modelContext.fetch(descriptor) else {
            return "{\"results\": [], \"count\": 0}"
        }

        let lowercaseQuery = query.lowercased()
        let validIdeas = allIdeas.filter { $0.modelContext != nil }
        let matches = validIdeas.filter { idea in
            idea.text.lowercased().contains(lowercaseQuery)
            || idea.tags.contains(where: { $0.lowercased().contains(lowercaseQuery) })
            || idea.category.lowercased().contains(lowercaseQuery)
        }

        let results = matches.prefix(20).map { idea -> [String: Any] in
            var result: [String: Any] = [
                "text": idea.text,
                "tags": idea.tags,
                "category": idea.category,
                "created": idea.createdAt.formatted(.dateTime.month().day().hour().minute()),
                "connections": idea.allLinks.count
            ]
            if let formatted = idea.formattedDueDate {
                result["dueDate"] = formatted
            }
            if let r = idea.recurringPattern {
                result["recurring"] = r
            }
            if !idea.updates.isEmpty {
                result["updates"] = idea.parsedUpdates.map { "\($0.date.formatted(.dateTime.month(.abbreviated).day().hour().minute())): \($0.text)" }
            }
            if !idea.subtasks.isEmpty {
                result["subtasks"] = idea.parsedSubtasks.map { ($0.isDone ? "[x] " : "[ ] ") + $0.text }
            }
            if idea.priority > 0 {
                result["priority"] = idea.priorityLevel.label
            }
            return result
        }

        let response: [String: Any] = [
            "results": results,
            "count": matches.count,
            "showing": min(matches.count, 20)
        ]

        if let data = try? JSONSerialization.data(withJSONObject: response),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return "{\"results\": [], \"count\": 0}"
    }

    // MARK: - Update

    @MainActor
    private static func executeUpdate(
        args: [String: Any],
        modelContext: ModelContext,
        ideasViewModel: IdeasViewModel?
    ) async -> String {
        guard let search = args["search"] as? String, !search.isEmpty else {
            return "{\"error\": \"missing 'search' parameter\"}"
        }

        let descriptor = FetchDescriptor<Idea>()
        guard let allIdeas = try? modelContext.fetch(descriptor) else {
            return "{\"error\": \"could not fetch ideas\"}"
        }

        let lowercaseSearch = search.lowercased()
        guard let idea = allIdeas.first(where: { $0.text.lowercased().contains(lowercaseSearch) }) else {
            return "{\"error\": \"no idea found matching '\(search)'\"}"
        }

        var changes: [String] = []

        if let newText = args["newText"] as? String {
            idea.text = newText
            changes.append("text")
        }
        if let newTags = args["newTags"] as? [String] {
            idea.tags = newTags
            changes.append("tags")
        }
        if let newCategory = args["newCategory"] as? String {
            idea.category = newCategory
            changes.append("category")
        }
        if let dueDateStr = args["dueDate"] as? String {
            if dueDateStr.lowercased() == "none" {
                idea.dueDate = nil
            } else {
                idea.dueDate = parseDateString(dueDateStr)
            }
            changes.append("dueDate")
        }
        if let dueTimeStr = args["dueTime"] as? String {
            if dueTimeStr.lowercased() == "none" {
                idea.dueTime = nil
            } else if isValidTime(dueTimeStr) {
                idea.dueTime = dueTimeStr
            }
            changes.append("dueTime")
        }
        if let recurringStr = args["recurring"] as? String {
            if recurringStr.lowercased() == "none" {
                idea.recurringPattern = nil
            } else if Idea.RecurringPattern(rawValue: recurringStr) != nil {
                idea.recurringPattern = recurringStr
            }
            changes.append("recurring")
        }
        if let priorityStr = args["priority"] as? String {
            if let p = Idea.Priority(fromString: priorityStr) {
                idea.priorityLevel = p
            }
            changes.append("priority")
        }

        try? modelContext.save()

        // Refresh connections if text or tags changed
        if !changes.isEmpty, let vm = ideasViewModel {
            await vm.refreshConnections(for: idea)
        }

        if changes.isEmpty {
            return "{\"success\": true, \"message\": \"No changes specified for idea: \(idea.text)\"}"
        }
        return "{\"success\": true, \"message\": \"Updated \(changes.joined(separator: ", ")) for idea: \(idea.text)\"}"
    }

    // MARK: - Delete

    @MainActor
    private static func executeDelete(args: [String: Any], modelContext: ModelContext) -> String {
        guard let query = args["query"] as? String, !query.isEmpty else {
            return "{\"error\": \"missing 'query' parameter\"}"
        }

        let descriptor = FetchDescriptor<Idea>()
        guard let allIdeas = try? modelContext.fetch(descriptor) else {
            return "{\"error\": \"could not fetch ideas\"}"
        }

        let lowercaseQuery = query.lowercased()
        guard let idea = allIdeas.first(where: { $0.text.lowercased().contains(lowercaseQuery) }) else {
            return "{\"error\": \"no idea found matching '\(query)'\"}"
        }

        let deletedText = idea.text
        modelContext.delete(idea)
        try? modelContext.save()

        return "{\"success\": true, \"message\": \"Deleted idea: \(deletedText)\"}"
    }

    // MARK: - Add Update

    @MainActor
    private static func executeAddUpdate(args: [String: Any], modelContext: ModelContext) -> String {
        guard let search = args["search"] as? String, !search.isEmpty else {
            return "{\"error\": \"missing 'search' parameter\"}"
        }
        guard let update = args["update"] as? String, !update.isEmpty else {
            return "{\"error\": \"missing 'update' parameter\"}"
        }

        let descriptor = FetchDescriptor<Idea>()
        guard let allIdeas = try? modelContext.fetch(descriptor) else {
            return "{\"error\": \"could not fetch ideas\"}"
        }

        let lowercaseSearch = search.lowercased()
        guard let idea = allIdeas.first(where: { $0.text.lowercased().contains(lowercaseSearch) }) else {
            return "{\"error\": \"no idea found matching '\(search)'\"}"
        }

        idea.addUpdate(update)
        try? modelContext.save()

        return "{\"success\": true, \"message\": \"Added update to idea: \(idea.text)\"}"
    }

    // MARK: - Subtasks

    @MainActor
    private static func executeAddSubtask(args: [String: Any], modelContext: ModelContext) -> String {
        guard let search = args["search"] as? String, !search.isEmpty else {
            return "{\"error\": \"missing 'search' parameter\"}"
        }
        guard let subtasks = args["subtasks"] as? [String], !subtasks.isEmpty else {
            return "{\"error\": \"missing 'subtasks' parameter\"}"
        }

        let descriptor = FetchDescriptor<Idea>()
        guard let allIdeas = try? modelContext.fetch(descriptor) else {
            return "{\"error\": \"could not fetch ideas\"}"
        }

        let lowercaseSearch = search.lowercased()
        guard let idea = allIdeas.first(where: { $0.text.lowercased().contains(lowercaseSearch) }) else {
            return "{\"error\": \"no idea found matching '\(search)'\"}"
        }

        for subtask in subtasks {
            idea.addSubtask(subtask)
        }
        try? modelContext.save()

        return "{\"success\": true, \"message\": \"Added \(subtasks.count) subtask(s) to: \(idea.text)\"}"
    }

    @MainActor
    private static func executeToggleSubtask(args: [String: Any], modelContext: ModelContext) -> String {
        guard let search = args["search"] as? String, !search.isEmpty else {
            return "{\"error\": \"missing 'search' parameter\"}"
        }
        guard let subtaskQuery = args["subtask"] as? String, !subtaskQuery.isEmpty else {
            return "{\"error\": \"missing 'subtask' parameter\"}"
        }

        let descriptor = FetchDescriptor<Idea>()
        guard let allIdeas = try? modelContext.fetch(descriptor) else {
            return "{\"error\": \"could not fetch ideas\"}"
        }

        let lowercaseSearch = search.lowercased()
        guard let idea = allIdeas.first(where: { $0.text.lowercased().contains(lowercaseSearch) }) else {
            return "{\"error\": \"no idea found matching '\(search)'\"}"
        }

        let lowercaseSubtask = subtaskQuery.lowercased()
        guard let index = idea.subtasks.firstIndex(where: { $0.lowercased().contains(lowercaseSubtask) }) else {
            return "{\"error\": \"no subtask found matching '\(subtaskQuery)'\"}"
        }

        idea.toggleSubtask(at: index)
        try? modelContext.save()

        let parsed = idea.parsedSubtasks[index]
        return "{\"success\": true, \"message\": \"Toggled subtask '\(parsed.text)' to \(parsed.isDone ? "done" : "todo")\"}"
    }

    @MainActor
    private static func executeRemoveSubtask(args: [String: Any], modelContext: ModelContext) -> String {
        guard let search = args["search"] as? String, !search.isEmpty else {
            return "{\"error\": \"missing 'search' parameter\"}"
        }
        guard let subtaskQuery = args["subtask"] as? String, !subtaskQuery.isEmpty else {
            return "{\"error\": \"missing 'subtask' parameter\"}"
        }

        let descriptor = FetchDescriptor<Idea>()
        guard let allIdeas = try? modelContext.fetch(descriptor) else {
            return "{\"error\": \"could not fetch ideas\"}"
        }

        let lowercaseSearch = search.lowercased()
        guard let idea = allIdeas.first(where: { $0.text.lowercased().contains(lowercaseSearch) }) else {
            return "{\"error\": \"no idea found matching '\(search)'\"}"
        }

        let lowercaseSubtask = subtaskQuery.lowercased()
        guard let index = idea.subtasks.firstIndex(where: { $0.lowercased().contains(lowercaseSubtask) }) else {
            return "{\"error\": \"no subtask found matching '\(subtaskQuery)'\"}"
        }

        let removedText = idea.parsedSubtasks[index].text
        idea.removeSubtask(at: index)
        try? modelContext.save()

        return "{\"success\": true, \"message\": \"Removed subtask '\(removedText)' from: \(idea.text)\"}"
    }

    // MARK: - Date Helpers

    private static func parseDateString(_ str: String) -> Date? {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        guard let date = fmt.date(from: str) else { return nil }
        return Calendar.current.startOfDay(for: date)
    }

    private static func isValidTime(_ str: String) -> Bool {
        let pattern = #"^\d{2}:\d{2}$"#
        return str.range(of: pattern, options: .regularExpression) != nil
    }
}
