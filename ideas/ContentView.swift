import SwiftUI
import SwiftData

// MARK: - Glass Input Modifier

#if os(iOS)
struct GlassInputModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.glassEffect(.regular, in: .capsule)
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
        }
    }
}
#endif

// MARK: - Tag Colors Environment

private struct TagColorsKey: EnvironmentKey {
    static let defaultValue: [String: String] = [:]
}

extension EnvironmentValues {
    var tagColors: [String: String] {
        get { self[TagColorsKey.self] }
        set { self[TagColorsKey.self] = newValue }
    }
}

enum Page: String, CaseIterable {
    case ideas, graph, chat, settings

    var label: String {
        switch self {
        case .ideas: "ideas"
        case .graph: "graph"
        case .chat: "ai chat"
        case .settings: "settings"
        }
    }

    var icon: String {
        switch self {
        case .ideas: "square.and.pencil"
        case .graph: "circle.grid.cross"
        case .chat: "bubble.left"
        case .settings: "gearshape"
        }
    }
}

enum IdeasLayout: String {
    case list, board
}

enum IdeaSort: String, CaseIterable {
    case newest, oldest, category, connections, dueDate, priority

    var label: String {
        switch self {
        case .newest: "newest"
        case .oldest: "oldest"
        case .category: "category"
        case .connections: "links"
        case .dueDate: "due"
        case .priority: "priority"
        }
    }
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Idea.createdAt, order: .reverse) private var ideas: [Idea]
    @Query private var profiles: [UserProfile]
    @State private var viewModel: IdeasViewModel?
    @State private var chatViewModel: ChatViewModel?
    @State private var currentPage: Page = .ideas
    #if os(iOS)
    @State private var selectedPage: Page? = .ideas
    #endif
    @State private var inputText = ""
    @State private var sortOption: IdeaSort = .newest
    @State private var ideasLayout: IdeasLayout = .list
    @State private var searchText = ""
    @State private var aiInputMode = false
    @State private var isAiProcessing = false
    @State private var selectedIdea: Idea? = nil
    @State private var ideaToDelete: Idea? = nil
    @State private var showDeleteConfirm = false
    @FocusState private var isInputFocused: Bool

    private var filteredIdeas: [Idea] {
        let valid = ideas.filter { $0.modelContext != nil }
        guard !searchText.isEmpty else { return valid }
        let query = searchText.lowercased()
        return valid.filter { idea in
            idea.text.lowercased().contains(query)
            || idea.tags.contains(where: { $0.lowercased().contains(query) })
            || idea.category.lowercased().contains(query)
        }
    }

    private var sortedIdeas: [Idea] {
        let base = filteredIdeas
        switch sortOption {
        case .newest:
            return base.sorted { $0.createdAt > $1.createdAt }
        case .oldest:
            return base.sorted { $0.createdAt < $1.createdAt }
        case .category:
            return base.sorted {
                if $0.category != $1.category { return $0.category < $1.category }
                return $0.createdAt > $1.createdAt
            }
        case .connections:
            return base.sorted { $0.allLinks.count > $1.allLinks.count }
        case .dueDate:
            return base.sorted { a, b in
                switch (a.dueDate, b.dueDate) {
                case (nil, nil): return a.createdAt > b.createdAt
                case (nil, _): return false
                case (_, nil): return true
                case let (d1?, d2?): return d1 < d2
                }
            }
        case .priority:
            return base.sorted { a, b in
                // Ideas with priority (1-4) come first, sorted by priority level (1=urgent first)
                // Then ideas with no priority (0), sorted by createdAt
                if a.priority == 0 && b.priority == 0 { return a.createdAt > b.createdAt }
                if a.priority == 0 { return false }
                if b.priority == 0 { return true }
                if a.priority != b.priority { return a.priority < b.priority }
                return a.createdAt > b.createdAt
            }
        }
    }

    var body: some View {
        #if os(macOS)
        HStack(spacing: 0) {
            sidebar

            if let idea = selectedIdea {
                IdeaEditorPanel(idea: idea) {
                    withAnimation(.easeOut(duration: 0.35)) { selectedIdea = nil }
                }
                .id(idea.id)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                mainContent
            }
        }
        .environment(\.tagColors, profiles.first?.tagColors ?? [:])
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.09, green: 0.09, blue: 0.09))
        .onAppear { setupViewModels() }
        .background {
            Button("") { currentPage = .settings }
                .keyboardShortcut(",", modifiers: .command)
                .hidden()
        }
        .alert("Delete idea?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {
                ideaToDelete = nil
            }
            Button("Delete", role: .destructive) {
                if let idea = ideaToDelete {
                    if selectedIdea?.id == idea.id {
                        selectedIdea = nil
                    }
                    withAnimation(.easeOut(duration: 0.2)) {
                        modelContext.delete(idea)
                        try? modelContext.save()
                    }
                    ideaToDelete = nil
                }
            }
        } message: {
            if let idea = ideaToDelete {
                Text("\(idea.text) will be permanently deleted.")
            }
        }
        #else
        NavigationSplitView {
            List(selection: $selectedPage) {
                ForEach([Page.ideas, .graph, .chat], id: \.self) { page in
                    NavigationLink(value: page) {
                        Label(page.label, systemImage: page.icon)
                    }
                }

                Section {
                    NavigationLink(value: Page.settings) {
                        Label(Page.settings.label, systemImage: Page.settings.icon)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("ideas.")
            .scrollContentBackground(.hidden)
            .background(Color(red: 0.07, green: 0.07, blue: 0.07))
        } detail: {
            iOSDetailView
        }
        .onChange(of: selectedPage) { _, newValue in
            if let newValue { currentPage = newValue }
        }
        .preferredColorScheme(.dark)
        .tint(.white)
        .environment(\.tagColors, profiles.first?.tagColors ?? [:])
        .onAppear { setupViewModels() }
        #endif
    }

    private func setupViewModels() {
        if viewModel == nil {
            viewModel = IdeasViewModel(modelContext: modelContext)
        }
        if chatViewModel == nil {
            let vm = ChatViewModel(modelContext: modelContext)
            vm.ideasViewModel = viewModel
            chatViewModel = vm
        }
        #if os(macOS)
        isInputFocused = true
        #endif
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Logo
            HStack(spacing: 8) {
                Image("IdeasLogo")
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 32, height: 32)
                    .foregroundStyle(Color.white.opacity(0.85))
                Text("ideas.")
                    .font(.custom("Gambarino-Regular", size: 24))
                    .foregroundStyle(Color.white.opacity(0.85))
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 24)

            // Navigation
            VStack(spacing: 2) {
                ForEach([Page.ideas, .graph, .chat], id: \.self) { page in
                    navItem(page: page)
                }
            }
            .padding(.horizontal, 10)

            Spacer()

            // Settings at bottom
            VStack(spacing: 2) {
                navItem(page: .settings)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 12)
        }
        .frame(width: 180)
        .background(Color(red: 0.07, green: 0.07, blue: 0.07))
    }

    private func navItem(page: Page) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { currentPage = page }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: page.icon)
                    .font(.system(size: 13))
                    .frame(width: 20)
                Text(page.label)
                    .font(.custom("Switzer-Medium", size: 13))
            }
            .foregroundStyle(Color.white.opacity(currentPage == page ? 0.85 : 0.25))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(currentPage == page ? 0.06 : 0))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Main Content

    @ViewBuilder
    private var mainContent: some View {
        switch currentPage {
        case .ideas:
            ideasPage
        case .graph:
            GraphView()
        case .chat:
            ChatView(ideasViewModel: viewModel)
        case .settings:
            SettingsView()
        }
    }

    #if os(iOS)
    @ViewBuilder
    private var iOSDetailView: some View {
        mainContent
            .navigationBarTitleDisplayMode(.inline)
    }
    #endif

    // MARK: - Ideas Page

    private var ideasPage: some View {
        #if os(macOS)
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                ideasToolbar

                if ideasLayout == .list {
                    ideasListContent
                } else {
                    ideasBoardContent
                }

                aiResponseCard

                ideasInputBar
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(Color.white.opacity(0.06))
                            .frame(height: 1)
                    }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        }
        .background(Color(red: 0.09, green: 0.09, blue: 0.09))
        #else
        iOSIdeasPage
        #endif
    }

    #if os(iOS)
    private var iOSIdeasPage: some View {
        ZStack {
            Color(red: 0.09, green: 0.09, blue: 0.09)
                .ignoresSafeArea()

            if ideasLayout == .list {
                ideasListContent
            } else {
                ideasBoardContent
            }
        }
        .safeAreaInset(edge: .bottom) {
            iOSIdeasInput
        }
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "search...")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Section("layout") {
                        Button {
                            ideasLayout = .list
                        } label: {
                            Label("list", systemImage: "list.bullet")
                        }
                        .disabled(ideasLayout == .list)

                        Button {
                            ideasLayout = .board
                        } label: {
                            Label("board", systemImage: "rectangle.split.3x1")
                        }
                        .disabled(ideasLayout == .board)
                    }

                    if ideasLayout == .list {
                        Section("sort by") {
                            Picker("sort", selection: $sortOption) {
                                ForEach(IdeaSort.allCases, id: \.self) { option in
                                    Text(option.label).tag(option)
                                }
                            }
                        }
                    }

                    Section {
                        Button {
                            aiInputMode.toggle()
                        } label: {
                            Label(
                                aiInputMode ? "switch to normal" : "switch to ai",
                                systemImage: aiInputMode ? "pencil.line" : "sparkles"
                            )
                        }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.system(size: 14))
                }
            }
        }
        .sheet(item: $selectedIdea) { idea in
            NavigationStack {
                IdeaEditorPanel(idea: idea) {
                    selectedIdea = nil
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("done") { selectedIdea = nil }
                            .font(.custom("Switzer-Medium", size: 15))
                    }
                }
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }

    private var iOSIdeasInput: some View {
        VStack(spacing: 6) {
            aiResponseCard

            HStack(spacing: 8) {
                ideasModeToggle

                TextField(aiInputMode ? "ask ai..." : "what's on your mind...", text: $inputText)
                    .font(.system(size: 15))
                    .onSubmit { handleIdeasSubmit() }

                if isAiProcessing {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 18, height: 18)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .modifier(GlassInputModifier())
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }
    #endif

    // macOS input bar — dark background, inline
    private var ideasInputBar: some View {
        HStack(spacing: 0) {
            ideasModeToggle
                .padding(.leading, 16)

            TextField(aiInputMode ? "ask ai to do something..." : "what's on your mind...", text: $inputText)
                .textFieldStyle(.plain)
                .font(.custom("Switzer-Regular", size: 15))
                .foregroundStyle(Color.white.opacity(0.9))
                .padding(.horizontal, 12)
                .padding(.vertical, 16)
                .focused($isInputFocused)
                .onSubmit { handleIdeasSubmit() }

            if isAiProcessing {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 20, height: 20)
                    .padding(.trailing, 16)
            }
        }
        .background(Color(red: 0.09, green: 0.09, blue: 0.09))
    }


    @ViewBuilder
    private var aiResponseCard: some View {
        let responseText = chatViewModel?.silentResponseText ?? ""
        let activity = chatViewModel?.toolActivity
        let showCard = isAiProcessing || !responseText.isEmpty

        if showCard {
            VStack(alignment: .leading, spacing: 8) {
                if let activity, isAiProcessing {
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 12, height: 12)
                        Text(activity)
                            .font(.custom("Switzer-Light", size: 11))
                            .foregroundStyle(Color.white.opacity(0.35))
                    }
                }

                if !responseText.isEmpty {
                    Text(responseText)
                        .font(.custom("Switzer-Regular", size: 13))
                        .foregroundStyle(Color.white.opacity(0.75))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(0.05))
            )
            #if os(macOS)
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
            #endif
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    private var ideasModeToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { aiInputMode.toggle() }
        } label: {
            Image(systemName: aiInputMode ? "sparkles" : "pencil.line")
                .font(.system(size: 12))
                .foregroundStyle(aiInputMode
                    ? Color(red: 0.6, green: 0.5, blue: 1.0)
                    : Color.white.opacity(0.35))
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(aiInputMode
                            ? Color(red: 0.6, green: 0.5, blue: 1.0).opacity(0.12)
                            : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .help(aiInputMode ? "AI mode — sends to AI agent" : "Normal mode — adds idea directly")
        #endif
    }

    private func handleIdeasSubmit() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Seed demo ideas for product showcase
        if trimmed.lowercased() == "demo" {
            inputText = ""
            seedDemoIdeas()
            return
        }

        // Clear demo ideas
        if trimmed.lowercased() == "clear demo" {
            inputText = ""
            clearDemoIdeas()
            return
        }

        if aiInputMode {
            let text = inputText
            inputText = ""
            withAnimation(.easeOut(duration: 0.25)) { isAiProcessing = true }
            Task {
                await chatViewModel?.sendSilent(text)
                withAnimation(.easeOut(duration: 0.2)) { isAiProcessing = false }
                try? await Task.sleep(for: .seconds(5))
                withAnimation(.easeOut(duration: 0.4)) {
                    chatViewModel?.silentResponseText = ""
                }
            }
        } else {
            viewModel?.addIdea(inputText)
            inputText = ""
        }
    }

    private func seedDemoIdeas() {
        let demoData: [(text: String, tags: [String], category: String, priority: Int, subtasks: [String], done: Bool)] = [
            (
                "Redesign onboarding flow with progressive disclosure",
                ["design", "ux"],
                "product",
                1,
                ["todo|||Audit current onboarding steps", "todo|||Sketch new flow wireframes", "done|||Benchmark competitor onboarding", "todo|||User test prototype with 5 users"],
                false
            ),
            (
                "Ship dark mode across all screens",
                ["design", "engineering"],
                "feature",
                2,
                ["done|||Create dark color palette tokens", "done|||Update navigation components", "todo|||Update settings & profile screens", "todo|||QA pass on all 12 screens"],
                false
            ),
            (
                "Set up error tracking with Sentry",
                ["engineering", "devops"],
                "infrastructure",
                2,
                ["done|||Install Sentry SDK", "todo|||Configure source maps", "todo|||Set up Slack alert channel"],
                false
            ),
            (
                "Write blog post: How we built our AI tagging system",
                ["marketing", "content"],
                "growth",
                3,
                ["todo|||Draft outline", "todo|||Write first draft", "todo|||Add screenshots and diagrams"],
                false
            ),
            (
                "Migrate database to connection pooling",
                ["engineering", "devops"],
                "infrastructure",
                2,
                [],
                false
            ),
            (
                "Customer interview: enterprise workflow needs",
                ["research", "product"],
                "discovery",
                3,
                ["done|||Schedule call with Acme Corp", "done|||Prepare interview script", "todo|||Summarize findings"],
                false
            ),
            (
                "Add keyboard shortcuts for power users",
                ["engineering", "ux"],
                "feature",
                4,
                ["todo|||Define shortcut map", "todo|||Implement global listener", "todo|||Add shortcuts cheat sheet overlay"],
                false
            ),
            (
                "Weekly team sync — sprint planning",
                ["team"],
                "process",
                0,
                [],
                true
            ),
            (
                "Implement graph view clustering for large idea counts",
                ["engineering", "design"],
                "feature",
                3,
                ["todo|||Research force-directed layout algorithms", "todo|||Prototype cluster grouping", "todo|||Animate cluster expand/collapse"],
                false
            ),
            (
                "Competitive analysis: Notion, Linear, Obsidian",
                ["research", "product"],
                "strategy",
                4,
                ["done|||Feature matrix spreadsheet", "done|||Pricing comparison", "todo|||Write positioning memo"],
                false
            ),
        ]

        let cal = Calendar.current
        let now = Date()

        for (i, data) in demoData.enumerated() {
            let idea = Idea(text: data.text)
            idea.tags = data.tags + [Idea.demoTag]
            idea.category = data.category
            idea.priority = data.priority
            idea.subtasks = data.subtasks
            idea.isDone = data.done
            idea.isProcessing = false

            // Stagger creation dates so they look natural
            idea.createdAt = cal.date(byAdding: .hour, value: -(i * 6 + Int.random(in: 0...3)), to: now) ?? now

            // Sprinkle due dates on some
            if i == 0 {
                idea.dueDate = cal.date(byAdding: .day, value: 1, to: now)
            } else if i == 2 {
                idea.dueDate = cal.date(byAdding: .day, value: 3, to: now)
            } else if i == 7 {
                idea.dueDate = cal.startOfDay(for: now)
                idea.recurringPattern = "weekly"
            }

            // Graph positions — spread in a grid
            let col = Double(i % 4)
            let row = Double(i / 4)
            idea.positionX = col * 220 - 330 + Double.random(in: -30...30)
            idea.positionY = row * 200 - 200 + Double.random(in: -30...30)

            withAnimation(.easeOut(duration: 0.25).delay(Double(i) * 0.05)) {
                modelContext.insert(idea)
            }
        }

        try? modelContext.save()
    }

    private func clearDemoIdeas() {
        let demoIdeas = ideas.filter { $0.isDemo }
        for idea in demoIdeas {
            withAnimation(.easeOut(duration: 0.2)) {
                modelContext.delete(idea)
            }
        }
        try? modelContext.save()
        selectedIdea = nil
    }

    // macOS-only toolbar (iOS uses native .searchable + inline toolbar in iOSIdeasPage)
    private var ideasToolbar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 2) {
                layoutButton(icon: "list.bullet", layout: .list)
                layoutButton(icon: "rectangle.split.3x1", layout: .board)
            }
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.white.opacity(0.04))
            )

            if ideasLayout == .list {
                sortPills
            }

            Spacer()

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.25))
                TextField("search...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.custom("Switzer-Regular", size: 13))
                    .foregroundStyle(Color.white.opacity(0.8))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.04))
                    .stroke(Color.white.opacity(searchText.isEmpty ? 0.06 : 0.12), lineWidth: 1)
            )
            .frame(width: 180)
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    private var sortPills: some View {
        HStack(spacing: 6) {
            ForEach(IdeaSort.allCases, id: \.self) { option in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { sortOption = option }
                } label: {
                    Text(option.label)
                        .font(.custom("Switzer-Light", size: 11))
                        .foregroundStyle(Color.white.opacity(sortOption == option ? 0.8 : 0.25))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule()
                                .fill(Color.white.opacity(sortOption == option ? 0.08 : 0))
                        )
                        .overlay(
                            Capsule()
                                .strokeBorder(Color.white.opacity(sortOption == option ? 0.15 : 0.06), lineWidth: 1)
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func layoutButton(icon: String, layout: IdeasLayout) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { ideasLayout = layout }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(ideasLayout == layout ? 0.8 : 0.25))
                .frame(width: 26, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.white.opacity(ideasLayout == layout ? 0.08 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - List Content

    private var ideasListContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(sortedIdeas) { idea in
                    ideaListRow(idea: idea)
                }
            }
            .padding(.top, 8)
        }
        .scrollDismissesKeyboard(.interactively)
        .defaultScrollAnchor(.top)
    }

    private func ideaListRow(idea: Idea) -> some View {
        let isSelected = selectedIdea?.id == idea.id
        return IdeaRow(idea: idea, isSelected: isSelected) {
            withAnimation(.easeOut(duration: 0.35)) {
                selectedIdea = isSelected ? nil : idea
            }
        }
        #if os(macOS)
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        #else
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        #endif
        .transition(.opacity.combined(with: .move(edge: .top)))
        .contextMenu {
            Button(role: .destructive) {
                ideaToDelete = idea
                showDeleteConfirm = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: - Board Content

    private var boardColumns: [(tag: String, ideas: [Idea])] {
        var grouped: [String: [Idea]] = [:]
        for idea in filteredIdeas {
            let key = idea.visibleTags.first ?? "untagged"
            grouped[key, default: []].append(idea)
        }
        return grouped
            .sorted {
                if $0.key == "untagged" { return false }
                if $1.key == "untagged" { return true }
                return $0.key < $1.key
            }
            .map { (tag: $0.key, ideas: $0.value.sorted { $0.createdAt > $1.createdAt }) }
    }

    private var ideasBoardContent: some View {
        #if os(iOS)
        // iOS: vertical grouped sections instead of horizontal kanban
        List {
            ForEach(boardColumns, id: \.tag) { column in
                let columnColor = profiles.first?.tagColors[column.tag].flatMap { Color(hex: $0) }
                Section {
                    ForEach(column.ideas) { idea in
                        boardCard(idea: idea)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedIdea = idea
                            }
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    }
                } header: {
                    HStack(spacing: 8) {
                        Circle()
                            .fill((columnColor ?? .white).opacity(0.5))
                            .frame(width: 6, height: 6)
                        Text(column.tag)
                            .font(.custom("Switzer-Semibold", size: 13))
                            .foregroundStyle((columnColor ?? .white).opacity(0.8))
                        Text("\(column.ideas.count)")
                            .font(.custom("Switzer-Regular", size: 11))
                            .foregroundStyle(Color.white.opacity(0.25))
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        #else
        // macOS: horizontal kanban columns
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(boardColumns, id: \.tag) { column in
                    boardColumn(tag: column.tag, ideas: column.ideas)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
        #endif
    }

    private func boardColumn(tag: String, ideas: [Idea]) -> some View {
        let columnColor = profiles.first?.tagColors[tag].flatMap { Color(hex: $0) }
        return VStack(alignment: .leading, spacing: 0) {
            // Column header
            HStack(spacing: 8) {
                Circle()
                    .fill((columnColor ?? .white).opacity(0.5))
                    .frame(width: 6, height: 6)
                Text(tag)
                    .font(.custom("Switzer-Semibold", size: 13))
                    .foregroundStyle((columnColor ?? .white).opacity(0.8))
                Text("\(ideas.count)")
                    .font(.custom("Switzer-Regular", size: 11))
                    .foregroundStyle(Color.white.opacity(0.25))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.white.opacity(0.06))
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 1)
                .padding(.horizontal, 10)

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 6) {
                    ForEach(ideas) { idea in
                        boardCard(idea: idea)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    selectedIdea = selectedIdea?.id == idea.id ? nil : idea
                                }
                            }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 10)
            }
        }
        .frame(width: 260)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.03))
                .stroke(Color.white.opacity(0.04), lineWidth: 1)
        )
    }

    private func boardCardAccent(for idea: Idea) -> Color? {
        guard let firstTag = idea.tags.first,
              let hex = profiles.first?.tagColors[firstTag], !hex.isEmpty else { return nil }
        return Color(hex: hex)
    }

    private func boardCard(idea: Idea) -> some View {
        let accent = boardCardAccent(for: idea)
        return HStack(alignment: .top, spacing: 10) {
            Button {
                handleBoardCheckbox(idea: idea)
            } label: {
                Image(systemName: idea.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(idea.isDone
                        ? (accent?.opacity(0.35) ?? Color.white.opacity(0.45))
                        : (accent?.opacity(0.2) ?? Color.white.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 8) {
                Text(idea.text)
                    .font(.custom("Switzer-Regular", size: 13))
                    .foregroundStyle(idea.isDone
                        ? (accent?.opacity(0.25) ?? Color.white.opacity(0.25))
                        : (accent?.opacity(0.9) ?? Color.white.opacity(0.9)))
                    .strikethrough(idea.isDone, color: (accent ?? .white).opacity(0.15))
                    .lineSpacing(2)
                    .lineLimit(4)

                if idea.tags.count > 1 {
                    let tc = profiles.first?.tagColors ?? [:]
                    HStack(spacing: 4) {
                        ForEach(idea.visibleTags.dropFirst(), id: \.self) { tag in
                            let tagColor = tc[tag].flatMap { Color(hex: $0) }
                            Text(tag)
                                .font(.custom("Switzer-Light", size: 9))
                                .foregroundStyle((tagColor ?? .white).opacity(0.7))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background((tagColor ?? .white).opacity(0.15))
                                .clipShape(Capsule())
                        }
                    }
                }

                HStack(spacing: 6) {
                    Text(idea.createdAt.formatted(.dateTime.month(.abbreviated).day()))
                        .font(.custom("Switzer-Light", size: 10))
                        .foregroundStyle((accent ?? .white).opacity(0.22))

                    let linkCount = idea.allLinks.count
                    if linkCount > 0 {
                        Circle()
                            .fill((accent ?? .white).opacity(0.15))
                            .frame(width: 3, height: 3)
                        Text("\(linkCount) link\(linkCount == 1 ? "" : "s")")
                            .font(.custom("Switzer-Light", size: 10))
                            .foregroundStyle((accent ?? .white).opacity(0.22))
                    }

                    if let formatted = idea.formattedDueDate {
                        Circle()
                            .fill((accent ?? .white).opacity(0.15))
                            .frame(width: 3, height: 3)
                        HStack(spacing: 3) {
                            Image(systemName: idea.recurring != nil ? "arrow.trianglehead.2.clockwise" : "calendar")
                                .font(.system(size: 8))
                            Text(formatted)
                                .font(.custom("Switzer-Light", size: 10))
                        }
                        .foregroundStyle(idea.dueStatus.color.opacity(0.8))
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill((accent ?? .white).opacity(0.04))
        )
    }

    private func handleBoardCheckbox(idea: Idea) {
        idea.animatedToggleDone()
    }
}

// MARK: - Idea Row

struct IdeaRow: View {
    @Environment(\.tagColors) private var tagColors
    @Bindable var idea: Idea
    var isSelected: Bool = false
    var onTap: (() -> Void)? = nil
    @State private var showDatePicker = false
    @State private var showUpdates = false

    /// Resolved color from the first tag, or nil if no color is set.
    private var rowAccent: Color? {
        guard let firstTag = idea.tags.first,
              let hex = tagColors[firstTag], !hex.isEmpty else { return nil }
        return Color(hex: hex)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                handleCheckboxToggle()
            } label: {
                Image(systemName: idea.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(idea.isDone
                        ? (rowAccent?.opacity(0.4) ?? Color.white.opacity(0.5))
                        : (rowAccent?.opacity(0.25) ?? Color.white.opacity(0.15)))
            }
            .buttonStyle(.plain)
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 6) {
                Text(idea.text)
                    .font(.custom("Switzer-Regular", size: 15))
                    .foregroundStyle(idea.isDone
                        ? (rowAccent?.opacity(0.3) ?? Color.white.opacity(0.3))
                        : (rowAccent?.opacity(0.9) ?? Color.white.opacity(0.85)))
                    .strikethrough(idea.isDone, color: (rowAccent ?? .white).opacity(0.2))
                    .contentShape(Rectangle())
                    .onTapGesture { onTap?() }

                if idea.isProcessing {
                    Text("...")
                        .font(.custom("Switzer-Light", size: 11))
                        .foregroundStyle(Color.white.opacity(0.2))
                }

                HStack(spacing: 8) {
                    Text(idea.createdAt.formatted(.dateTime.hour().minute()))
                        .font(.custom("Switzer-Light", size: 11))
                        .foregroundStyle((rowAccent ?? .white).opacity(0.25))

                    if idea.priorityLevel != .none {
                        Text(idea.priorityLevel.label)
                            .font(.custom("Switzer-Medium", size: 10))
                            .foregroundStyle(idea.priorityLevel.color)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(idea.priorityLevel.color.opacity(0.12))
                            .clipShape(Capsule())
                    }

                    if !idea.isProcessing {
                        ForEach(idea.visibleTags, id: \.self) { tag in
                            let tagColor = tagColors[tag].flatMap { Color(hex: $0) }
                            Text(tag)
                                .font(.custom("Switzer-Light", size: 10))
                                .foregroundStyle((tagColor ?? .white).opacity(0.7))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background((tagColor ?? .white).opacity(0.15))
                                .clipShape(Capsule())
                        }
                    }

                    if !idea.category.isEmpty {
                        Text(idea.category)
                            .font(.custom("Switzer-Light", size: 11))
                            .foregroundStyle((rowAccent ?? .white).opacity(0.35))
                    }

                    let linkCount = idea.allLinks.count
                    if linkCount > 0 {
                        Text("\(linkCount) link\(linkCount == 1 ? "" : "s")")
                            .font(.custom("Switzer-Light", size: 11))
                            .foregroundStyle((rowAccent ?? .white).opacity(0.25))
                    }

                    // Due date indicator
                    dueDateButton

                    // Updates count
                    if !idea.updates.isEmpty {
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) { showUpdates.toggle() }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: showUpdates ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 7, weight: .bold))
                                Text("\(idea.updates.count) update\(idea.updates.count == 1 ? "" : "s")")
                                    .font(.custom("Switzer-Light", size: 11))
                            }
                            .foregroundStyle((rowAccent ?? .white).opacity(0.3))
                        }
                        .buttonStyle(.plain)
                    }

                    // Subtask progress
                    if !idea.subtasks.isEmpty {
                        let progress = idea.subtaskProgress
                        HStack(spacing: 4) {
                            Image(systemName: "checklist")
                                .font(.system(size: 9))
                            Text("\(progress.done)/\(progress.total)")
                                .font(.custom("Switzer-Light", size: 11))
                        }
                        .foregroundStyle((rowAccent ?? .white).opacity(progress.done == progress.total ? 0.4 : 0.3))
                    }
                }

                // Expandable updates list
                if showUpdates && !idea.updates.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(idea.parsedUpdates.reversed(), id: \.text) { update in
                            HStack(alignment: .top, spacing: 8) {
                                Circle()
                                    .fill((rowAccent ?? .white).opacity(0.2))
                                    .frame(width: 4, height: 4)
                                    .padding(.top, 5)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(update.text)
                                        .font(.custom("Switzer-Regular", size: 12))
                                        .foregroundStyle((rowAccent ?? .white).opacity(0.6))
                                    Text(update.date.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                                        .font(.custom("Switzer-Light", size: 10))
                                        .foregroundStyle((rowAccent ?? .white).opacity(0.2))
                                }
                            }
                        }
                    }
                    .padding(.top, 4)
                    .padding(.leading, 4)
                }

                // Subtasks
                if !idea.subtasks.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(idea.parsedSubtasks.enumerated()), id: \.offset) { index, subtask in
                            HStack(spacing: 8) {
                                Button {
                                    withAnimation(.easeOut(duration: 0.15)) {
                                        idea.toggleSubtask(at: index)
                                    }
                                } label: {
                                    Image(systemName: subtask.isDone ? "checkmark.square.fill" : "square")
                                        .font(.system(size: 11))
                                        .foregroundStyle((rowAccent ?? .white).opacity(subtask.isDone ? 0.35 : 0.2))
                                }
                                .buttonStyle(.plain)

                                Text(subtask.text)
                                    .font(.custom("Switzer-Regular", size: 12))
                                    .foregroundStyle((rowAccent ?? .white).opacity(subtask.isDone ? 0.3 : 0.6))
                                    .strikethrough(subtask.isDone, color: (rowAccent ?? .white).opacity(0.15))
                            }
                        }
                    }
                    .padding(.top, 4)
                    .padding(.leading, 4)
                }
            }
        }
        .padding(isSelected ? 10 : 0)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? (rowAccent ?? .white).opacity(0.06) : Color.clear)
        )
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var dueDateButton: some View {
        if let formatted = idea.formattedDueDate {
            Button { showDatePicker = true } label: {
                HStack(spacing: 4) {
                    Image(systemName: idea.recurring != nil ? "arrow.trianglehead.2.clockwise" : "calendar")
                        .font(.system(size: 9))
                    Text(formatted)
                        .font(.custom("Switzer-Light", size: 11))
                    if let r = idea.recurring {
                        Text(r.rawValue)
                            .font(.custom("Switzer-Light", size: 9))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(idea.dueStatus.color.opacity(0.15))
                            .clipShape(Capsule())
                    }
                }
                .foregroundStyle(idea.dueStatus.color)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showDatePicker) {
                DatePickerPopover(idea: idea)
            }
        } else {
            Button { showDatePicker = true } label: {
                Image(systemName: "calendar.badge.plus")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.white.opacity(0.15))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showDatePicker) {
                DatePickerPopover(idea: idea)
            }
        }
    }

    private func handleCheckboxToggle() {
        idea.animatedToggleDone()
    }
}

