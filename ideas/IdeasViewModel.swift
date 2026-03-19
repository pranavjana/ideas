import SwiftUI
import SwiftData

@MainActor
@Observable
class IdeasViewModel {
    private var modelContext: ModelContext
    private let cal = Calendar.current

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func addIdea(
        _ text: String,
        scheduledAt: Date? = nil,
        durationMinutes: Int? = nil,
        linkedAppleCalendarEventIdentifier: String? = nil,
        canvasSize: CGSize = CGSize(width: 600, height: 800)
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let idea = Idea(text: trimmed)
        idea.appleCalendarEventIdentifier = linkedAppleCalendarEventIdentifier
        if let scheduledAt {
            idea.dueDate = scheduledAt
            idea.dueTime = String(
                format: "%02d:%02d",
                cal.component(.hour, from: scheduledAt),
                cal.component(.minute, from: scheduledAt)
            )
            idea.durationMinutes = durationMinutes ?? 60
        }

        // Position around origin, spread out in a circle
        let existingCount = (try? modelContext.fetchCount(FetchDescriptor<Idea>())) ?? 0
        let angle = (2.0 * Double.pi * Double(existingCount)) / max(Double(existingCount + 1), 6.0) - Double.pi / 2
        let radius = max(200.0, Double(existingCount + 1) * 70.0)
        idea.positionX = radius * cos(angle) + Double.random(in: -20...20)
        idea.positionY = radius * sin(angle) + Double.random(in: -20...20)

        withAnimation(.easeOut(duration: 0.25)) {
            modelContext.insert(idea)
            try? modelContext.save()
        }

        // tagIdea automatically refreshes connections when done
        Task {
            await tagIdea(idea)
            let syncEnabled = fetchProfile()?.appleCalendarSyncEnabled ?? false
            AppleCalendarManager.shared.syncIdea(idea, enabled: syncEnabled)
        }
    }

    // MARK: - Profile

    private func fetchProfile() -> UserProfile? {
        let descriptor = FetchDescriptor<UserProfile>()
        return (try? modelContext.fetch(descriptor))?.first
    }

    // MARK: - Tagging

    /// Tags an idea via the API, then automatically refreshes its connections.
    func tagIdea(_ idea: Idea) async {
        guard let profile = fetchProfile(),
              !profile.openaiAPIKey.isEmpty else {
            withAnimation(.easeOut(duration: 0.3)) {
                idea.isProcessing = false
            }
            return
        }

        let bio = profile.bio
        let verifiedTags = profile.verifiedTags

        var systemPrompt: String
        if !verifiedTags.isEmpty {
            let tagList = verifiedTags.joined(separator: ", ")
            systemPrompt = """
            You tag, categorize, and lightly clean up short ideas. \
            Only use tags from this list: [\(tagList)]. \
            Pick exactly 1 primary tag. Use lowercase. \
            For category, pick the single best fitting tag from the list. \
            Think about the core topic, not surface keywords. \
            For cleanedText: fix typos, capitalize properly, and tighten phrasing while keeping the original meaning and voice. \
            Keep it concise — don't expand or add words unnecessarily. If the text is already clean, return it as-is.
            """
        } else {
            systemPrompt = """
            You tag, categorize, and lightly clean up short ideas. \
            Pick exactly 1 primary tag that describes the core topic (e.g. 'ml', 'finance', 'design', 'startup'). \
            Category should be a broad domain (e.g. 'tech', 'business', 'personal', 'academic', 'creative', 'career'). \
            Be concise. Use lowercase. Think about what the idea is really about, not just surface keywords. \
            For cleanedText: fix typos, capitalize properly, and tighten phrasing while keeping the original meaning and voice. \
            Keep it concise — don't expand or add words unnecessarily. If the text is already clean, return it as-is.
            """
        }

        if !bio.isEmpty {
            systemPrompt = "Context about the user: \(bio)\n\n" + systemPrompt
        }

        systemPrompt += "\n\nRespond with JSON: {\"tags\": [\"tag1\"], \"category\": \"category\", \"cleanedText\": \"cleaned version\"}"

        do {
            let result = try await OpenAIService.jsonCompletion(
                apiKey: profile.openaiAPIKey,
                messages: [
                    .init(role: "system", content: systemPrompt),
                    .init(role: "user", content: idea.text)
                ]
            )

            let tags = Array((result["tags"] as? [String] ?? []).prefix(1))
            let category = result["category"] as? String ?? ""
            let cleanedText = result["cleanedText"] as? String

            withAnimation(.easeOut(duration: 0.3)) {
                idea.tags = tags.map { $0.lowercased() }
                idea.category = category.lowercased()
                if let cleaned = cleanedText, !cleaned.isEmpty {
                    idea.text = cleaned
                }
                idea.isProcessing = false
            }
            try? modelContext.save()
        } catch {
            withAnimation(.easeOut(duration: 0.3)) {
                idea.isProcessing = false
            }
        }

        // Always refresh connections after any tag/content change
        await refreshConnections(for: idea)
    }

