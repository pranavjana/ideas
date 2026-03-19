import Foundation
import SwiftData

extension AppSchemaV1 {
@Model
final class UserProfile {
    var bio: String
    var verifiedTags: [String]
    var openaiAPIKey: String
    var tagColors: [String: String] = [:]
    var appleCalendarSyncEnabled: Bool

    init() {
        self.bio = ""
        self.verifiedTags = []
        self.openaiAPIKey = ""
        self.tagColors = [:]
        self.appleCalendarSyncEnabled = false
    }
}
}
