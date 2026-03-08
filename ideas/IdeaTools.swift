import Foundation
import SwiftUI
import SwiftData

struct IdeaTools {

    // MARK: - Tool Definitions (4 CRUD tools)

    static let definitions: [[String: Any]] = [
        [
            "type": "function",
            "function": [
                "name": "create",
                "description": """
                Create something new. Use type to specify what to create:
                - "idea": A new idea (auto-tagged and connected). Params: text, dueDate, dueTime, recurring, priority, folder
                - "folder": A new folder for organizing ideas (can be nested). Params: name, parent, icon, color
                - "subtask": Add subtasks to an existing idea. Params: search (find the idea), subtasks (array of texts)
                - "update": Add a timestamped progress note to an idea. Params: search, text
                - "note": Write/replace markdown notes on an idea. Params: search, content
                """,
                "parameters": [
                    "type": "object",
                    "properties": [
                        "type": ["type": "string", "enum": ["idea", "folder", "subtask", "update", "note"], "description": "What to create"],
                        // idea
                        "text": ["type": "string", "description": "Idea text, or update text (for type=update)"],
                        "dueDate": ["type": "string", "description": "Due date YYYY-MM-DD (idea)"],
                        "dueTime": ["type": "string", "description": "Due time HH:mm (idea)"],
                        "recurring": ["type": "string", "enum": ["daily", "weekly", "monthly", "weekdays", "yearly"], "description": "Recurring pattern (idea)"],
                        "priority": ["type": "string", "enum": ["urgent", "high", "medium", "low", "none"], "description": "Priority (idea)"],
                        "folder": ["type": "string", "description": "Folder name or full path like 'School / Projects' (idea)"],
                        // folder
                        "name": ["type": "string", "description": "Folder name (folder)"],
                        "parent": ["type": "string", "description": "Parent folder name to nest under (folder)"],
                        "icon": ["type": "string", "description": "SF Symbol name e.g. 'briefcase', 'graduationcap', 'book' (folder). Defaults to 'folder'."],
                        "color": ["type": "string", "description": "Hex color e.g. '#FF4D4D' (folder)"],
                        // subtask, update, note
                        "search": ["type": "string", "description": "Text to find the idea (subtask/update/note)"],
                        "subtasks": ["type": "array", "items": ["type": "string"], "description": "Subtask texts (subtask)"],
                        "content": ["type": "string", "description": "Markdown content (note)"]
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
                Read/search data. Use type to specify what to read:
                - "ideas": Search ideas by keyword across text, tags, category, folder. Params: query, folder (optional filter)
                - "folders": List all folders and their hierarchy with idea counts.
                - "notes": Read an idea's notes. Params: search
                """,
                "parameters": [
                    "type": "object",
                    "properties": [
                        "type": ["type": "string", "enum": ["ideas", "folders", "notes"], "description": "What to read"],
                        "query": ["type": "string", "description": "Search keyword (ideas)"],
                        "folder": ["type": "string", "description": "Folder to search within (ideas)"],
                        "search": ["type": "string", "description": "Text to find the idea (notes)"]
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
                Update something that exists. Use type to specify what to update:
                - "idea": Update an idea's fields. Params: search, then any of: newText, newTags, newCategory, dueDate, dueTime, recurring, priority, folder, done. Pass "none" to clear optional fields.
                - "folder": Rename or restyle a folder. Params: name (find folder), newName, newIcon, newColor, newParent
                - "subtask": Toggle a subtask's done/todo status. Params: search (find idea), subtask (text match)
                - "note": Append to an idea's existing notes. Params: search, content
                """,
                "parameters": [
                    "type": "object",
                    "properties": [
                        "type": ["type": "string", "enum": ["idea", "folder", "subtask", "note"], "description": "What to update"],
                        // idea
                        "search": ["type": "string", "description": "Text to find the idea (idea/subtask/note)"],
                        "newText": ["type": "string", "description": "New idea text (idea)"],
                        "newTags": ["type": "array", "items": ["type": "string"], "description": "New tags (idea)"],
                        "newCategory": ["type": "string", "description": "New category (idea)"],
                        "dueDate": ["type": "string", "description": "Due date YYYY-MM-DD or 'none' (idea)"],
                        "dueTime": ["type": "string", "description": "Due time HH:mm or 'none' (idea)"],
                        "recurring": ["type": "string", "description": "Recurring pattern or 'none' (idea)"],
                        "priority": ["type": "string", "enum": ["urgent", "high", "medium", "low", "none"], "description": "Priority (idea)"],
                        "folder": ["type": "string", "description": "Folder name or full path like 'School / Projects', or 'none' to remove (idea)"],
                        "done": ["type": "boolean", "description": "Mark done or undone (idea)"],
                        // folder
                        "name": ["type": "string", "description": "Folder to find (folder)"],
                        "newName": ["type": "string", "description": "New folder name (folder)"],
                        "newIcon": ["type": "string", "description": "New icon (folder)"],
                        "newColor": ["type": "string", "description": "New hex color (folder)"],
                        "newParent": ["type": "string", "description": "New parent folder or 'none' (folder)"],
                        // subtask
                        "subtask": ["type": "string", "description": "Subtask text to toggle (subtask)"],
                        // note
                        "content": ["type": "string", "description": "Text to append (note)"]
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
                Delete something. Use type to specify what to delete:
                - "idea": Delete an idea. Params: search
                - "folder": Delete a folder (ideas move to parent). Params: name
                - "subtask": Remove a subtask from an idea. Params: search (find idea), subtask (text match)
                """,
                "parameters": [
                    "type": "object",
                    "properties": [
                        "type": ["type": "string", "enum": ["idea", "folder", "subtask"], "description": "What to delete"],
                        "search": ["type": "string", "description": "Text to find the idea (idea/subtask)"],
                        "name": ["type": "string", "description": "Folder name (folder)"],
                        "subtask": ["type": "string", "description": "Subtask text to remove (subtask)"]
                    ] as [String: Any],
                    "required": ["type"]
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

        guard let type = args["type"] as? String else {
            // Backwards compat: route old tool names directly
            return await executeLegacy(name: name, args: args, modelContext: modelContext, ideasViewModel: ideasViewModel)
        }

        switch name {
        case "create":
            return await executeCreate(type: type, args: args, modelContext: modelContext, ideasViewModel: ideasViewModel)
        case "read":
            return executeRead(type: type, args: args, modelContext: modelContext)
        case "update":
            return await executeUpdate(type: type, args: args, modelContext: modelContext, ideasViewModel: ideasViewModel)
        case "delete":
            return executeDelete(type: type, args: args, modelContext: modelContext)
        default:
            return await executeLegacy(name: name, args: args, modelContext: modelContext, ideasViewModel: ideasViewModel)
        }
    }

    // MARK: - Create

    @MainActor
    private static func executeCreate(
        type: String,
        args: [String: Any],
        modelContext: ModelContext,
        ideasViewModel: IdeasViewModel?
    ) async -> String {
        switch type {
        case "idea":
            return await createIdea(args: args, modelContext: modelContext, ideasViewModel: ideasViewModel)
        case "folder":
            return createFolder(args: args, modelContext: modelContext)
        case "subtask":
            return createSubtask(args: args, modelContext: modelContext)
        case "update":
            return createUpdate(args: args, modelContext: modelContext)
        case "note":
            return createNote(args: args, modelContext: modelContext)
        default:
            return "{\"error\": \"unknown create type: \(type). Use: idea, folder, subtask, update, note\"}"
        }
    }

    @MainActor
    private static func createIdea(
        args: [String: Any],
        modelContext: ModelContext,
        ideasViewModel: IdeasViewModel?
    ) async -> String {
        guard let text = args["text"] as? String, !text.isEmpty else {
            return "{\"error\": \"missing 'text'\"}"
        }

        let idea = Idea(text: text)
        idea.positionX = 300 + Double.random(in: -100...100)
        idea.positionY = 400 + Double.random(in: -100...100)

        if let s = args["dueDate"] as? String { idea.dueDate = parseDateString(s) }
        if let s = args["dueTime"] as? String, isValidTime(s) { idea.dueTime = s }
        if let s = args["recurring"] as? String, Idea.RecurringPattern(rawValue: s) != nil { idea.recurringPattern = s }
        if let s = args["priority"] as? String, let p = Idea.Priority(fromString: s) { idea.priorityLevel = p }
        if let s = args["folder"] as? String, !s.isEmpty, let f = findFolder(matching: s, in: modelContext) { idea.folder = f }

        modelContext.insert(idea)
        try? modelContext.save()

        if let vm = ideasViewModel {
            Task { await vm.tagIdea(idea) }
        }

        var msg = "Created idea: \(text)"
        if let d = idea.formattedDueDate { msg += " (due \(d))" }
        if let r = idea.recurringPattern { msg += " [repeats \(r)]" }
        if let f = idea.folder { msg += " [folder: \(f.name)]" }
        return jsonResult(["success": true, "message": msg])
    }

    @MainActor
    private static func createFolder(args: [String: Any], modelContext: ModelContext) -> String {
        guard let name = args["name"] as? String, !name.isEmpty else {
            return "{\"error\": \"missing 'name'\"}"
        }

        var parentFolder: Folder? = nil
        if let parentName = args["parent"] as? String, !parentName.isEmpty {
            parentFolder = findFolder(matching: parentName, in: modelContext)
            if parentFolder == nil { return jsonResult(["error": "parent folder '\(parentName)' not found"]) }
        }

        let icon = args["icon"] as? String ?? "folder"
        let colorHex = args["color"] as? String ?? ""

        let folder = Folder(name: name, icon: icon, colorHex: colorHex, parent: parentFolder)
        modelContext.insert(folder)
        try? modelContext.save()

        var msg = "Created folder: \(name)"
        if let p = parentFolder { msg += " inside \(p.name)" }
        return jsonResult(["success": true, "message": msg])
    }

    @MainActor
    private static func createSubtask(args: [String: Any], modelContext: ModelContext) -> String {
        guard let search = args["search"] as? String, !search.isEmpty else { return "{\"error\": \"missing 'search'\"}" }
        guard let subtasks = args["subtasks"] as? [String], !subtasks.isEmpty else { return "{\"error\": \"missing 'subtasks'\"}" }

        let result = findIdea(matching: search, in: modelContext)
        guard let idea = result.idea else { return result.error! }

        for s in subtasks { idea.addSubtask(s) }
        try? modelContext.save()
        return jsonResult(["success": true, "message": "Added \(subtasks.count) subtask(s) to: \(idea.text)"])
    }

    @MainActor
    private static func createUpdate(args: [String: Any], modelContext: ModelContext) -> String {
        guard let search = args["search"] as? String, !search.isEmpty else { return "{\"error\": \"missing 'search'\"}" }
        guard let text = args["text"] as? String, !text.isEmpty else { return "{\"error\": \"missing 'text'\"}" }

        let result = findIdea(matching: search, in: modelContext)
        guard let idea = result.idea else { return result.error! }

        idea.addUpdate(text)
        try? modelContext.save()
        return jsonResult(["success": true, "message": "Added update to: \(idea.text)"])
    }

    @MainActor
    private static func createNote(args: [String: Any], modelContext: ModelContext) -> String {
        guard let search = args["search"] as? String, !search.isEmpty else { return "{\"error\": \"missing 'search'\"}" }
        guard let content = args["content"] as? String else { return "{\"error\": \"missing 'content'\"}" }

        let result = findIdea(matching: search, in: modelContext)
        guard let idea = result.idea else { return result.error! }

        idea.attributedNotes = AttributedString(content)
        try? modelContext.save()
        return jsonResult(["success": true, "message": "Notes written for: \(idea.text) (\(content.count) chars)"])
    }

    // MARK: - Read

    @MainActor
    private static func executeRead(type: String, args: [String: Any], modelContext: ModelContext) -> String {
        switch type {
        case "ideas":
            return readIdeas(args: args, modelContext: modelContext)
        case "folders":
            return readFolders(modelContext: modelContext)
        case "notes":
            return readNotes(args: args, modelContext: modelContext)
        default:
            return "{\"error\": \"unknown read type: \(type). Use: ideas, folders, notes\"}"
        }
    }

    @MainActor
    static func readIdeas(args: [String: Any], modelContext: ModelContext) -> String {
        guard let query = args["query"] as? String, !query.isEmpty else {
            return "{\"error\": \"missing 'query'\"}"
        }

        let descriptor = FetchDescriptor<Idea>(sortBy: [SortDescriptor(\Idea.createdAt, order: .reverse)])
        guard let allIdeas = try? modelContext.fetch(descriptor) else { return "{\"results\": [], \"count\": 0}" }

        let lowQ = query.lowercased()
        var valid = allIdeas.filter { $0.modelContext != nil }

        if let folderName = args["folder"] as? String, !folderName.isEmpty,
           let folder = findFolder(matching: folderName, in: modelContext) {
            let ids = Set(folder.allIdeas.map { $0.persistentModelID })
            valid = valid.filter { ids.contains($0.persistentModelID) }
        }

        let matches = valid.filter { idea in
            idea.text.lowercased().contains(lowQ)
            || idea.tags.contains(where: { $0.lowercased().contains(lowQ) })
            || idea.category.lowercased().contains(lowQ)
            || (idea.folder?.name.lowercased().contains(lowQ) ?? false)
        }

        let results = matches.prefix(20).map { idea -> [String: Any] in
            var r: [String: Any] = [
                "text": idea.text, "tags": idea.tags, "category": idea.category,
                "created": idea.createdAt.formatted(.dateTime.month().day().hour().minute()),
                "connections": idea.allLinks.count, "done": idea.isDone
            ]
            if let d = idea.formattedDueDate { r["dueDate"] = d }
            if let rec = idea.recurringPattern { r["recurring"] = rec }
            if !idea.updates.isEmpty { r["updates"] = idea.parsedUpdates.map { "\($0.date.formatted(.dateTime.month(.abbreviated).day().hour().minute())): \($0.text)" } }
            if !idea.subtasks.isEmpty { r["subtasks"] = idea.parsedSubtasks.map { ($0.isDone ? "[x] " : "[ ] ") + $0.text } }
            if idea.priority > 0 { r["priority"] = idea.priorityLevel.label }
            if let f = idea.folder { r["folder"] = f.breadcrumb }
            return r
        }

        let response: [String: Any] = ["results": results, "count": matches.count, "showing": min(matches.count, 20)]
        if let data = try? JSONSerialization.data(withJSONObject: response), let json = String(data: data, encoding: .utf8) { return json }
        return "{\"results\": [], \"count\": 0}"
    }

    @MainActor
    static func readFolders(modelContext: ModelContext) -> String {
        let descriptor = FetchDescriptor<Folder>()
        guard let all = try? modelContext.fetch(descriptor) else { return "{\"folders\": []}" }

        let roots = all.filter { $0.parent == nil }.sorted { $0.name < $1.name }

        func tree(_ f: Folder) -> [String: Any] {
            var d: [String: Any] = ["name": f.name, "icon": f.icon, "ideaCount": f.ideas.count, "totalIdeas": f.allIdeas.count, "path": f.breadcrumb]
            if !f.colorHex.isEmpty { d["color"] = f.colorHex }
            if !f.children.isEmpty { d["children"] = f.sortedChildren.map { tree($0) } }
            return d
        }

        let result: [String: Any] = ["folders": roots.map { tree($0) }, "totalFolders": all.count]
        if let data = try? JSONSerialization.data(withJSONObject: result), let json = String(data: data, encoding: .utf8) { return json }
        return "{\"folders\": []}"
    }

    @MainActor
    private static func readNotes(args: [String: Any], modelContext: ModelContext) -> String {
        guard let search = args["search"] as? String, !search.isEmpty else { return "{\"error\": \"missing 'search'\"}" }

        let result = findIdea(matching: search, in: modelContext)
        guard let idea = result.idea else { return result.error! }

        let text = String(idea.attributedNotes.characters)
        let response: [String: Any] = [
            "idea": idea.text,
            "notes": text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "(empty)" : text
        ]
        if let data = try? JSONSerialization.data(withJSONObject: response), let json = String(data: data, encoding: .utf8) { return json }
        return "{\"idea\": \"unknown\", \"notes\": \"(empty)\"}"
    }

    // MARK: - Update

    @MainActor
    private static func executeUpdate(
        type: String,
        args: [String: Any],
        modelContext: ModelContext,
        ideasViewModel: IdeasViewModel?
    ) async -> String {
        switch type {
        case "idea":
            return await updateIdea(args: args, modelContext: modelContext, ideasViewModel: ideasViewModel)
        case "folder":
            return updateFolder(args: args, modelContext: modelContext)
        case "subtask":
            return updateSubtask(args: args, modelContext: modelContext)
        case "note":
            return updateNote(args: args, modelContext: modelContext)
        default:
            return "{\"error\": \"unknown update type: \(type). Use: idea, folder, subtask, note\"}"
        }
    }

    @MainActor
    private static func updateIdea(
        args: [String: Any],
        modelContext: ModelContext,
        ideasViewModel: IdeasViewModel?
    ) async -> String {
        guard let search = args["search"] as? String, !search.isEmpty else { return "{\"error\": \"missing 'search'\"}" }

        let result = findIdea(matching: search, in: modelContext)
        guard let idea = result.idea else { return result.error! }

        var changes: [String] = []

        if let v = args["newText"] as? String { idea.text = v; changes.append("text") }
        if let v = args["newTags"] as? [String] { idea.tags = v; changes.append("tags") }
        if let v = args["newCategory"] as? String { idea.category = v; changes.append("category") }
        if let v = args["dueDate"] as? String {
            idea.dueDate = v.lowercased() == "none" ? nil : parseDateString(v)
            changes.append("dueDate")
        }
        if let v = args["dueTime"] as? String {
            idea.dueTime = v.lowercased() == "none" ? nil : (isValidTime(v) ? v : idea.dueTime)
            changes.append("dueTime")
        }
        if let v = args["recurring"] as? String {
            if v.lowercased() == "none" { idea.recurringPattern = nil }
            else if Idea.RecurringPattern(rawValue: v) != nil { idea.recurringPattern = v }
            changes.append("recurring")
        }
        if let v = args["priority"] as? String, let p = Idea.Priority(fromString: v) {
            idea.priorityLevel = p; changes.append("priority")
        }
        if let v = args["folder"] as? String {
            if v.lowercased() == "none" { idea.folder = nil; changes.append("folder") }
            else if let f = findFolder(matching: v, in: modelContext) { idea.folder = f; changes.append("folder") }
            else {
                let available = (try? modelContext.fetch(FetchDescriptor<Folder>()))?.map { $0.breadcrumb } ?? []
                return jsonResult(["error": "folder '\(v)' not found", "availableFolders": available])
            }
        }
        if let v = args["done"] as? Bool {
            idea.isDone = v; changes.append("done")
        }

        try? modelContext.save()

        let contentFields: Set<String> = ["text", "tags", "category"]
        if !changes.isEmpty && !contentFields.isDisjoint(with: changes), let vm = ideasViewModel {
            await vm.refreshConnections(for: idea)
        }

        if changes.isEmpty { return jsonResult(["success": true, "message": "No changes for: \(idea.text)"]) }
        return jsonResult(["success": true, "message": "Updated \(changes.joined(separator: ", ")) for: \(idea.text)"])
    }

    @MainActor
    private static func updateFolder(args: [String: Any], modelContext: ModelContext) -> String {
        guard let name = args["name"] as? String, !name.isEmpty else { return "{\"error\": \"missing 'name'\"}" }
        guard let folder = findFolder(matching: name, in: modelContext) else { return jsonResult(["error": "folder '\(name)' not found"]) }

        var changes: [String] = []
        if let v = args["newName"] as? String { folder.name = v; changes.append("name") }
        if let v = args["newIcon"] as? String { folder.icon = v; changes.append("icon") }
        if let v = args["newColor"] as? String { folder.colorHex = v; changes.append("color") }
        if let v = args["newParent"] as? String {
            if v.lowercased() == "none" { folder.parent = nil }
            else if let p = findFolder(matching: v, in: modelContext) { folder.parent = p }
            changes.append("parent")
        }

        try? modelContext.save()
        if changes.isEmpty { return jsonResult(["success": true, "message": "No changes for folder: \(folder.name)"]) }
        return jsonResult(["success": true, "message": "Updated \(changes.joined(separator: ", ")) for folder: \(folder.name)"])
    }

    @MainActor
    private static func updateSubtask(args: [String: Any], modelContext: ModelContext) -> String {
        guard let search = args["search"] as? String, !search.isEmpty else { return "{\"error\": \"missing 'search'\"}" }
        guard let subtaskQ = args["subtask"] as? String, !subtaskQ.isEmpty else { return "{\"error\": \"missing 'subtask'\"}" }

        let result = findIdea(matching: search, in: modelContext)
        guard let idea = result.idea else { return result.error! }

        let lc = subtaskQ.lowercased()
        guard let idx = idea.subtasks.firstIndex(where: { $0.lowercased().contains(lc) }) else {
            return "{\"error\": \"no subtask matching '\(subtaskQ)'\"}"
        }

        idea.toggleSubtask(at: idx)
        try? modelContext.save()
        let parsed = idea.parsedSubtasks[idx]
        return jsonResult(["success": true, "message": "Toggled '\(parsed.text)' to \(parsed.isDone ? "done" : "todo")"])
    }

    @MainActor
    private static func updateNote(args: [String: Any], modelContext: ModelContext) -> String {
        guard let search = args["search"] as? String, !search.isEmpty else { return "{\"error\": \"missing 'search'\"}" }
        guard let content = args["content"] as? String else { return "{\"error\": \"missing 'content'\"}" }

        let result = findIdea(matching: search, in: modelContext)
        guard let idea = result.idea else { return result.error! }

        var current = idea.attributedNotes
        current.append(AttributedString("\n\n" + content))
        idea.attributedNotes = current
        try? modelContext.save()
        return jsonResult(["success": true, "message": "Appended to notes for: \(idea.text)"])
    }

    // MARK: - Delete

    @MainActor
    private static func executeDelete(type: String, args: [String: Any], modelContext: ModelContext) -> String {
        switch type {
        case "idea":
            return deleteIdea(args: args, modelContext: modelContext)
        case "folder":
            return deleteFolder(args: args, modelContext: modelContext)
        case "subtask":
            return deleteSubtask(args: args, modelContext: modelContext)
        default:
            return "{\"error\": \"unknown delete type: \(type). Use: idea, folder, subtask\"}"
        }
    }

    @MainActor
    private static func deleteIdea(args: [String: Any], modelContext: ModelContext) -> String {
        guard let search = args["search"] as? String, !search.isEmpty else { return "{\"error\": \"missing 'search'\"}" }

        let result = findIdea(matching: search, in: modelContext)
        guard let idea = result.idea else { return result.error! }

        let text = idea.text
        modelContext.delete(idea)
        try? modelContext.save()
        return jsonResult(["success": true, "message": "Deleted idea: \(text)"])
    }

    @MainActor
    private static func deleteFolder(args: [String: Any], modelContext: ModelContext) -> String {
        guard let name = args["name"] as? String, !name.isEmpty else { return "{\"error\": \"missing 'name'\"}" }
        guard let folder = findFolder(matching: name, in: modelContext) else { return jsonResult(["error": "folder '\(name)' not found"]) }

        let folderName = folder.name
        let count = folder.ideas.count
        for idea in folder.ideas { idea.folder = folder.parent }
        for child in folder.children { child.parent = folder.parent }
        modelContext.delete(folder)
        try? modelContext.save()
        return jsonResult(["success": true, "message": "Deleted folder '\(folderName)'. \(count) idea(s) moved to parent."])
    }

    @MainActor
    private static func deleteSubtask(args: [String: Any], modelContext: ModelContext) -> String {
        guard let search = args["search"] as? String, !search.isEmpty else { return "{\"error\": \"missing 'search'\"}" }
        guard let subtaskQ = args["subtask"] as? String, !subtaskQ.isEmpty else { return "{\"error\": \"missing 'subtask'\"}" }

        let result = findIdea(matching: search, in: modelContext)
        guard let idea = result.idea else { return result.error! }

        let lc = subtaskQ.lowercased()
        guard let idx = idea.subtasks.firstIndex(where: { $0.lowercased().contains(lc) }) else {
            return "{\"error\": \"no subtask matching '\(subtaskQ)'\"}"
        }

        let text = idea.parsedSubtasks[idx].text
        idea.removeSubtask(at: idx)
        try? modelContext.save()
        return jsonResult(["success": true, "message": "Removed subtask '\(text)' from: \(idea.text)"])
    }

    // MARK: - Legacy Compat (routes old tool names)

    @MainActor
    private static func executeLegacy(
        name: String,
        args: [String: Any],
        modelContext: ModelContext,
        ideasViewModel: IdeasViewModel?
    ) async -> String {
        switch name {
        case "create_idea":
            return await createIdea(args: args, modelContext: modelContext, ideasViewModel: ideasViewModel)
        case "search_ideas":
            return readIdeas(args: args, modelContext: modelContext)
        case "update_idea":
            return await updateIdea(args: args, modelContext: modelContext, ideasViewModel: ideasViewModel)
        case "delete_idea":
            return deleteIdea(args: args, modelContext: modelContext)
        case "add_update":
            // Remap: "update" field -> "text" field
            var remapped = args
            if let u = args["update"] as? String { remapped["text"] = u }
            return createUpdate(args: remapped, modelContext: modelContext)
        case "add_subtask":
            return createSubtask(args: args, modelContext: modelContext)
        case "toggle_subtask":
            return updateSubtask(args: args, modelContext: modelContext)
        case "remove_subtask":
            return deleteSubtask(args: args, modelContext: modelContext)
        case "write_notes":
            return createNote(args: args, modelContext: modelContext)
        case "read_notes":
            return readNotes(args: args, modelContext: modelContext)
        case "create_folder":
            return createFolder(args: args, modelContext: modelContext)
        case "list_folders":
            return readFolders(modelContext: modelContext)
        case "move_to_folder":
            var remapped = args
            remapped["type"] = "idea"
            return await updateIdea(args: remapped, modelContext: modelContext, ideasViewModel: ideasViewModel)
        case "delete_folder":
            return deleteFolder(args: args, modelContext: modelContext)
        default:
            return "{\"error\": \"unknown tool: \(name)\"}"
        }
    }

    // MARK: - JSON Helper

    static func jsonResult(_ dict: [String: Any]) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: dict),
           let json = String(data: data, encoding: .utf8) { return json }
        return "{\"error\": \"serialization failed\"}"
    }

    // MARK: - Shared Helpers

    @MainActor
    private static func findIdea(matching search: String, in modelContext: ModelContext) -> (idea: Idea?, error: String?) {
        let descriptor = FetchDescriptor<Idea>()
        guard let allIdeas = try? modelContext.fetch(descriptor) else {
            return (nil, "{\"error\": \"could not fetch ideas\"}")
        }
        let lc = search.lowercased()
        guard let idea = allIdeas.first(where: { $0.text.lowercased().contains(lc) }) else {
            return (nil, jsonResult(["error": "no idea found matching '\(search)'"]))
        }
        return (idea, nil)
    }

    @MainActor
    static func findFolder(matching name: String, in modelContext: ModelContext) -> Folder? {
        let descriptor = FetchDescriptor<Folder>()
        guard let folders = try? modelContext.fetch(descriptor) else { return nil }
        let lc = name.lowercased()
        // Exact breadcrumb match first (e.g. "School / Projects"), then exact name, then partial name
        return folders.first(where: { $0.breadcrumb.lowercased() == lc })
            ?? folders.first(where: { $0.name.lowercased() == lc })
            ?? folders.first(where: { $0.name.lowercased().contains(lc) })
    }

    // MARK: - Date Helpers

    private static let dateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt
    }()

    static func parseDateString(_ str: String) -> Date? {
        guard let date = dateFormatter.date(from: str) else { return nil }
        return Calendar.current.startOfDay(for: date)
    }

    private static func isValidTime(_ str: String) -> Bool {
        let pattern = #"^\d{2}:\d{2}$"#
        return str.range(of: pattern, options: .regularExpression) != nil
    }
}