    // MARK: - Connections

    /// Clear existing links for an idea and re-evaluate all connections.
    func refreshConnections(for idea: Idea) async {
        idea.linkedTo.removeAll()
        idea.linkedFrom.removeAll()
        try? modelContext.save()
        await findConnections(for: idea)
    }

    private func findConnections(for newIdea: Idea) async {
        guard let profile = fetchProfile(),
              !profile.openaiAPIKey.isEmpty else { return }

        let descriptor = FetchDescriptor<Idea>()
        guard let allIdeas = try? modelContext.fetch(descriptor) else { return }

        let otherIdeas = allIdeas.filter { $0.persistentModelID != newIdea.persistentModelID }
        guard !otherIdeas.isEmpty else { return }

        // Build a numbered list of candidates for a single batched API call
        let candidates = otherIdeas.prefix(100) // cap to avoid token overflow
        var numberedList = ""
        for (i, idea) in candidates.enumerated() {
            numberedList += "\(i): \(idea.text)\n"
        }

        var systemPrompt = """
        You are given a TARGET idea and a numbered list of OTHER ideas. \
        Return ONLY the numbers of ideas that are DEEPLY and SPECIFICALLY related to the target. \
        Two ideas are related ONLY if one directly builds on, contradicts, or is a concrete dependency of the other. \
        Sharing the same broad topic or tag is NOT enough. \
        Default to empty — most ideas are NOT related. \
        Respond with JSON: {"related": [0, 3, 7]} or {"related": []} if none are related.
        """
        if !profile.bio.isEmpty {
            systemPrompt = "Context about the user: \(profile.bio)\n\n" + systemPrompt
        }

        let userPrompt = "TARGET: \(newIdea.text)\n\nOTHER IDEAS:\n\(numberedList)"

        do {
            let result = try await OpenAIService.jsonCompletion(
                apiKey: profile.openaiAPIKey,
                messages: [
                    .init(role: "system", content: systemPrompt),
                    .init(role: "user", content: userPrompt)
                ]
            )

            // Parse related indices
            let relatedIndices: [Int]
            if let indices = result["related"] as? [Int] {
                relatedIndices = indices
            } else if let indices = result["related"] as? [Double] {
                // JSON numbers sometimes decode as Double
                relatedIndices = indices.map { Int($0) }
            } else {
                relatedIndices = []
            }

            let candidateArray = Array(candidates)
            for index in relatedIndices {
                guard index >= 0, index < candidateArray.count else { continue }
                let other = candidateArray[index]
                let otherID = other.persistentModelID
                // Avoid duplicates
                let alreadyLinkedTo = newIdea.linkedTo.contains(where: { $0.persistentModelID == otherID })
                let alreadyLinkedFrom = newIdea.linkedFrom.contains(where: { $0.persistentModelID == otherID })
                if !alreadyLinkedTo && !alreadyLinkedFrom {
                    withAnimation(.easeOut(duration: 0.3)) {
                        newIdea.linkedTo.append(other)
                    }
                }
            }
        } catch {
            // Skip on failure
        }

        try? modelContext.save()
    }
}
