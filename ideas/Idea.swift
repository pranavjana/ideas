import Foundation
import SwiftUI
import SwiftData

@Model
class Idea {
    var text: String
    var tags: [String]
    var category: String
    var createdAt: Date
    var isProcessing: Bool
    var isDone: Bool = false

    // Updates log — each entry is "ISO8601|||update text"
    var updates: [String] = []

    // Subtasks — each entry is "done|||text" or "todo|||text"
    var subtasks: [String] = []

    // Priority: 0=none, 1=urgent, 2=high, 3=medium, 4=low
    var priority: Int = 0

    // Scheduling
    var dueDate: Date? = nil
    var dueTime: String? = nil          // "HH:mm" or nil for all-day
    var recurringPattern: String? = nil  // "daily"|"weekly"|"monthly"|"weekdays"|"yearly"

    // Rich text notes (encoded AttributedString)
    var notesData: Data = Data()

    // Persisted AI chat messages (encoded [IdeaChatMessage])
    var chatData: Data = Data()

    // Position on graph canvas
    var positionX: Double
    var positionY: Double

    // Folder organization
    var folder: Folder?

    // Graph relationships for mindmap
    @Relationship(inverse: \Idea.linkedFrom)
    var linkedTo: [Idea]
    var linkedFrom: [Idea]

    init(text: String) {
        self.text = text
        self.tags = []
        self.category = ""
        self.createdAt = Date()
        self.isProcessing = true
        self.isDone = false
        self.updates = []
        self.subtasks = []
        self.notesData = Data()
        self.chatData = Data()
        self.priority = 0
        self.dueDate = nil
        self.dueTime = nil
        self.recurringPattern = nil
        self.folder = nil
        self.positionX = 0
        self.positionY = 0
        self.linkedTo = []
        self.linkedFrom = []
    }

    static let demoTag = "_demo"

    var visibleTags: [String] { tags.filter { $0 != Self.demoTag } }
    var isDemo: Bool { tags.contains(Self.demoTag) }

    func accentColor(from tagColors: [String: String]) -> Color? {
        guard let firstTag = tags.first,
              let hex = tagColors[firstTag], !hex.isEmpty else { return nil }
        return Color(hex: hex)
    }

    var allLinks: [Idea] {
        Array(Set(linkedTo + linkedFrom))
    }

    // MARK: - Updates

