import Foundation
import SwiftData

extension AppSchemaV1 {
@Model
final class Idea {
    var text: String
    var tags: [String]
    var category: String
    var createdAt: Date
    var isProcessing: Bool
    var isDone: Bool = false
    var updates: [String] = []
    var subtasks: [String] = []
    var priority: Int = 0
    var dueDate: Date? = nil
    var dueTime: String? = nil
    var durationMinutes: Int? = nil
    var recurringPattern: String? = nil
    var appleCalendarEventIdentifier: String? = nil
    var notesData: Data = Data()
    var chatData: Data = Data()
    var positionX: Double
    var positionY: Double
    var folder: Folder?

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
        self.priority = 0
        self.dueDate = nil
        self.dueTime = nil
        self.durationMinutes = nil
        self.recurringPattern = nil
        self.appleCalendarEventIdentifier = nil
        self.notesData = Data()
        self.chatData = Data()
        self.positionX = 0
        self.positionY = 0
        self.folder = nil
        self.linkedTo = []
        self.linkedFrom = []
    }
}
}
