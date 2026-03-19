import SwiftUI
import SwiftData
import EventKit

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var ideas: [Idea]
    @Query private var profiles: [UserProfile]
    @ObservedObject private var appleCalendarManager = AppleCalendarManager.shared
    #if os(macOS)
    @StateObject private var updaterViewModel = UpdaterViewModel()
    #endif
    @State private var isGenerating = false
    @State private var newTag = ""
    @State private var bioText = ""
    @State private var tags: [String] = []
    @State private var tagColors: [String: String] = [:]
    @State private var errorMessage: String?
    @State private var apiKeyText = ""
    @State private var didLoad = false

    private var profile: UserProfile? {
        profiles.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            Text("settings")
                .font(.custom("Switzer-Medium", size: 18))
                .foregroundStyle(Color.fg.opacity(0.7))
                .padding(.horizontal, 32)
                .padding(.top, 24)
                .padding(.bottom, 24)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // About you section
                    sectionHeader("about you")

                    Text("tell the ai about yourself — what you study, what you do, what you're into. it uses this as context for everything.")
                        .font(.custom("Switzer-Light", size: 12))
                        .foregroundStyle(Color.fg.opacity(0.25))
                        .lineSpacing(4)

                    TextEditor(text: $bioText)
                        .font(.custom("Switzer-Regular", size: 14))
                        .foregroundStyle(Color.fg.opacity(0.8))
                        .scrollContentBackground(.hidden)
                        .padding(12)
                        .frame(minHeight: 120)
                        .background(Color.fg.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .onChange(of: bioText) {
                            ensureProfile().bio = bioText
                            try? modelContext.save()
                        }

                    // Generate tags
                    HStack {
                        Button {
                            Task { await generateTags() }
                        } label: {
                            HStack(spacing: 6) {
                                if isGenerating {
                                    ProgressView()
                                        .scaleEffect(0.6)
                                        .frame(width: 12, height: 12)
                                } else {
                                    Image(systemName: "sparkles")
                                        .font(.system(size: 11))
                                }
                                Text(isGenerating ? "generating..." : "generate tags")
                                    .font(.custom("Switzer-Medium", size: 13))
                            }
                            .foregroundStyle(Color.fg.opacity(!bioText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.6 : 0.2))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.fg.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .disabled(bioText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isGenerating)
                    }

                    // Error message
                    if let error = errorMessage {
                        Text(error)
                            .font(.custom("Switzer-Regular", size: 12))
                            .foregroundStyle(Color.red.opacity(0.7))
                    }

                    // Tags section
                    if !tags.isEmpty {
                        sectionHeader("your tags")

                        Text("click the color dot to assign a color to each tag.")
                            .font(.custom("Switzer-Light", size: 12))
                            .foregroundStyle(Color.fg.opacity(0.25))

                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(tags, id: \.self) { tag in
                                TagColorRow(
                                    tag: tag,
                                    color: Binding(
                                        get: { Color.accent(hex: tagColors[tag] ?? "") ?? .fg },
                                        set: { newColor in
                                            tagColors[tag] = newColor.toHex()
                                            ensureProfile().tagColors = tagColors
                                            try? modelContext.save()
                                        }
                                    ),
                                    hasColor: tagColors[tag] != nil && !tagColors[tag]!.isEmpty,
                                    onClearColor: {
                                        tagColors.removeValue(forKey: tag)
                                        ensureProfile().tagColors = tagColors
                                        try? modelContext.save()
                                    },
                                    onRemove: {
                                        withAnimation(.easeOut(duration: 0.2)) {
                                            tags.removeAll { $0 == tag }
                                            tagColors.removeValue(forKey: tag)
                                        }
                                    }
                                )
                            }
                        }

                        // Add custom tag
                        HStack(spacing: 8) {
                            TextField("add tag...", text: $newTag)
                                .textFieldStyle(.plain)
                                .font(.custom("Switzer-Regular", size: 13))
                                .foregroundStyle(Color.fg.opacity(0.7))
                                .onSubmit {
                                    addCustomTag()
                                }

                            if !newTag.isEmpty {
                                Button("add") {
                                    addCustomTag()
                                }
                                .buttonStyle(.plain)
                                .font(.custom("Switzer-Regular", size: 12))
                                .foregroundStyle(Color.fg.opacity(0.4))
                            }
                        }
                        .padding(.top, 4)
                    }

                    // Divider
                    Rectangle()
                        .fill(Color.fg.opacity(0.06))
                        .frame(height: 1)
                        .padding(.vertical, 8)

                    // Updates section
                    #if os(macOS)
                    sectionHeader("updates")

                    HStack(spacing: 12) {
                        Button {
                            updaterViewModel.checkForUpdates()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 11))
                                Text("check for updates")
                                    .font(.custom("Switzer-Medium", size: 13))
                            }
                            .foregroundStyle(Color.fg.opacity(0.6))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.fg.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .disabled(!updaterViewModel.canCheckForUpdates)

                        Text("v\(Self.appVersion)")
                            .font(.custom("Switzer-Light", size: 12))
                            .foregroundStyle(Color.fg.opacity(0.2))
                    }

                    Rectangle()
                        .fill(Color.fg.opacity(0.06))
                        .frame(height: 1)
                        .padding(.vertical, 8)
                    #endif

                    sectionHeader("apple calendar")

                    Text("show Apple Calendar events beside ideas in the calendar view, and sync timed ideas to Apple Calendar.")
                        .font(.custom("Switzer-Light", size: 12))
                        .foregroundStyle(Color.fg.opacity(0.25))
                        .lineSpacing(4)

                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Circle()
                                .fill(calendarStatusColor)
                                .frame(width: 8, height: 8)

                            Text(calendarStatusText)
                                .font(.custom("Switzer-Regular", size: 13))
                                .foregroundStyle(Color.fg.opacity(0.6))
                        }

                        HStack(spacing: 12) {
                            Button {
                                Task {
                                    let granted = await appleCalendarManager.requestAccess()
                                    if granted, ensureProfile().appleCalendarSyncEnabled {
                                        syncTimedIdeasToAppleCalendar()
                                    }
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: appleCalendarManager.hasFullAccess ? "arrow.clockwise" : "link")
                                        .font(.system(size: 11))
                                    Text(appleCalendarManager.hasFullAccess ? "refresh calendar access" : "connect to apple calendar")
                                        .font(.custom("Switzer-Medium", size: 13))
                                }
                                .foregroundStyle(Color.fg.opacity(0.6))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Color.fg.opacity(0.06))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)

                            Toggle(isOn: Binding(
                                get: { profile?.appleCalendarSyncEnabled ?? false },
                                set: { newValue in
                                    ensureProfile().appleCalendarSyncEnabled = newValue
                                    try? modelContext.save()
                                    if newValue {
                                        if appleCalendarManager.hasFullAccess {
                                            syncTimedIdeasToAppleCalendar()
                                        }
                                    }
                                }
                            )) {
                                Text("sync timed ideas")
                                    .font(.custom("Switzer-Regular", size: 12))
                                    .foregroundStyle(Color.fg.opacity(0.6))
                            }
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .disabled(!appleCalendarManager.hasFullAccess)
                        }

                        if let error = appleCalendarManager.lastErrorMessage, !error.isEmpty {
                            Text(error)
                                .font(.custom("Switzer-Regular", size: 12))
                                .foregroundStyle(Color.red.opacity(0.7))
                        }
                    }

                    Rectangle()
                        .fill(Color.fg.opacity(0.06))
                        .frame(height: 1)
                        .padding(.vertical, 8)

                    // API Key section
                    sectionHeader("ai chat")

                    Text("enter your openrouter api key to use the chat feature. get one at openrouter.ai. stored locally.")
                        .font(.custom("Switzer-Light", size: 12))
                        .foregroundStyle(Color.fg.opacity(0.25))
                        .lineSpacing(4)

                    SecureField("sk-or-...", text: $apiKeyText)
                        .textFieldStyle(.plain)
                        .font(.custom("Switzer-Regular", size: 14))
                        .foregroundStyle(Color.fg.opacity(0.8))
                        .padding(12)
                        .background(Color.fg.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .onChange(of: apiKeyText) {
                            ensureProfile().openaiAPIKey = apiKeyText
                            try? modelContext.save()
                        }
                }
                #if os(macOS)
                .padding(.horizontal, 32)
                #else
                .padding(.horizontal, 20)
                #endif
                .padding(.bottom, 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        #if os(iOS)
        .background(Color.bgBase)
        #endif
        .onAppear {
            if !didLoad {
                bioText = profile?.bio ?? ""
                tags = profile?.verifiedTags ?? []
                tagColors = profile?.tagColors ?? [:]
                apiKeyText = profile?.openaiAPIKey ?? ""
                appleCalendarManager.refreshAuthorizationStatus()
                didLoad = true
            }
        }
        .onChange(of: tags) {
            ensureProfile().verifiedTags = tags
            try? modelContext.save()
        }
        .onDisappear {
            try? modelContext.save()
        }
    }

    private static let appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.custom("Switzer-Medium", size: 11))
            .foregroundStyle(Color.fg.opacity(0.3))
            .textCase(.uppercase)
            .tracking(1.5)
    }

    private var calendarStatusColor: Color {
        if appleCalendarManager.hasFullAccess {
            return Color.green.opacity(0.8)
        }

        switch appleCalendarManager.authorizationStatus {
        case .fullAccess:
            return Color.green.opacity(0.8)
        case .denied, .restricted:
            return Color.red.opacity(0.8)
        case .notDetermined, .writeOnly:
            return Color.orange.opacity(0.8)
        @unknown default:
            return Color.fg.opacity(0.4)
        }
    }

    private var calendarStatusText: String {
        if appleCalendarManager.hasFullAccess {
            return "connected"
        }

        switch appleCalendarManager.authorizationStatus {
        case .fullAccess:
            return "connected"
        case .denied:
            return "access denied"
        case .restricted:
            return "access restricted"
        case .notDetermined:
            return "not connected"
        case .writeOnly:
            return "write-only access"
        @unknown default:
            return "unknown status"
        }
    }

    @discardableResult
    private func ensureProfile() -> UserProfile {
        if let existing = profiles.first {
            return existing
        }
        let new = UserProfile()
        modelContext.insert(new)
        return new
    }

    private func addCustomTag() {
        let tag = newTag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !tag.isEmpty, !tags.contains(tag) else {
            newTag = ""
            return
        }
        withAnimation(.easeOut(duration: 0.2)) {
            tags.append(tag)
        }
        newTag = ""
    }

    private func generateTags() async {
        isGenerating = true
        errorMessage = nil
        defer { isGenerating = false }

        guard !apiKeyText.isEmpty else {
            errorMessage = "add your openrouter api key first"
            return
        }

        let systemPrompt = """
        Generate 10-15 relevant tags for someone based on their self-description. \
        Tags should be short, lowercase, and useful for categorizing ideas and projects. \
        Respond with JSON: {"tags": ["tag1", "tag2", ...]}
        """

        do {
            let result = try await OpenAIService.jsonCompletion(
                apiKey: apiKeyText,
                messages: [
                    .init(role: "system", content: systemPrompt),
                    .init(role: "user", content: bioText)
                ]
            )

            if let generatedTags = result["tags"] as? [String] {
                withAnimation(.easeOut(duration: 0.3)) {
                    tags = generatedTags.map { $0.lowercased() }
                }
            } else {
                errorMessage = "unexpected response format"
            }
        } catch {
            errorMessage = "failed to generate tags: \(error.localizedDescription)"
        }
    }

    private func syncTimedIdeasToAppleCalendar() {
        let timedIdeas = ideas.filter { $0.dueDate != nil && $0.dueTime != nil && $0.modelContext != nil }
        for idea in timedIdeas {
            AppleCalendarManager.shared.syncIdea(idea, enabled: true)
        }
        try? modelContext.save()
    }
}