    private static let iso8601Formatter = ISO8601DateFormatter()
    private static let dueDateShortFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d"
        return fmt
    }()
    private static let dueDateLongFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d, yyyy"
        return fmt
    }()

    struct Update {
        let date: Date
        let text: String
    }

    var parsedUpdates: [Update] {
        updates.compactMap { entry in
            let parts = entry.components(separatedBy: "|||")
            guard parts.count == 2,
                  let date = Self.iso8601Formatter.date(from: parts[0]) else { return nil }
            return Update(date: date, text: parts[1])
        }
    }

    func addUpdate(_ text: String) {
        let timestamp = Self.iso8601Formatter.string(from: Date())
        updates.append("\(timestamp)|||\(text)")
    }

    // MARK: - Subtasks

    struct Subtask {
        let text: String
        let isDone: Bool
    }

    var parsedSubtasks: [Subtask] {
        subtasks.map { entry in
            if entry.hasPrefix("done|||") {
                return Subtask(text: String(entry.dropFirst(7)), isDone: true)
            } else if entry.hasPrefix("todo|||") {
                return Subtask(text: String(entry.dropFirst(7)), isDone: false)
            }
            return Subtask(text: entry, isDone: false)
        }
    }

    func addSubtask(_ text: String) {
        subtasks.append("todo|||\(text)")
    }

    func toggleSubtask(at index: Int) {
        guard index >= 0, index < subtasks.count else { return }
        let entry = subtasks[index]
        if entry.hasPrefix("done|||") {
            subtasks[index] = "todo|||" + entry.dropFirst(7)
        } else if entry.hasPrefix("todo|||") {
            subtasks[index] = "done|||" + entry.dropFirst(7)
        }
    }

    func removeSubtask(at index: Int) {
        guard index >= 0, index < subtasks.count else { return }
        subtasks.remove(at: index)
    }

    var subtaskProgress: (done: Int, total: Int) {
        let done = subtasks.filter { $0.hasPrefix("done|||") }.count
        return (done, subtasks.count)
    }

    // MARK: - Priority

    enum Priority: Int, CaseIterable {
        case none = 0, urgent = 1, high = 2, medium = 3, low = 4

        var label: String {
            switch self {
            case .none: return "none"
            case .urgent: return "urgent"
            case .high: return "high"
            case .medium: return "medium"
            case .low: return "low"
            }
        }

        var color: Color {
            switch self {
            case .none: return .white.opacity(0.2)
            case .urgent: return Color(red: 1.0, green: 0.3, blue: 0.3)
            case .high: return Color(red: 1.0, green: 0.55, blue: 0.2)
            case .medium: return Color(red: 1.0, green: 0.8, blue: 0.3)
            case .low: return Color(red: 0.5, green: 0.7, blue: 1.0)
            }
        }

        var icon: String {
            switch self {
            case .none: return ""
            case .urgent: return "exclamationmark.3"
            case .high: return "exclamationmark.2"
            case .medium: return "exclamationmark"
            case .low: return "minus"
            }
        }

        init?(fromString str: String) {
            switch str.lowercased() {
            case "urgent", "p1": self = .urgent
            case "high", "p2": self = .high
            case "medium", "p3": self = .medium
            case "low", "p4": self = .low
            case "none", "": self = .none
            default: return nil
            }
        }
    }

    var priorityLevel: Priority {
        get { Priority(rawValue: priority) ?? .none }
        set { priority = newValue.rawValue }
    }

    // MARK: - Recurring Pattern

    enum RecurringPattern: String, CaseIterable {
        case daily, weekly, monthly, weekdays, yearly
    }

    var recurring: RecurringPattern? {
        get { recurringPattern.flatMap { RecurringPattern(rawValue: $0) } }
        set { recurringPattern = newValue?.rawValue }
    }

    // MARK: - Due Date Helpers

    var dueDatetime: Date? {
        guard let dueDate else { return nil }
        guard let dueTime, dueTime.count == 5,
              let hour = Int(dueTime.prefix(2)),
              let minute = Int(dueTime.suffix(2)) else {
            return Calendar.current.startOfDay(for: dueDate)
        }
        return Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: dueDate)
    }

    enum DueStatus {
        case none, future, today, upcoming, overdue
    }

    var dueStatus: DueStatus {
        guard let dueDate else { return .none }
        let cal = Calendar.current
        let now = Date()
        let startOfToday = cal.startOfDay(for: now)
        let startOfDue = cal.startOfDay(for: dueDate)

        if startOfDue < startOfToday {
            return .overdue
        } else if cal.isDateInToday(dueDate) {
            return .today
        } else if let threeDaysOut = cal.date(byAdding: .day, value: 3, to: startOfToday), startOfDue < threeDaysOut {
            return .upcoming
        } else {
            return .future
        }
    }

    var formattedDueDate: String? {
        guard let dueDate else { return nil }
        let cal = Calendar.current

        var dateStr: String
        if cal.isDateInToday(dueDate) {
            dateStr = "today"
        } else if cal.isDateInTomorrow(dueDate) {
            dateStr = "tomorrow"
        } else if cal.isDateInYesterday(dueDate) {
            dateStr = "yesterday"
        } else {
            let fmt = cal.isDate(dueDate, equalTo: Date(), toGranularity: .year) ? Self.dueDateShortFormatter : Self.dueDateLongFormatter
            dateStr = fmt.string(from: dueDate)
        }

        if let dueTime {
            dateStr += " at \(dueTime)"
        }

        return dateStr
    }

    func nextDueDate() -> Date? {
        guard let dueDate, let pattern = recurring else { return nil }
        let cal = Calendar.current
        switch pattern {
        case .daily:
            return cal.date(byAdding: .day, value: 1, to: dueDate)
        case .weekly:
            return cal.date(byAdding: .weekOfYear, value: 1, to: dueDate)
        case .monthly:
            return cal.date(byAdding: .month, value: 1, to: dueDate)
        case .weekdays:
            var next = cal.date(byAdding: .day, value: 1, to: dueDate)!
            while cal.isDateInWeekend(next) {
                next = cal.date(byAdding: .day, value: 1, to: next)!
            }
            return next
        case .yearly:
            return cal.date(byAdding: .year, value: 1, to: dueDate)
        }
    }
}

extension Idea {
    /// Animated checkbox toggle with recurring-aware date advancement.
    func animatedToggleDone() {
        if recurring != nil && !isDone {
            withAnimation(.easeOut(duration: 0.15)) { isDone = true }
            if let next = nextDueDate() { dueDate = next }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                withAnimation(.easeOut(duration: 0.15)) { self.isDone = false }
            }
        } else {
            withAnimation(.easeOut(duration: 0.15)) { isDone.toggle() }
        }
    }
}

extension Idea.DueStatus {
    var color: Color {
        switch self {
        case .none: return .white.opacity(0.2)
        case .future: return .white.opacity(0.5)
        case .today: return Color(red: 0.4, green: 0.7, blue: 1.0)
        case .upcoming: return Color(red: 1.0, green: 0.75, blue: 0.3)
        case .overdue: return Color(red: 1.0, green: 0.4, blue: 0.4)
        }
    }
}
