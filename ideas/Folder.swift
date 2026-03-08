import Foundation
import SwiftUI
import SwiftData

@Model
class Folder {
    var name: String
    var icon: String          // SF Symbol name
    var colorHex: String      // hex color for the folder
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

    var color: Color? {
        guard !colorHex.isEmpty else { return nil }
        return Color(hex: colorHex)
    }

    /// All ideas in this folder and all descendant folders.
    var allIdeas: [Idea] {
        var result = ideas
        for child in children {
            result.append(contentsOf: child.allIdeas)
        }
        return result
    }

    /// Full path from root, e.g. "School / CS 101 / Projects"
    var breadcrumb: String {
        var parts: [String] = [name]
        var current = parent
        while let p = current {
            parts.insert(p.name, at: 0)
            current = p.parent
        }
        return parts.joined(separator: " / ")
    }

    /// Depth from root (0 = top-level)
    var depth: Int {
        var d = 0
        var current = parent
        while let p = current {
            d += 1
            current = p.parent
        }
        return d
    }

    /// Sorted children by sortOrder then name
    var sortedChildren: [Folder] {
        children.sorted {
            if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}
