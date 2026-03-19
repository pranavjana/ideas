import Foundation
import SwiftData

extension AppSchemaV1 {
@Model
final class Folder {
    var name: String
    var icon: String
    var colorHex: String
    var createdAt: Date
    var sortOrder: Int
    var parent: Folder?

    @Relationship(deleteRule: .cascade, inverse: \Folder.parent)
    var children: [Folder]

    @Relationship(inverse: \Idea.folder)
    var ideas: [Idea]

    init(name: String, icon: String = "folder", colorHex: String = "", parent: Folder? = nil) {
        self.name = name
        self.icon = icon
        self.colorHex = colorHex
        self.createdAt = Date()
        self.sortOrder = 0
        self.parent = parent
        self.children = []
        self.ideas = []
    }
}
}