struct TagColorRow: View {
    let tag: String
    @Binding var color: Color
    let hasColor: Bool
    let onClearColor: () -> Void
    let onRemove: () -> Void

    @State private var showSwatches = false

    private static var presetHexColors: [String] { AccentPalette.hexOptions }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button { withAnimation(.easeOut(duration: 0.15)) { showSwatches.toggle() } } label: {
                    Circle()
                        .fill(hasColor ? color : Color.fg.opacity(0.15))
                        .frame(width: 18, height: 18)
                        .overlay(
                            Circle()
                                .strokeBorder(Color.fg.opacity(0.1), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)

                Text(tag)
                    .font(.custom("Switzer-Regular", size: 13))
                    .foregroundStyle(hasColor ? color : Color.fg.opacity(0.6))

                Spacer()

                if hasColor {
                    Button {
                        onClearColor()
                        showSwatches = false
                    } label: {
                        Text("clear")
                            .font(.custom("Switzer-Light", size: 10))
                            .foregroundStyle(Color.fg.opacity(0.25))
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    onRemove()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.fg.opacity(0.25))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            if showSwatches {
                HStack(spacing: 6) {
                    ForEach(Self.presetHexColors, id: \.self) { hex in
                        let c = AccentPalette.color(for: hex) ?? .fg
                        Button {
                            color = c
                            showSwatches = false
                        } label: {
                            Circle()
                                .fill(c)
                                .frame(width: 20, height: 20)
                                .overlay(
                                    Circle()
                                        .strokeBorder(Color.fg.opacity(
                                            hasColor && color.toHex() == hex ? 0.8 : 0
                                        ), lineWidth: 2)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                    ColorPicker("", selection: $color, supportsOpacity: false)
                        .labelsHidden()
                        .frame(width: 20, height: 20)
                        .scaleEffect(0.65)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.fg.opacity(0.04))
        )
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: .unspecified
            )
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }

        return (CGSize(width: maxWidth, height: y + rowHeight), positions)
    }
}

#Preview {
    SettingsView()
        .modelContainer(for: [Idea.self, UserProfile.self], inMemory: true)
        .frame(width: 500, height: 600)
}