// MARK: - Date Picker Popover

struct DatePickerPopover: View {
    @Bindable var idea: Idea
    @Environment(\.dismiss) private var dismiss

    @State private var selectedDate: Date
    @State private var hasTime: Bool
    @State private var timeString: String
    @State private var selectedRecurring: Idea.RecurringPattern?

    init(idea: Idea) {
        self.idea = idea
        _selectedDate = State(initialValue: idea.dueDate ?? Calendar.current.startOfDay(for: Date()))
        _hasTime = State(initialValue: idea.dueTime != nil)
        _timeString = State(initialValue: idea.dueTime ?? "09:00")
        _selectedRecurring = State(initialValue: idea.recurring)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("due date")
                .font(.custom("Switzer-Semibold", size: 13))
                .foregroundStyle(Color.white.opacity(0.8))

            DatePicker("", selection: $selectedDate, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .tint(Color(red: 0.4, green: 0.7, blue: 1.0))

            // Time toggle
            HStack(spacing: 8) {
                Toggle(isOn: $hasTime) {
                    Text("time")
                        .font(.custom("Switzer-Regular", size: 12))
                        .foregroundStyle(Color.white.opacity(0.6))
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                if hasTime {
                    TextField("HH:mm", text: $timeString)
                        .textFieldStyle(.plain)
                        .font(.custom("Switzer-Regular", size: 12))
                        .foregroundStyle(Color.white.opacity(0.8))
                        .frame(width: 50)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color.white.opacity(0.06))
                                .stroke(Color.white.opacity(0.1), lineWidth: 1)
                        )
                }
            }

            // Recurring picker
            HStack(spacing: 8) {
                Text("repeat")
                    .font(.custom("Switzer-Regular", size: 12))
                    .foregroundStyle(Color.white.opacity(0.6))

                Picker("", selection: $selectedRecurring) {
                    Text("none").tag(Idea.RecurringPattern?.none)
                    ForEach(Idea.RecurringPattern.allCases, id: \.self) { pattern in
                        Text(pattern.rawValue).tag(Idea.RecurringPattern?.some(pattern))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            // Actions
            HStack {
                Button("clear") {
                    idea.dueDate = nil
                    idea.dueTime = nil
                    idea.recurringPattern = nil
                    dismiss()
                }
                .font(.custom("Switzer-Regular", size: 12))
                .foregroundStyle(Color.white.opacity(0.4))
                .buttonStyle(.plain)

                Spacer()

                Button("save") {
                    idea.dueDate = Calendar.current.startOfDay(for: selectedDate)
                    idea.dueTime = hasTime ? timeString : nil
                    idea.recurring = selectedRecurring
                    dismiss()
                }
                .font(.custom("Switzer-Semibold", size: 12))
                .foregroundStyle(Color(red: 0.4, green: 0.7, blue: 1.0))
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(width: 260)
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [Idea.self, UserProfile.self], inMemory: true)
        .frame(width: 1100, height: 750)
}
