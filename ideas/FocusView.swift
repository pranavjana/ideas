import SwiftUI
import SwiftData

struct FocusView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Idea.createdAt, order: .reverse) private var allIdeas: [Idea]
    @Query private var profiles: [UserProfile]
    @Environment(\.tagColors) private var tagColors
    @ObservedObject private var appleCalendarManager = AppleCalendarManager.shared

    @Bindable var viewModel: FocusViewModel
    var onSelectIdea: ((Idea) -> Void)? = nil

    @State private var inputText = ""
    @State private var selectedModel: AIModel = AIModel.available[0]
    @State private var showAddIdea = false
    @State private var addIdeaSearch = ""
    @FocusState private var isInputFocused: Bool

    private let cal = Calendar.current
    private let hourHeight: CGFloat = 60
    private let timeGutterWidth: CGFloat = 48
    private let startHour = 0
    private let endHour = 24

    var body: some View {
        #if os(macOS)
        GeometryReader { geo in
            let showSchedule = geo.size.width > 700
            HStack(spacing: 0) {
                leftColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if showSchedule {
                    rightColumn
                        .frame(width: min(max(geo.size.width * 0.35, 280), 420))
                        .frame(maxHeight: .infinity)
                        .padding(.trailing, 8)
                        .background(Color.fg.opacity(0.02))
                }
            }
        }
        .background(Color.bgBase)
        .task {
            refreshTodaySchedule()
        }
        #else
        ScrollView {
            VStack(spacing: 0) {
                focusHeader
                    .padding(.top, 20)
                    .padding(.bottom, 16)

                if !viewModel.focusItems.isEmpty {
                    progressBar
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                }

                focusTaskList
                    .padding(.horizontal, 12)
            }
        }
        .background(Color.bgBase)
        .safeAreaInset(edge: .bottom) {
            iOSInputBar
        }
        #endif
    }

    // MARK: - Left Column (macOS)

    private var leftColumn: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    focusHeader
                        .padding(.top, 32)
                        .padding(.bottom, 20)
                        .padding(.horizontal, 32)

                    if !viewModel.focusItems.isEmpty {
                        progressBar
                            .padding(.horizontal, 32)
                            .padding(.bottom, 16)
                    }

                    focusTaskList
                        .padding(.horizontal, 24)

                    // AI response card
                    aiResponseCard
                        .padding(.horizontal, 24)
                        .padding(.top, 8)
                }
            }
            .defaultScrollAnchor(.top)

            focusInputBar
        }
    }

    // MARK: - Right Column — Today's Schedule

    private var rightColumn: some View {
        let timedIdeas = todayTimedIdeas

        return VStack(alignment: .leading, spacing: 0) {
            // Up next section
            upNextSection(timedIdeas: timedIdeas)
                .padding(.horizontal, 14)
                .padding(.top, 28)
                .padding(.bottom, 12)

            // Time grid
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    ZStack(alignment: .topLeading) {
                        todayTimeGrid
                        todayEventBlocks(timedIdeas: timedIdeas)
                        todayAppleCalendarBlocks
                        todayNowIndicator
                    }
                    .frame(height: CGFloat(endHour - startHour) * hourHeight)
                }
                .onAppear {
                    let currentHour = max(cal.component(.hour, from: Date()) - 1, 0)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        proxy.scrollTo("schedule-hour-\(currentHour)", anchor: .top)
                    }
                }
            }
        }
    }

    // MARK: - Up Next Section

    private func upNextSection(timedIdeas: [Idea]) -> some View {
        let now = Date()
        let allEvents = upcomingEvents(after: now, timedIdeas: timedIdeas)

        return VStack(alignment: .leading, spacing: 10) {
            Text("up next")
                .font(.custom("Switzer-Semibold", size: 16))
                .foregroundStyle(Color.fg.opacity(0.75))

            if allEvents.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.fg.opacity(0.15))
                    Text("nothing scheduled")
                        .font(.custom("Switzer-Light", size: 13))
                        .foregroundStyle(Color.fg.opacity(0.2))
                }
                .padding(.top, 2)
            } else {
                VStack(spacing: 6) {
                    ForEach(Array(allEvents.prefix(3).enumerated()), id: \.offset) { _, event in
                        upNextCard(event: event)
                    }
                }
            }
        }
    }

    private enum ScheduleEvent {
        case idea(Idea)
        case calendar(AppleCalendarEvent)

        var startDate: Date {
            switch self {
            case .idea(let idea): return idea.dueDatetime ?? Date()
            case .calendar(let event): return event.startDate
            }
        }

        var title: String {
            switch self {
            case .idea(let idea): return idea.text
            case .calendar(let event): return event.title
            }
        }
    }

    private func upcomingEvents(after date: Date, timedIdeas: [Idea]) -> [ScheduleEvent] {
        var events: [ScheduleEvent] = []

        for idea in timedIdeas {
            if let dt = idea.dueDatetime, dt > date {
                events.append(.idea(idea))
            }
        }

        let calEvents = appleCalendarManager.visibleEvents.filter {
            !$0.isAllDay && cal.isDateInToday($0.startDate) && $0.endDate > date
        }
        for event in calEvents {
            events.append(.calendar(event))
        }

        return events.sorted { $0.startDate < $1.startDate }
    }

    private static let upNextTimeFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "h:mm a"
        return fmt
    }()

    private func upNextCard(event: ScheduleEvent) -> some View {
        let timeStr = Self.upNextTimeFormatter.string(from: event.startDate).lowercased()
        let isCalendar: Bool
        let color: Color
        let subtitle: String?

        switch event {
        case .idea(let idea):
            isCalendar = false
            color = eventColor(for: idea)
            subtitle = idea.visibleTags.first
        case .calendar(let calEvent):
            isCalendar = true
            color = Color.fg.opacity(0.3)
            subtitle = calEvent.calendarTitle
        }

        return HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 3, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.custom("Switzer-Medium", size: 13))
                    .foregroundStyle(Color.fg.opacity(0.75))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(timeStr)
                        .font(.custom("Switzer-Light", size: 11))
                        .foregroundStyle(Color.fg.opacity(0.35))

                    if let subtitle {
                        Text("·")
                            .foregroundStyle(Color.fg.opacity(0.15))
                        Text(subtitle)
                            .font(.custom("Switzer-Light", size: 11))
                            .foregroundStyle(Color.fg.opacity(0.25))
                    }

                    if isCalendar {
                        Image(systemName: "calendar")
                            .font(.system(size: 8))
                            .foregroundStyle(Color.fg.opacity(0.2))
                    }
                }
            }

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(color.opacity(0.06))
        )
    }

    // MARK: - Focus Header

    private var focusHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    let greeting = timeGreeting()
                    Text(viewModel.userName.isEmpty ? "\(greeting)." : "\(greeting), \(viewModel.userName).")
                        .font(.custom("Switzer-Semibold", size: 22))
                        .foregroundStyle(Color.fg.opacity(0.85))

                    Text(todayFormatted())
                        .font(.custom("Switzer-Light", size: 13))
                        .foregroundStyle(Color.fg.opacity(0.3))
                }

                Spacer()

                if !viewModel.focusItems.isEmpty {
                    Button {
                        viewModel.resetFocus()
                    } label: {
                        Text("reset")
                            .font(.custom("Switzer-Regular", size: 11))
                            .foregroundStyle(Color.fg.opacity(0.3))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.fg.opacity(0.04))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Progress Bar

    private var progressBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(viewModel.completedCount) of \(viewModel.totalCount) completed")
                    .font(.custom("Switzer-Regular", size: 12))
                    .foregroundStyle(Color.fg.opacity(0.4))
                Spacer()
                if viewModel.totalCount > 0 {
                    Text("\(Int(Double(viewModel.completedCount) / Double(viewModel.totalCount) * 100))%")
                        .font(.custom("Switzer-Medium", size: 12))
                        .foregroundStyle(Color.fg.opacity(0.5))
                }
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.fg.opacity(0.06))
                        .frame(height: 5)

                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.fg.opacity(0.25))
                        .frame(width: viewModel.totalCount > 0
                            ? geo.size.width * CGFloat(viewModel.completedCount) / CGFloat(viewModel.totalCount)
                            : 0,
                               height: 5)
                        .animation(.easeInOut(duration: 0.3), value: viewModel.completedCount)
                }
            }
            .frame(height: 5)
        }
    }

    // MARK: - Focus Task List

    private var focusTaskList: some View {
        VStack(spacing: 2) {
            ForEach(viewModel.focusItems) { item in
                focusItemRow(item: item)
            }

            // Add button
            Button {
                showAddIdea = true
                addIdeaSearch = ""
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 14))
                    Text("add idea to focus")
                        .font(.custom("Switzer-Regular", size: 13))
                }
                .foregroundStyle(Color.fg.opacity(0.2))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showAddIdea) {
                addIdeaPicker
            }
        }
    }

    // MARK: - Focus Item Row

    private func focusItemRow(item: FocusViewModel.FocusItem) -> some View {
        let accent = item.idea.accentColor(from: tagColors)

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        viewModel.toggleItem(item)
                    }
                } label: {
                    Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16))
                        .foregroundStyle(item.isCompleted
                            ? (accent?.opacity(0.5) ?? Color.fg.opacity(0.4))
                            : (accent?.opacity(0.2) ?? Color.fg.opacity(0.15)))
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.idea.text)
                        .font(.custom("Switzer-Regular", size: 14))
                        .foregroundStyle(item.isCompleted
                            ? Color.fg.opacity(0.3)
                            : (accent?.opacity(0.9) ?? Color.fg.opacity(0.8)))
                        .strikethrough(item.isCompleted, color: Color.fg.opacity(0.2))
                        .lineLimit(2)

                    HStack(spacing: 6) {
                        if item.idea.priority > 0 {
                            Text(item.idea.priorityLevel.label)
                                .font(.custom("Switzer-Light", size: 10))
                                .foregroundStyle(item.idea.priorityLevel.color.opacity(0.7))
                        }
                        ForEach(item.idea.visibleTags, id: \.self) { tag in
                            let tagColor = tagColors[tag].flatMap { Color.accent(hex: $0) }
                            Text(tag)
                                .font(.custom("Switzer-Light", size: 9))
                                .foregroundStyle((tagColor ?? .fg).opacity(0.6))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background((tagColor ?? .fg).opacity(0.1))
                                .clipShape(Capsule())
                        }
                        if let due = item.idea.dueTime {
                            Text(formatDueTime(due))
                                .font(.custom("Switzer-Light", size: 10))
                                .foregroundStyle(Color.fg.opacity(0.3))
                        }
                        if !item.idea.subtasks.isEmpty {
                            let progress = item.idea.subtaskProgress
                            Text("\(progress.done)/\(progress.total)")
                                .font(.custom("Switzer-Light", size: 10))
                                .foregroundStyle(Color.fg.opacity(0.25))
                        }
                    }
                }

                Spacer()

                // Remove from focus
                Button {
                    viewModel.removeFocusItem(item)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color.fg.opacity(0.12))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)

                // Open detail
                Button {
                    onSelectIdea?(item.idea)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.fg.opacity(0.12))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(item.isCompleted ? Color.fg.opacity(0.02) : (accent ?? Color.fg).opacity(0.04))
            )

            // Subtasks
            if !item.subtasks.isEmpty && !item.isCompleted {
                VStack(spacing: 0) {
                    ForEach(Array(item.subtasks.enumerated()), id: \.offset) { index, subtask in
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                viewModel.toggleSubtask(item: item, subtaskIndex: index)
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: subtask.isDone ? "checkmark.square.fill" : "square")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.fg.opacity(subtask.isDone ? 0.3 : 0.15))
                                Text(subtask.text)
                                    .font(.custom("Switzer-Light", size: 12))
                                    .foregroundStyle(Color.fg.opacity(subtask.isDone ? 0.25 : 0.5))
                                    .strikethrough(subtask.isDone, color: Color.fg.opacity(0.15))
                                    .lineLimit(1)
                                Spacer()
                            }
                            .padding(.leading, 42)
                            .padding(.trailing, 14)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.bottom, 2)
            }
        }
        .padding(.vertical, 1)
    }

    // MARK: - Add Idea Picker

    private var addIdeaPicker: some View {
        let focusIDs = Set(viewModel.focusItems.map { $0.idea.persistentModelID })
        let available = allIdeas
            .filter { $0.modelContext != nil && !$0.isDone && !focusIDs.contains($0.persistentModelID) }
        let filtered = addIdeaSearch.isEmpty ? available : available.filter {
            $0.text.localizedCaseInsensitiveContains(addIdeaSearch)
            || $0.tags.contains(where: { $0.localizedCaseInsensitiveContains(addIdeaSearch) })
        }

        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.fg.opacity(0.25))
                TextField("search ideas...", text: $addIdeaSearch)
                    .textFieldStyle(.plain)
                    .font(.custom("Switzer-Regular", size: 13))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Rectangle()
                .fill(Color.fg.opacity(0.06))
                .frame(height: 1)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filtered.prefix(20)) { idea in
                        Button {
                            viewModel.addFocusItem(idea)
                            showAddIdea = false
                        } label: {
                            HStack(spacing: 8) {
                                let accent = idea.accentColor(from: tagColors)
                                Circle()
                                    .fill((accent ?? Color.fg).opacity(0.3))
                                    .frame(width: 6, height: 6)

                                Text(idea.text)
                                    .font(.custom("Switzer-Regular", size: 13))
                                    .foregroundStyle(Color.fg.opacity(0.7))
                                    .lineLimit(1)

                                Spacer()

                                if idea.priority > 0 {
                                    Text(idea.priorityLevel.label)
                                        .font(.custom("Switzer-Light", size: 9))
                                        .foregroundStyle(idea.priorityLevel.color.opacity(0.6))
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    if filtered.isEmpty {
                        Text("no ideas found")
                            .font(.custom("Switzer-Light", size: 12))
                            .foregroundStyle(Color.fg.opacity(0.2))
                            .padding(16)
                    }
                }
            }
            .frame(maxHeight: 300)
        }
        .frame(width: 320)
    }

    // MARK: - AI Response Card

    @ViewBuilder
    private var aiResponseCard: some View {
        if viewModel.isStreaming, let activity = viewModel.toolActivity {
            HStack(spacing: 6) {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 12, height: 12)
                Text(activity)
                    .font(.custom("Switzer-Light", size: 11))
                    .foregroundStyle(Color.fg.opacity(0.3))
            }
            .padding(.vertical, 4)
        }

        if !viewModel.latestResponse.isEmpty {
            Text(viewModel.latestResponse)
                .font(.custom("Switzer-Regular", size: 13))
                .foregroundStyle(Color.fg.opacity(0.65))
                .lineSpacing(3)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.fg.opacity(0.04))
                )
                .transition(.opacity)
        }
    }

    // MARK: - Focus Input Bar (macOS)

    private var focusInputBar: some View {
        let inputIsEmpty = inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        return HStack(spacing: 10) {
            TextField("talk to your focus coach...", text: $inputText)
                .textFieldStyle(.plain)
                .font(.custom("Switzer-Regular", size: 14))
                .foregroundStyle(Color.fg.opacity(0.9))
                .focused($isInputFocused)
                .onSubmit { sendMessage() }
                .disabled(viewModel.isStreaming)

            if viewModel.isStreaming {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 16, height: 16)
            }

            Button { sendMessage() } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(inputIsEmpty ? Color.fg.opacity(0.15) : Color.fg.opacity(0.7))
                    .frame(width: 26, height: 26)
                    .background(
                        Circle()
                            .fill(inputIsEmpty ? Color.fg.opacity(0.04) : Color.fg.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .disabled(inputIsEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(Color.bgElevated)
                .stroke(Color.fg.opacity(0.08), lineWidth: 1)
        )
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    #if os(iOS)
    private var iOSInputBar: some View {
        HStack(spacing: 8) {
            Button { showAddIdea = true; addIdeaSearch = "" } label: {
                Image(systemName: "plus.circle")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.fg.opacity(0.3))
            }
            .buttonStyle(.plain)

            TextField("talk to your focus coach...", text: $inputText)
                .font(.system(size: 15))
                .onSubmit { sendMessage() }
                .disabled(viewModel.isStreaming)

            if viewModel.isStreaming {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 16, height: 16)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .modifier(GlassInputModifier())
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }
    #endif

    // MARK: - Today's Schedule Grid

    private var todayTimedIdeas: [Idea] {
        let today = Date()
        return allIdeas.filter { idea in
            guard let due = idea.dueDate, idea.dueTime != nil else { return false }
            return cal.isDate(due, inSameDayAs: today)
        }.sorted { ($0.dueTime ?? "") < ($1.dueTime ?? "") }
    }

    private var appleCalendarSyncEnabled: Bool {
        profiles.first?.appleCalendarSyncEnabled ?? false
    }

    private func refreshTodaySchedule() {
        guard appleCalendarSyncEnabled, appleCalendarManager.hasFullAccess else {
            appleCalendarManager.clearVisibleEvents()
            return
        }
        let today = cal.startOfDay(for: Date())
        guard let tomorrow = cal.date(byAdding: .day, value: 1, to: today) else { return }
        let linkedIDs = Set(allIdeas.compactMap(\.appleCalendarEventIdentifier))
        appleCalendarManager.refreshEvents(in: DateInterval(start: today, end: tomorrow), excluding: linkedIDs)
    }

    private var todayTimeGrid: some View {
        ZStack(alignment: .topLeading) {
            ForEach(startHour..<endHour, id: \.self) { hour in
                ZStack(alignment: .topLeading) {
                    Text(hourLabel(hour))
                        .font(.custom("Switzer-Light", size: 9))
                        .foregroundStyle(Color.fg.opacity(0.2))
                        .frame(width: timeGutterWidth, alignment: .trailing)
                        .padding(.trailing, 6)
                        .offset(y: -5)
                        .id("schedule-hour-\(hour)")

                    Rectangle()
                        .fill(Color.fg.opacity(0.04))
                        .frame(height: 1)
                        .offset(x: timeGutterWidth)
                }
                .offset(y: CGFloat(hour - startHour) * hourHeight)
            }
        }
    }

    private func todayEventBlocks(timedIdeas: [Idea]) -> some View {
        GeometryReader { geo in
            let columnWidth = geo.size.width - timeGutterWidth

            ForEach(timedIdeas) { idea in
                if let (hour, minute) = idea.timeComponents {
                    let topOffset = CGFloat(hour - startHour) * hourHeight + CGFloat(minute) / 60.0 * hourHeight
                    let blockHeight = max(CGFloat(idea.scheduledDurationMinutes) / 60.0 * hourHeight, 22)
                    let color = eventColor(for: idea)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(idea.text)
                            .font(.custom("Switzer-Medium", size: 11))
                            .foregroundStyle(Color.fg.opacity(idea.isDone ? 0.3 : 0.8))
                            .strikethrough(idea.isDone)
                            .lineLimit(blockHeight > 40 ? 2 : 1)

                        if blockHeight > 30 {
                            Text(formatDueTime(idea.dueTime ?? ""))
                                .font(.custom("Switzer-Light", size: 9))
                                .foregroundStyle(Color.fg.opacity(0.35))
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .frame(width: columnWidth - 4, height: blockHeight, alignment: .topLeading)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(color.opacity(0.15))
                            .overlay(alignment: .leading) {
                                UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 4)
                                    .fill(color)
                                    .frame(width: 3)
                            }
                    )
                    .offset(x: timeGutterWidth + 2, y: topOffset)
                    .onTapGesture { onSelectIdea?(idea) }
                }
            }
        }
    }

    private var todayAppleCalendarBlocks: some View {
        GeometryReader { geo in
            let columnWidth = geo.size.width - timeGutterWidth
            let todayEvents = appleCalendarManager.visibleEvents.filter {
                !$0.isAllDay && cal.isDateInToday($0.startDate)
            }

            ForEach(todayEvents) { event in
                let hour = cal.component(.hour, from: event.startDate)
                let minute = cal.component(.minute, from: event.startDate)
                let duration = max(Int(event.endDate.timeIntervalSince(event.startDate) / 60), 15)
                let topOffset = CGFloat(hour - startHour) * hourHeight + CGFloat(minute) / 60.0 * hourHeight
                let blockHeight = max(CGFloat(duration) / 60.0 * hourHeight, 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title)
                        .font(.custom("Switzer-Medium", size: 10))
                        .foregroundStyle(Color.fg.opacity(0.6))
                        .lineLimit(1)

                    if blockHeight > 28 {
                        Text(event.calendarTitle)
                            .font(.custom("Switzer-Light", size: 9))
                            .foregroundStyle(Color.fg.opacity(0.25))
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .frame(width: columnWidth - 4, height: blockHeight, alignment: .topLeading)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.fg.opacity(0.05))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.fg.opacity(0.1), lineWidth: 1)
                        )
                )
                .offset(x: timeGutterWidth + 2, y: topOffset)
            }
        }
    }

    private var todayNowIndicator: some View {
        GeometryReader { geo in
            let now = Date()
            if cal.isDateInToday(now) {
                let hour = cal.component(.hour, from: now)
                let minute = cal.component(.minute, from: now)
                let lineY = CGFloat(hour - startHour) * hourHeight + CGFloat(minute) / 60.0 * hourHeight
                let columnWidth = geo.size.width - timeGutterWidth

                HStack(spacing: 0) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 7, height: 7)
                        .offset(x: -3.5)
                    Rectangle()
                        .fill(Color.red.opacity(0.6))
                        .frame(width: columnWidth, height: 1)
                }
                .offset(x: timeGutterWidth, y: lineY - 3.5)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Helpers

    private func sendMessage() {
        let text = inputText
        inputText = ""
        Task {
            await viewModel.sendMessage(text, model: selectedModel.id)
        }
    }

    private func timeGreeting() -> String {
        let hour = cal.component(.hour, from: Date())
        if hour < 12 { return "good morning" }
        if hour < 17 { return "good afternoon" }
        return "good evening"
    }

    private static let todayFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "EEEE, MMMM d"
        return fmt
    }()

    private func todayFormatted() -> String {
        Self.todayFormatter.string(from: Date()).lowercased()
    }

    private func hourLabel(_ hour: Int) -> String {
        if hour == 0 || hour == 24 { return "12a" }
        if hour == 12 { return "12p" }
        if hour < 12 { return "\(hour)a" }
        return "\(hour - 12)p"
    }

    private func eventColor(for idea: Idea) -> Color {
        idea.eventColor(from: tagColors)
    }
}
