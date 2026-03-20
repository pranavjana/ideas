import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import EventKit
#if os(macOS)
import AppKit
#endif

// MARK: - Idea Transfer (for drag & drop)

/// Transferable wrapper so we can drag Idea persistent IDs across calendar slots.
struct IdeaTransfer: Codable, Transferable {
    let uriRepresentation: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .ideaTransfer)
    }
}

extension UTType {
    static let ideaTransfer = UTType(exportedAs: "com.ideas.ideatransfer")
    static let appleCalendarEventTransfer = UTType(exportedAs: "com.ideas.applecalendareventtransfer")
}

struct AppleCalendarEventTransfer: Codable, Transferable {
    let identifier: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .appleCalendarEventTransfer)
    }
}

// MARK: - View Mode

enum CalendarViewMode: String {
    case month, week
}

// MARK: - Calendar View

struct CalendarView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Idea.createdAt, order: .reverse) private var allIdeas: [Idea]
    @Query private var profiles: [UserProfile]
    @Environment(\.tagColors) private var tagColors
    @ObservedObject private var appleCalendarManager = AppleCalendarManager.shared
    var ideasViewModel: IdeasViewModel? = nil
    var onSelectIdea: ((Idea) -> Void)? = nil

    @State private var displayedDate = Date()
    @State private var selectedDate: Date? = nil
    @State private var viewMode: CalendarViewMode = .week
    @State private var hoveredSlot: TimeSlot? = nil
    @State private var showQuickAdd = false
    @State private var quickAddDate: Date? = nil
    @State private var quickAddMode: QuickAddMode = .new
    @State private var quickAddNewKind: QuickAddNewKind = .idea
    @State private var editingAppleCalendarEvent: AppleCalendarEvent? = nil
    @State private var quickAddText = ""
    @State private var quickAddSelectedTag: String? = nil
    @State private var quickAddDuration: Int = 60
    @State private var quickAddStartHour: Int = 16
    @State private var quickAddStartMinute: Int = 0
    @State private var quickAddEndHour: Int = 17
    @State private var quickAddEndMinute: Int = 0
    @State private var quickAddLinkSearch = ""
    @State private var dropTargetSlot: TimeSlot? = nil
    @State private var hoveredEventURI: String? = nil
    @State private var hoveredAppleEventID: String? = nil
    @State private var draggedIdeaURI: String? = nil
    @State private var draggedDurationMinutes = 60
    @State private var ideaToDelete: Idea? = nil
    @State private var showDeleteConfirm = false
    @GestureState private var activeResizeDrag: ResizeDragState? = nil
    @GestureState private var activeIdeaDrag: IdeaDragState? = nil
    @GestureState private var activeAppleResizeDrag: AppleResizeDragState? = nil
    @GestureState private var activeAppleEventDrag: AppleEventDragState? = nil
    @FocusState private var quickAddFocused: Bool

    private let cal = Calendar.current
    private let hourHeight: CGFloat = 60
    private let minuteIncrement = 15
    private let timeGutterWidth: CGFloat = 52
    private let dayDividerWidth: CGFloat = 1
    private let eventColumnInset: CGFloat = 2
    private let startHour = 0
    private let endHour = 24

    private struct TimeSlot: Equatable, Hashable {
        let date: Date
        let hour: Int
        let minute: Int
    }

    private enum QuickAddMode: String, CaseIterable {
        case new = "new"
        case link = "link"
    }

    private enum QuickAddNewKind: String, CaseIterable {
        case idea = "idea"
        case calendarItem = "calendar item"
    }

    private struct ResizeDragState: Equatable {
        let ideaURI: String
        let translationHeight: CGFloat
        let baseDurationMinutes: Int
    }

    private struct IdeaDragState: Equatable {
        let ideaURI: String
        let originDayIndex: Int
        let originStartMinutes: Int
        let durationMinutes: Int
        let translation: CGSize
    }

    private struct AppleEventDragState: Equatable {
        let eventIdentity: String
        let originDayIndex: Int
        let originStartMinutes: Int
        let durationMinutes: Int
        let translation: CGSize
    }

    private struct AppleResizeDragState: Equatable {
        let eventIdentity: String
        let translationHeight: CGFloat
        let baseDurationMinutes: Int
    }

    /// Represents a time span in minutes from midnight, used for overlap detection.
    private struct EventSpan {
        let id: String
        let startMinutes: Int
        let endMinutes: Int
    }

    /// Layout result: which sub-column this event occupies and how many total columns in its cluster.
    private struct EventLayout {
        let columnIndex: Int
        let totalColumns: Int
    }

    /// Computes side-by-side column assignments for overlapping events (Google Calendar style).
    private func computeOverlapLayout(spans: [EventSpan]) -> [String: EventLayout] {
        guard !spans.isEmpty else { return [:] }

        let sorted = spans.sorted { $0.startMinutes < $1.startMinutes || ($0.startMinutes == $1.startMinutes && $0.endMinutes > $1.endMinutes) }

        // Build overlap clusters — events that transitively overlap share a cluster
        var clusters: [[EventSpan]] = []
        var currentCluster: [EventSpan] = []
        var clusterEnd = 0

        for span in sorted {
            if currentCluster.isEmpty || span.startMinutes < clusterEnd {
                currentCluster.append(span)
                clusterEnd = max(clusterEnd, span.endMinutes)
            } else {
                clusters.append(currentCluster)
                currentCluster = [span]
                clusterEnd = span.endMinutes
            }
        }
        if !currentCluster.isEmpty {
            clusters.append(currentCluster)
        }

        // For each cluster, greedily assign columns
        var result: [String: EventLayout] = [:]

        for cluster in clusters {
            // columnEnds[i] = the end-minute of the last event placed in column i
            var columnEnds: [Int] = []

            for span in cluster {
                // Find the leftmost column where this event fits (no overlap)
                var placed = false
                for col in 0..<columnEnds.count {
                    if columnEnds[col] <= span.startMinutes {
                        columnEnds[col] = span.endMinutes
                        result[span.id] = EventLayout(columnIndex: col, totalColumns: 0) // totalColumns set later
                        placed = true
                        break
                    }
                }
                if !placed {
                    result[span.id] = EventLayout(columnIndex: columnEnds.count, totalColumns: 0)
                    columnEnds.append(span.endMinutes)
                }
            }

            let totalCols = columnEnds.count
            for span in cluster {
                if let layout = result[span.id] {
                    result[span.id] = EventLayout(columnIndex: layout.columnIndex, totalColumns: totalCols)
                }
            }
        }

        return result
    }

    private struct TimeGridDropDelegate: DropDelegate {
        let days: [Date]
        let totalWidth: CGFloat
        let dayColumnWidth: CGFloat
        let dayDividerWidth: CGFloat
        let startHour: Int
        let endHour: Int
        let minuteIncrement: Int
        let timeSlotHeight: CGFloat
        @Binding var dropTargetSlot: TimeSlot?
        let slotForLocation: (CGPoint) -> TimeSlot?
        let moveIdea: (String, TimeSlot) -> Void
        let moveAppleEvent: (AppleCalendarEvent, TimeSlot, Int) -> Void
        let appleEventForID: (String) -> AppleCalendarEvent?
        let draggedDurationMinutes: () -> Int
        let clearDraggedState: () -> Void

        func dropEntered(info: DropInfo) {
            dropTargetSlot = slotForLocation(info.location)
        }

        func dropUpdated(info: DropInfo) -> DropProposal? {
            dropTargetSlot = slotForLocation(info.location)
            return DropProposal(operation: .move)
        }

        func dropExited(info: DropInfo) {
            dropTargetSlot = nil
        }

        func performDrop(info: DropInfo) -> Bool {
            guard let slot = slotForLocation(info.location) else {
                dropTargetSlot = nil
                clearDraggedState()
                return false
            }

            let ideaProviders = info.itemProviders(for: [UTType.ideaTransfer])
            if let provider = ideaProviders.first {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.ideaTransfer.identifier) { data, _ in
                    guard let data,
                          let transfer = try? JSONDecoder().decode(IdeaTransfer.self, from: data) else { return }

                    DispatchQueue.main.async {
                        moveIdea(transfer.uriRepresentation, slot)
                        clearDraggedState()
                    }
                }

                dropTargetSlot = nil
                return true
            }

            let appleProviders = info.itemProviders(for: [UTType.appleCalendarEventTransfer])
            guard let appleProvider = appleProviders.first else {
                dropTargetSlot = nil
                clearDraggedState()
                return false
            }

            appleProvider.loadDataRepresentation(forTypeIdentifier: UTType.appleCalendarEventTransfer.identifier) { data, _ in
                guard let data,
                      let transfer = try? JSONDecoder().decode(AppleCalendarEventTransfer.self, from: data) else { return }

                DispatchQueue.main.async {
                    guard let event = appleEventForID(transfer.identifier) else { return }
                    moveAppleEvent(event, slot, draggedDurationMinutes())
                    clearDraggedState()
                }
            }

            dropTargetSlot = nil
            return true
        }
    }

    // MARK: - Data

    private var ideasWithDueDate: [Idea] {
        allIdeas.filter { $0.dueDate != nil && $0.modelContext != nil }
    }

    private var weekDays: [Date] {
        let weekday = cal.component(.weekday, from: displayedDate)
        guard let startOfWeek = cal.date(byAdding: .day, value: -(weekday - 1), to: cal.startOfDay(for: displayedDate)) else { return [] }
        return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: startOfWeek) }
    }

    private func ideasForDate(_ date: Date) -> [Idea] {
        ideasWithDueDate.filter { idea in
            guard let due = idea.dueDate else { return false }
            return cal.isDate(due, inSameDayAs: date)
        }
    }

    private func ideasByDayMap() -> [Date: [Idea]] {
        var dict: [Date: [Idea]] = [:]
        for idea in ideasWithDueDate {
            guard let due = idea.dueDate else { continue }
            let key = cal.startOfDay(for: due)
            dict[key, default: []].append(idea)
        }
        return dict
    }

    private func findIdea(uri: String) -> Idea? {
        allIdeas.first { idea in
            idea.persistentModelID.hashValue.description == uri
        }
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            Color.bgBase.ignoresSafeArea()

            VStack(spacing: 0) {
                calendarHeader

                if viewMode == .week {
                    weekTimeGrid
                } else {
                    monthView
                }
            }

            if showQuickAdd {
                quickAddOverlay
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .alert("Delete idea?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {
                ideaToDelete = nil
            }
            Button("Delete", role: .destructive) {
                if let idea = ideaToDelete {
                    deleteIdea(idea)
                }
            }
        } message: {
            if let idea = ideaToDelete {
                Text("\(idea.text) will be permanently deleted.")
            }
        }
    }

    // MARK: - Header

    private var calendarHeader: some View {
        HStack(spacing: 16) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    displayedDate = Date()
                    selectedDate = Date()
                }
            } label: {
                Text("today")
                    .font(.custom("Switzer-Medium", size: 13))
                    .foregroundStyle(Color.fg.opacity(0.5))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.fg.opacity(0.1), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)

            HStack(spacing: 4) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { navigateBack() }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.fg.opacity(0.4))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { navigateForward() }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.fg.opacity(0.4))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
            }

            Text(headerTitle)
                .font(.custom("Switzer-Semibold", size: 18))
                .foregroundStyle(Color.fg.opacity(0.85))

            Spacer()

            HStack(spacing: 0) {
                viewModeButton("week", mode: .week)
                viewModeButton("month", mode: .month)
            }
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.bgElevated)
            )
        }
        #if os(macOS)
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 8)
        #else
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 6)
        #endif
    }

    private func viewModeButton(_ label: String, mode: CalendarViewMode) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { viewMode = mode }
        } label: {
            Text(label)
                .font(.custom("Switzer-Medium", size: 12))
                .foregroundStyle(Color.fg.opacity(viewMode == mode ? 0.7 : 0.3))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(viewMode == mode ? Color.bgCard : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }

    private static let monthYearFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMMM yyyy"
        return fmt
    }()

    private static let shortMonthFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM"
        return fmt
    }()

    private static let yearFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy"
        return fmt
    }()

    private var headerTitle: String {
        if viewMode == .week {
            let days = weekDays
            guard let first = days.first, let last = days.last else { return "" }
            if cal.component(.month, from: first) == cal.component(.month, from: last) {
                return Self.monthYearFormatter.string(from: first).lowercased()
            } else {
                return "\(Self.shortMonthFormatter.string(from: first).lowercased()) – \(Self.shortMonthFormatter.string(from: last).lowercased()) \(Self.yearFormatter.string(from: last))"
            }
        } else {
            return Self.monthYearFormatter.string(from: displayedDate).lowercased()
        }
    }

    private var appleCalendarSyncEnabled: Bool {
        profiles.first?.appleCalendarSyncEnabled ?? false
    }

    // MARK: - Week Time Grid

    private var weekTimeGrid: some View {
        let days = weekDays
        return VStack(spacing: 0) {
            weekDayHeaders(days: days)

            Rectangle().fill(Color.fg.opacity(0.06)).frame(height: 1)

            allDaySection(days: days)

            Rectangle().fill(Color.fg.opacity(0.06)).frame(height: 1)

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    ZStack(alignment: .topLeading) {
                        timeGridBackground(days: days)
                        hoverPreview(days: days)
                        dropTargetHighlight(days: days)
                        appleCalendarEventBlocks(days: days)
                        ideaDragPreview(days: days)
                        appleCalendarDragPreview(days: days)
                        appleCalendarResizePreview(days: days)
                        eventBlocks(days: days)
                        resizePreview(days: days)
                        nowIndicator(days: days)
                    }
                    .frame(height: CGFloat(endHour - startHour) * hourHeight)
                    .id("timeGrid")
                }
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        proxy.scrollTo("hour-8", anchor: .top)
                    }
                }
            }
        }
        .task(id: appleCalendarRefreshKey(days: days)) {
            refreshAppleCalendar(for: days)
        }
    }

    private func appleCalendarRefreshKey(days: [Date]) -> String {
        let weekKey = days.map { String(Int($0.timeIntervalSinceReferenceDate)) }.joined(separator: ",")
        let ideasKey = ideasWithDueDate
            .filter { $0.dueTime != nil }
            .map {
                "\($0.persistentModelID.hashValue):\($0.text):\($0.dueDate?.timeIntervalSinceReferenceDate ?? 0):\($0.dueTime ?? ""):\($0.scheduledDurationMinutes):\($0.appleCalendarEventIdentifier ?? "")"
            }
            .joined(separator: "|")
        return "\(viewMode.rawValue)-\(appleCalendarSyncEnabled)-\(appleCalendarManager.authorizationStatus.rawValue)-\(weekKey)-\(ideasKey)"
    }

    // MARK: - Compact Day Headers

    private func weekDayHeaders(days: [Date]) -> some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: timeGutterWidth, height: 1)

            ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                let isToday = cal.isDateInToday(day)
                HStack(spacing: 6) {
                    Text(dayOfWeekShort(day))
                        .font(.custom("Switzer-Medium", size: 10))
                        .foregroundStyle(Color.fg.opacity(isToday ? 0.5 : 0.25))

                    Text("\(cal.component(.day, from: day))")
                        .font(.custom("Switzer-Semibold", size: 13))
                        .foregroundStyle(isToday ? Color.bgBase : Color.fg.opacity(0.5))
                        .frame(width: 24, height: 24)
                        .background(
                            Circle()
                                .fill(isToday ? Color.fg : Color.clear)
                        )
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
        }
        .frame(height: 36, alignment: .center)
    }

    // MARK: - All-Day Section

    private func allDaySection(days: [Date]) -> some View {
        let allDayIdeas = days.map { day in
            ideasForDate(day).filter { $0.dueTime == nil }
        }
        let hasAnyAllDay = allDayIdeas.contains { !$0.isEmpty }

        return Group {
            if hasAnyAllDay {
                HStack(spacing: 0) {
                    Text("all-day")
                        .font(.custom("Switzer-Light", size: 9))
                        .foregroundStyle(Color.fg.opacity(0.2))
                        .frame(width: timeGutterWidth)

                    ForEach(Array(days.enumerated()), id: \.offset) { idx, day in
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(allDayIdeas[idx].prefix(2)) { idea in
                                allDayChip(idea)
                            }
                            if allDayIdeas[idx].count > 2 {
                                Text("+\(allDayIdeas[idx].count - 2)")
                                    .font(.custom("Switzer-Light", size: 8))
                                    .foregroundStyle(Color.fg.opacity(0.2))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 2)
                        .dropDestination(for: IdeaTransfer.self) { items, _ in
                            guard let item = items.first,
                                  let idea = findIdea(uri: item.uriRepresentation) else { return false }
                            moveIdea(idea, toDate: day, hour: nil)
                            return true
                        }
                    }
                }
                .padding(.vertical, 3)
            }
        }
    }

    private func allDayChip(_ idea: Idea) -> some View {
        Button { onSelectIdea?(idea) } label: {
            Text(idea.text)
                .font(.custom("Switzer-Medium", size: 10))
                .foregroundStyle(Color.fg.opacity(idea.isDone ? 0.3 : 0.8))
                .strikethrough(idea.isDone)
                .lineLimit(1)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(eventColor(for: idea).opacity(0.2))
                )
        }
        .buttonStyle(.plain)
        .draggable(ideaTransfer(idea)) {
            dragPreview(idea)
        }
        .contextMenu {
            ideaContextMenu(idea)
        }
    }

    // MARK: - Time Grid Background

    private func timeGridBackground(days: [Date]) -> some View {
        GeometryReader { geo in
            let totalWidth = geo.size.width - timeGutterWidth
            let columnWidth = dayColumnWidth(totalWidth: totalWidth, dayCount: days.count)

            ZStack(alignment: .topLeading) {
                // Hour lines + labels
                ForEach(startHour..<endHour, id: \.self) { hour in
                    ZStack(alignment: .topLeading) {
                        Text(hourLabel(hour))
                            .font(.custom("Switzer-Light", size: 10))
                            .foregroundStyle(Color.fg.opacity(0.25))
                            .frame(width: timeGutterWidth, alignment: .trailing)
                            .padding(.trailing, 8)
                            .offset(y: -6)
                            .id("hour-\(hour)")

                        Rectangle()
                            .fill(Color.fg.opacity(0.04))
                            .frame(height: 1)
                            .offset(x: timeGutterWidth)
                    }
                    .offset(y: CGFloat(hour - startHour) * hourHeight)
                }

                // Vertical dividers are positioned with the same column math as events.
                ForEach(1..<days.count, id: \.self) { idx in
                    let xOffset = timeGutterWidth + CGFloat(idx) * columnWidth + CGFloat(idx - 1) * dayDividerWidth
                    Rectangle()
                        .fill(Color.fg.opacity(0.04))
                        .frame(width: dayDividerWidth, height: CGFloat(endHour - startHour) * hourHeight)
                        .offset(x: xOffset, y: 0)
                }

                // Tap targets remain per slot; dragging uses a single geometry-backed drop surface.
                dayColumnTargets(days: days)
                timeGridDropLayer(days: days, totalWidth: totalWidth, columnWidth: columnWidth)
            }
        }
    }

    private func dayColumnWidth(totalWidth: CGFloat, dayCount: Int) -> CGFloat {
        let dividerTotal = CGFloat(max(dayCount - 1, 0)) * dayDividerWidth
        return (totalWidth - dividerTotal) / CGFloat(max(dayCount, 1))
    }

    private func dayColumnXOffset(columnIndex: Int, totalWidth: CGFloat, dayCount: Int) -> CGFloat {
        let columnWidth = dayColumnWidth(totalWidth: totalWidth, dayCount: dayCount)
        return timeGutterWidth + CGFloat(columnIndex) * (columnWidth + dayDividerWidth)
    }

    // MARK: - Day Column Tap + Drop Targets

    private func dayColumnTargets(days: [Date]) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: timeGutterWidth)

            ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                dayColumn(day: day)
            }
        }
        .frame(height: CGFloat(endHour - startHour) * hourHeight)
    }

    private func dayColumn(day: Date) -> some View {
        VStack(spacing: 0) {
            ForEach(startHour..<endHour, id: \.self) { hour in
                ForEach(Array(stride(from: 0, to: 60, by: minuteIncrement)), id: \.self) { minute in
                    timeSlotView(day: day, hour: hour, minute: minute)
                }
            }
        }
    }

    private var timeSlotHeight: CGFloat {
        hourHeight / CGFloat(60 / minuteIncrement)
    }

    private var defaultTimedDurationMinutes: Int { 60 }

    private func yOffset(forHour hour: Int, minute: Int) -> CGFloat {
        CGFloat(hour - startHour) * hourHeight + CGFloat(minute) / 60.0 * hourHeight
    }

    private func height(forDurationMinutes durationMinutes: Int) -> CGFloat {
        max(CGFloat(durationMinutes) / 60.0 * hourHeight, timeSlotHeight)
    }

    private var activeDraggedDurationMinutes: Int {
        max(draggedDurationMinutes, minuteIncrement)
    }

    private func timeSlotView(day: Date, hour: Int, minute: Int) -> some View {
        let slot = TimeSlot(date: day, hour: hour, minute: minute)
        return timeSlotBase(day: day, hour: hour, minute: minute, slot: slot)
    }

    private func timeSlotBase(day: Date, hour: Int, minute: Int, slot: TimeSlot) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: timeSlotHeight)
            .contentShape(Rectangle())
            .onTapGesture {
                if let targetDate = cal.date(bySettingHour: hour, minute: minute, second: 0, of: day) {
                    quickAddDate = targetDate
                    quickAddText = ""
                    showQuickAdd = true
                    quickAddFocused = true
                    syncQuickAddTimesFromDate()
                }
            }
    }

    private func timeGridDropLayer(days: [Date], totalWidth: CGFloat, columnWidth: CGFloat) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: totalWidth, height: CGFloat(endHour - startHour) * hourHeight)
            .contentShape(Rectangle())
            .offset(x: timeGutterWidth)
            .simultaneousGesture(
                SpatialTapGesture()
                    .onEnded { value in
                        guard let slot = timeSlot(at: value.location, days: days, totalWidth: totalWidth, columnWidth: columnWidth),
                              let targetDate = cal.date(bySettingHour: slot.hour, minute: slot.minute, second: 0, of: slot.date)
                        else { return }

                        quickAddDate = targetDate
                        quickAddText = ""
                        showQuickAdd = true
                        quickAddFocused = true
                        syncQuickAddTimesFromDate()
                    }
            )
            #if os(macOS)
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let location):
                    hoveredSlot = timeSlot(at: location, days: days, totalWidth: totalWidth, columnWidth: columnWidth)
                case .ended:
                    hoveredSlot = nil
                @unknown default:
                    break
                }
            }
            #endif
            .onDrop(
                of: [UTType.ideaTransfer],
                delegate: TimeGridDropDelegate(
                    days: days,
                    totalWidth: totalWidth,
                    dayColumnWidth: columnWidth,
                    dayDividerWidth: dayDividerWidth,
                    startHour: startHour,
                    endHour: endHour,
                    minuteIncrement: minuteIncrement,
                    timeSlotHeight: timeSlotHeight,
                    dropTargetSlot: $dropTargetSlot,
                    slotForLocation: { location in
                        timeSlot(at: location, days: days, totalWidth: totalWidth, columnWidth: columnWidth)
                    },
                    moveIdea: { ideaURI, slot in
                        guard let idea = findIdea(uri: ideaURI) else { return }
                        moveIdea(idea, toDate: slot.date, hour: slot.hour, minute: slot.minute)
                    },
                    moveAppleEvent: { event, slot, durationMinutes in
                        moveAppleCalendarEvent(event, toDate: slot.date, hour: slot.hour, minute: slot.minute, durationMinutes: durationMinutes)
                    },
                    appleEventForID: { transferID in
                        appleCalendarManager.visibleEvents.first(where: { $0.id == transferID })
                    },
                    draggedDurationMinutes: { activeDraggedDurationMinutes },
                    clearDraggedState: clearDraggedState
                )
            )
    }

    private func timeSlot(at location: CGPoint, days: [Date], totalWidth: CGFloat, columnWidth: CGFloat) -> TimeSlot? {
        guard !days.isEmpty else { return nil }

        let clampedX = min(max(location.x, 0), max(totalWidth - 1, 0))
        let clampedY = min(max(location.y, 0), max(CGFloat(endHour - startHour) * hourHeight - 1, 0))

        let columnStep = columnWidth + dayDividerWidth
        let rawDayIndex = Int(clampedX / max(columnStep, 1))
        let dayIndex = min(max(rawDayIndex, 0), days.count - 1)

        let totalSlots = (endHour - startHour) * (60 / minuteIncrement)
        let slotIndex = min(max(Int(clampedY / timeSlotHeight), 0), max(totalSlots - 1, 0))
        let hour = startHour + slotIndex / (60 / minuteIncrement)
        let minute = (slotIndex % (60 / minuteIncrement)) * minuteIncrement

        return TimeSlot(date: days[dayIndex], hour: hour, minute: minute)
    }

    private func clearDraggedState() {
        dropTargetSlot = nil
        draggedIdeaURI = nil
        draggedDurationMinutes = defaultTimedDurationMinutes
    }

    private func hoverPreview(days: [Date]) -> some View {
        GeometryReader { geo in
            guard let slot = hoveredSlot,
                  dropTargetSlot == nil,
                  hoveredEventURI == nil,
                  hoveredAppleEventID == nil,
                  activeResizeDrag == nil,
                  activeAppleResizeDrag == nil,
                  activeIdeaDrag == nil,
                  activeAppleEventDrag == nil,
                  let dayIdx = days.firstIndex(where: { cal.isDate($0, inSameDayAs: slot.date) })
            else { return AnyView(EmptyView()) }

            let totalWidth = geo.size.width - timeGutterWidth
            let columnWidth = dayColumnWidth(totalWidth: totalWidth, dayCount: days.count)
            let xOffset = dayColumnXOffset(columnIndex: dayIdx, totalWidth: totalWidth, dayCount: days.count)
            let previewY = yOffset(forHour: slot.hour, minute: slot.minute)

            return AnyView(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.fg.opacity(0.025))
                    .frame(width: columnWidth - eventColumnInset * 2, height: height(forDurationMinutes: defaultTimedDurationMinutes))
                    .overlay(alignment: .topLeading) {
                        HStack(spacing: 4) {
                            Image(systemName: "plus")
                                .font(.system(size: 8, weight: .medium))
                            Text("new idea")
                                .font(.custom("Switzer-Light", size: 9))
                            Text("1 hr")
                                .font(.custom("Switzer-Light", size: 9))
                                .foregroundStyle(Color.fg.opacity(0.12))
                        }
                        .foregroundStyle(Color.fg.opacity(0.15))
                        .padding(.leading, 4)
                        .padding(.top, 3)
                    }
                    .offset(x: xOffset + eventColumnInset, y: previewY)
                    .allowsHitTesting(false)
            )
        }
    }

    // MARK: - Drop Target Highlight

    private func dropTargetHighlight(days: [Date]) -> some View {
        GeometryReader { geo in
            if activeAppleEventDrag != nil || activeIdeaDrag != nil {
                EmptyView()
            } else if let slot = dropTargetSlot,
                      let dayIdx = days.firstIndex(where: { cal.isDate($0, inSameDayAs: slot.date) }) {
                let totalWidth = geo.size.width - timeGutterWidth
                let columnWidth = dayColumnWidth(totalWidth: totalWidth, dayCount: days.count)
                let xOffset = dayColumnXOffset(columnIndex: dayIdx, totalWidth: totalWidth, dayCount: days.count)
                let previewY = yOffset(forHour: slot.hour, minute: slot.minute)
                let previewHeight = height(forDurationMinutes: activeDraggedDurationMinutes)

                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.fg.opacity(0.06))
                    .frame(width: columnWidth - eventColumnInset * 2, height: previewHeight)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.fg.opacity(0.15), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    )
                    .offset(x: xOffset + eventColumnInset, y: previewY)
            }
        }
        .allowsHitTesting(false)
    }

    private func appleCalendarDragPreview(days: [Date]) -> some View {
        GeometryReader { geo in
            guard let drag = activeAppleEventDrag,
                  let event = appleCalendarManager.visibleEvents.first(where: { $0.id == drag.eventIdentity }),
                  let slot = appleEventDropSlot(
                    translation: drag.translation,
                    originDayIndex: drag.originDayIndex,
                    originStartMinutes: drag.originStartMinutes,
                    days: days,
                    columnWidth: dayColumnWidth(totalWidth: geo.size.width - timeGutterWidth, dayCount: days.count),
                    dayCount: days.count
                  ),
                  let dayIdx = days.firstIndex(where: { cal.isDate($0, inSameDayAs: slot.date) })
            else { return AnyView(EmptyView()) }

            let totalWidth = geo.size.width - timeGutterWidth
            let columnWidth = dayColumnWidth(totalWidth: totalWidth, dayCount: days.count)
            let xOffset = dayColumnXOffset(columnIndex: dayIdx, totalWidth: totalWidth, dayCount: days.count)
            let previewY = yOffset(forHour: slot.hour, minute: slot.minute)
            let previewHeight = height(forDurationMinutes: drag.durationMinutes)

            return AnyView(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.fg.opacity(0.08))
                    .frame(width: columnWidth - eventColumnInset * 2, height: previewHeight)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.fg.opacity(0.2), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    )
                    .overlay(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.title)
                                .font(.custom("Switzer-Medium", size: 11))
                                .foregroundStyle(Color.fg.opacity(0.75))
                                .lineLimit(previewHeight > 40 ? 2 : 1)

                            if previewHeight > 30 {
                                Text(formatTime(slot.date))
                                    .font(.custom("Switzer-Light", size: 10))
                                    .foregroundStyle(Color.fg.opacity(0.4))
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                    }
                    .offset(x: xOffset + eventColumnInset, y: previewY)
                    .allowsHitTesting(false)
            )
        }
    }

    // MARK: - Event Blocks

    private func eventBlocks(days: [Date]) -> some View {
        GeometryReader { geo in
            let totalWidth = geo.size.width - timeGutterWidth
            let columnWidth = dayColumnWidth(totalWidth: totalWidth, dayCount: days.count)

            ForEach(Array(days.enumerated()), id: \.offset) { idx, day in
                let timedIdeas = ideasForDate(day)
                    .filter { $0.dueTime != nil }
                    .sorted { ($0.dueTime ?? "") < ($1.dueTime ?? "") }

                // Gather all events for this day (ideas + apple calendar) for overlap layout
                let appleEventsForDay = appleCalendarManager.visibleEvents.filter { !$0.isAllDay && cal.isDate($0.startDate, inSameDayAs: day) }

                let ideaSpans: [EventSpan] = timedIdeas.compactMap { idea in
                    guard let timeStr = idea.dueTime, timeStr.count == 5,
                          let h = Int(timeStr.prefix(2)), let m = Int(timeStr.suffix(2)) else { return nil }
                    let start = h * 60 + m
                    let end = start + idea.scheduledDurationMinutes
                    return EventSpan(id: "idea-\(idea.persistentModelID)", startMinutes: start, endMinutes: end)
                }
                let appleSpans: [EventSpan] = appleEventsForDay.map { event in
                    let h = cal.component(.hour, from: event.startDate)
                    let m = cal.component(.minute, from: event.startDate)
                    let start = h * 60 + m
                    let dur = max(Int(event.endDate.timeIntervalSince(event.startDate) / 60), minuteIncrement)
                    return EventSpan(id: "apple-\(event.id)", startMinutes: start, endMinutes: start + dur)
                }

                let layout = computeOverlapLayout(spans: ideaSpans + appleSpans)

                ForEach(timedIdeas) { idea in
                    let key = "idea-\(idea.persistentModelID)"
                    let overlapLayout = layout[key] ?? EventLayout(columnIndex: 0, totalColumns: 1)
                    eventBlock(idea: idea, columnIndex: idx, columnWidth: columnWidth, totalWidth: totalWidth, dayCount: days.count, overlapColumn: overlapLayout.columnIndex, overlapTotalColumns: overlapLayout.totalColumns)
                }
            }
        }
    }

    private func appleCalendarEventBlocks(days: [Date]) -> some View {
        GeometryReader { geo in
            let totalWidth = geo.size.width - timeGutterWidth
            let columnWidth = dayColumnWidth(totalWidth: totalWidth, dayCount: days.count)

            ForEach(Array(days.enumerated()), id: \.offset) { idx, day in
                let timedIdeas = ideasForDate(day)
                    .filter { $0.dueTime != nil }
                let appleEventsForDay = appleCalendarManager.visibleEvents.filter { !$0.isAllDay && cal.isDate($0.startDate, inSameDayAs: day) }

                let ideaSpans: [EventSpan] = timedIdeas.compactMap { idea in
                    guard let timeStr = idea.dueTime, timeStr.count == 5,
                          let h = Int(timeStr.prefix(2)), let m = Int(timeStr.suffix(2)) else { return nil }
                    let start = h * 60 + m
                    return EventSpan(id: "idea-\(idea.persistentModelID)", startMinutes: start, endMinutes: start + idea.scheduledDurationMinutes)
                }
                let appleSpans: [EventSpan] = appleEventsForDay.map { event in
                    let h = cal.component(.hour, from: event.startDate)
                    let m = cal.component(.minute, from: event.startDate)
                    let start = h * 60 + m
                    let dur = max(Int(event.endDate.timeIntervalSince(event.startDate) / 60), minuteIncrement)
                    return EventSpan(id: "apple-\(event.id)", startMinutes: start, endMinutes: start + dur)
                }

                let layout = computeOverlapLayout(spans: ideaSpans + appleSpans)

                ForEach(appleEventsForDay) { event in
                    let key = "apple-\(event.id)"
                    let overlapLayout = layout[key] ?? EventLayout(columnIndex: 0, totalColumns: 1)
                    appleCalendarEventBlock(event, columnIndex: idx, columnWidth: columnWidth, totalWidth: totalWidth, dayCount: days.count, overlapColumn: overlapLayout.columnIndex, overlapTotalColumns: overlapLayout.totalColumns)
                }
            }
        }
    }

    private func appleCalendarEventBlock(_ event: AppleCalendarEvent, columnIndex: Int, columnWidth: CGFloat, totalWidth: CGFloat, dayCount: Int, overlapColumn: Int = 0, overlapTotalColumns: Int = 1) -> some View {
        let startHour = cal.component(.hour, from: event.startDate)
        let startMinute = cal.component(.minute, from: event.startDate)
        let durationMinutes = max(Int(event.endDate.timeIntervalSince(event.startDate) / 60), minuteIncrement)
        let baseX = dayColumnXOffset(columnIndex: columnIndex, totalWidth: totalWidth, dayCount: dayCount) + eventColumnInset
        let availableWidth = columnWidth - eventColumnInset * 2
        let slotWidth = availableWidth / CGFloat(max(overlapTotalColumns, 1))
        let xOffset = baseX + slotWidth * CGFloat(overlapColumn)
        let eventWidth = slotWidth - (overlapTotalColumns > 1 ? 1 : 0)
        let topOffset = yOffset(forHour: startHour, minute: startMinute)
        let blockHeight = height(forDurationMinutes: durationMinutes)
        let startMinutes = startHour * 60 + startMinute
        let isDraggingThisEvent = activeAppleEventDrag?.eventIdentity == event.id
        let isHovered = hoveredAppleEventID == event.id
        let isResizing = activeAppleResizeDrag?.eventIdentity == event.id

        let card = VStack(alignment: .leading, spacing: 2) {
            Text(event.title)
                .font(.custom("Switzer-Medium", size: 11))
                .foregroundStyle(Color.fg.opacity(0.75))
                .lineLimit(blockHeight > 40 ? 2 : 1)

            if blockHeight > 30 {
                Text("\(formatTime(event.startDate)) · \(event.calendarTitle)")
                    .font(.custom("Switzer-Light", size: 10))
                    .foregroundStyle(Color.fg.opacity(0.35))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .frame(width: eventWidth, height: blockHeight, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.fg.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.fg.opacity(0.12), lineWidth: 1)
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 4))

        return ZStack(alignment: .bottom) {
            card

            appleCalendarResizeHandle(for: event, isVisible: isHovered || isResizing)
        }
        .frame(width: eventWidth, height: blockHeight, alignment: .topLeading)
        .contentShape(RoundedRectangle(cornerRadius: 4))
        .opacity(isDraggingThisEvent ? 0.0 : 1.0)
        .gesture(appleCalendarEventDragGesture(
            event: event,
            originDayIndex: columnIndex,
            originStartMinutes: startMinutes,
            durationMinutes: durationMinutes,
            columnWidth: columnWidth,
            dayCount: dayCount
        ))
        #if os(macOS)
        .onHover { hovering in
            hoveredAppleEventID = hovering ? event.id : (hoveredAppleEventID == event.id ? nil : hoveredAppleEventID)
            if hovering {
                hoveredSlot = nil
            }
        }
        #endif
        .offset(x: xOffset, y: topOffset)
        .contextMenu {
            appleCalendarEventContextMenu(event)
        }
    }

    private func eventBlock(idea: Idea, columnIndex: Int, columnWidth: CGFloat, totalWidth: CGFloat, dayCount: Int, overlapColumn: Int = 0, overlapTotalColumns: Int = 1) -> some View {
        let (topOffset, blockHeight) = eventPosition(idea)
        let color = eventColor(for: idea)
        let baseX = dayColumnXOffset(columnIndex: columnIndex, totalWidth: totalWidth, dayCount: dayCount) + eventColumnInset
        let availableWidth = columnWidth - eventColumnInset * 2
        let slotWidth = availableWidth / CGFloat(max(overlapTotalColumns, 1))
        let xOffset = baseX + slotWidth * CGFloat(overlapColumn)
        let eventWidth = slotWidth - (overlapTotalColumns > 1 ? 1 : 0) // 1pt gap between side-by-side events
        let eventURI = ideaURI(idea)
        let isHovered = hoveredEventURI == eventURI
        let isResizing = activeResizeDrag?.ideaURI == eventURI
        let isDragging = activeIdeaDrag?.ideaURI == eventURI
        let cardHeight = max(blockHeight, 22)
        let startMinutes = (timeComponents(for: idea)?.hour ?? 0) * 60 + (timeComponents(for: idea)?.minute ?? 0)

        let card = VStack(alignment: .leading, spacing: 1) {
            Text(idea.text)
                .font(.custom("Switzer-Medium", size: 11))
                .foregroundStyle(Color.fg.opacity(idea.isDone ? 0.3 : 0.85))
                .strikethrough(idea.isDone)
                .lineLimit(blockHeight > 40 ? 2 : 1)

            if let time = idea.dueTime, blockHeight > 30 {
                Text(formatTime(time))
                    .font(.custom("Switzer-Light", size: 10))
                    .foregroundStyle(Color.fg.opacity(0.4))
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .frame(width: eventWidth, height: cardHeight, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(color.opacity(0.15))
                .overlay(alignment: .leading) {
                    UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 4)
                        .fill(color)
                        .frame(width: 3)
                }
        )
        .contentShape(RoundedRectangle(cornerRadius: 4))
        .onTapGesture { onSelectIdea?(idea) }
        .opacity(isDragging ? 0.0 : 1.0)
        .gesture(ideaDragGesture(
            idea: idea,
            originDayIndex: columnIndex,
            originStartMinutes: startMinutes,
            durationMinutes: idea.scheduledDurationMinutes,
            columnWidth: columnWidth,
            dayCount: dayCount
        ))

        return ZStack(alignment: .bottom) {
            card

            resizeHandle(for: idea, isVisible: isHovered || isResizing)
        }
        .frame(width: eventWidth, height: cardHeight, alignment: .top)
        .contentShape(RoundedRectangle(cornerRadius: 4))
        #if os(macOS)
        .onHover { hovering in
            hoveredEventURI = hovering ? eventURI : (hoveredEventURI == eventURI ? nil : hoveredEventURI)
            if hovering {
                hoveredSlot = nil
            }
        }
        #endif
        .offset(x: xOffset, y: topOffset)
        .contextMenu {
            ideaContextMenu(idea)
        }
    }

    private func resizeHandle(for idea: Idea, isVisible: Bool) -> some View {
        ZStack {
            Color.clear.frame(height: 12)

            Capsule()
                .fill(Color.fg.opacity(isVisible ? 0.3 : 0.12))
                .frame(width: 40, height: 4)
                .padding(.bottom, 3)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        #if os(macOS)
        .onHover { hovering in
            if hovering {
                NSCursor.resizeUpDown.push()
            } else {
                NSCursor.pop()
            }
        }
        #endif
        .highPriorityGesture(resizeGesture(for: idea))
    }

    private func appleCalendarResizeHandle(for event: AppleCalendarEvent, isVisible: Bool) -> some View {
        ZStack {
            Color.clear.frame(height: 12)

            Capsule()
                .fill(Color.fg.opacity(isVisible ? 0.3 : 0.12))
                .frame(width: 40, height: 4)
                .padding(.bottom, 3)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        #if os(macOS)
        .onHover { hovering in
            if hovering {
                NSCursor.resizeUpDown.push()
            } else {
                NSCursor.pop()
            }
        }
        #endif
        .highPriorityGesture(appleCalendarResizeGesture(for: event))
    }

    private func resizeGesture(for idea: Idea) -> some Gesture {
        let eventURI = ideaURI(idea)
        let baseDurationMinutes = idea.scheduledDurationMinutes

        return DragGesture(minimumDistance: 1)
            .updating($activeResizeDrag) { value, state, transaction in
                transaction.animation = nil
                state = ResizeDragState(
                    ideaURI: eventURI,
                    translationHeight: value.translation.height,
                    baseDurationMinutes: baseDurationMinutes
                )
            }
            .onEnded { value in
                idea.durationMinutes = resizedDurationMinutes(
                    baseDurationMinutes: baseDurationMinutes,
                    idea: idea,
                    translationHeight: value.translation.height
                )
                try? modelContext.save()
                AppleCalendarManager.shared.syncIdea(idea, enabled: appleCalendarSyncEnabled)
            }
    }

    private func appleCalendarResizeGesture(for event: AppleCalendarEvent) -> some Gesture {
        let baseDurationMinutes = max(Int(event.endDate.timeIntervalSince(event.startDate) / 60), minuteIncrement)

        return DragGesture(minimumDistance: 1)
            .updating($activeAppleResizeDrag) { value, state, transaction in
                transaction.animation = nil
                state = AppleResizeDragState(
                    eventIdentity: event.id,
                    translationHeight: value.translation.height,
                    baseDurationMinutes: baseDurationMinutes
                )
            }
            .onEnded { value in
                let durationMinutes = resizedDurationMinutes(
                    baseDurationMinutes: baseDurationMinutes,
                    startMinutes: cal.component(.hour, from: event.startDate) * 60 + cal.component(.minute, from: event.startDate),
                    translationHeight: value.translation.height
                )
                _ = appleCalendarManager.updateEvent(event, title: nil, startDate: nil, durationMinutes: durationMinutes)
                refreshAppleCalendar(for: weekDays)
            }
    }

    private func eventPosition(_ idea: Idea) -> (topOffset: CGFloat, height: CGFloat) {
        guard let timeStr = idea.dueTime,
              timeStr.count == 5,
              let hour = Int(timeStr.prefix(2)),
              let minute = Int(timeStr.suffix(2)) else {
            return (0, hourHeight)
        }
        let top = yOffset(forHour: hour, minute: minute)
        let height = height(forDurationMinutes: idea.scheduledDurationMinutes)
        return (top, height)
    }

    private func resizePreview(days: [Date]) -> some View {
        GeometryReader { geo in
            guard let resizeDrag = activeResizeDrag,
                  let idea = findIdea(uri: resizeDrag.ideaURI),
                  let dueDate = idea.dueDate,
                  let dayIdx = days.firstIndex(where: { cal.isDate($0, inSameDayAs: dueDate) }),
                  let (hour, minute) = timeComponents(for: idea)
            else { return AnyView(EmptyView()) }

            let totalWidth = geo.size.width - timeGutterWidth
            let columnWidth = dayColumnWidth(totalWidth: totalWidth, dayCount: days.count)
            let xOffset = dayColumnXOffset(columnIndex: dayIdx, totalWidth: totalWidth, dayCount: days.count)
            let previewY = yOffset(forHour: hour, minute: minute)
            let previewDuration = resizedDurationMinutes(
                baseDurationMinutes: resizeDrag.baseDurationMinutes,
                idea: idea,
                translationHeight: resizeDrag.translationHeight
            )
            let previewHeight = height(forDurationMinutes: previewDuration)
            let color = eventColor(for: idea)

            return AnyView(
                RoundedRectangle(cornerRadius: 4)
                    .fill(color.opacity(0.1))
                    .frame(width: columnWidth - eventColumnInset * 2, height: previewHeight)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(color.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    )
                    .overlay(alignment: .bottom) {
                        Capsule()
                            .fill(color.opacity(0.8))
                            .frame(width: 40, height: 4)
                            .padding(.bottom, 3)
                    }
                    .offset(x: xOffset + eventColumnInset, y: previewY)
                    .allowsHitTesting(false)
            )
        }
    }

    private func appleCalendarResizePreview(days: [Date]) -> some View {
        GeometryReader { geo in
            guard let resizeDrag = activeAppleResizeDrag,
                  let event = appleCalendarManager.visibleEvents.first(where: { $0.id == resizeDrag.eventIdentity }),
                  let dayIdx = days.firstIndex(where: { cal.isDate($0, inSameDayAs: event.startDate) })
            else { return AnyView(EmptyView()) }

            let totalWidth = geo.size.width - timeGutterWidth
            let columnWidth = dayColumnWidth(totalWidth: totalWidth, dayCount: days.count)
            let xOffset = dayColumnXOffset(columnIndex: dayIdx, totalWidth: totalWidth, dayCount: days.count)
            let previewY = yOffset(forHour: cal.component(.hour, from: event.startDate), minute: cal.component(.minute, from: event.startDate))
            let previewDuration = resizedDurationMinutes(
                baseDurationMinutes: resizeDrag.baseDurationMinutes,
                startMinutes: cal.component(.hour, from: event.startDate) * 60 + cal.component(.minute, from: event.startDate),
                translationHeight: resizeDrag.translationHeight
            )
            let previewHeight = height(forDurationMinutes: previewDuration)

            return AnyView(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.fg.opacity(0.08))
                    .frame(width: columnWidth - eventColumnInset * 2, height: previewHeight)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.fg.opacity(0.2), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    )
                    .overlay(alignment: .bottom) {
                        Capsule()
                            .fill(Color.fg.opacity(0.8))
                            .frame(width: 40, height: 4)
                            .padding(.bottom, 3)
                    }
                    .offset(x: xOffset + eventColumnInset, y: previewY)
                    .allowsHitTesting(false)
            )
        }
    }

    // MARK: - Drag Helpers

    private func ideaTransfer(_ idea: Idea) -> IdeaTransfer {
        IdeaTransfer(uriRepresentation: idea.persistentModelID.hashValue.description)
    }

    private func appleCalendarEventTransfer(_ event: AppleCalendarEvent) -> AppleCalendarEventTransfer {
        AppleCalendarEventTransfer(identifier: event.id)
    }

    private func ideaDragGesture(
        idea: Idea,
        originDayIndex: Int,
        originStartMinutes: Int,
        durationMinutes: Int,
        columnWidth: CGFloat,
        dayCount: Int
    ) -> some Gesture {
        let eventURI = ideaURI(idea)

        return DragGesture(minimumDistance: 2)
            .updating($activeIdeaDrag) { value, state, transaction in
                transaction.animation = nil
                let translation = value.translation
                state = IdeaDragState(
                    ideaURI: eventURI,
                    originDayIndex: originDayIndex,
                    originStartMinutes: originStartMinutes,
                    durationMinutes: durationMinutes,
                    translation: translation
                )

                if let slot = draggedTimeSlot(
                    translation: translation,
                    originDayIndex: originDayIndex,
                    originStartMinutes: originStartMinutes,
                    days: weekDays,
                    columnWidth: columnWidth,
                    dayCount: dayCount
                ) {
                    dropTargetSlot = slot
                    draggedIdeaURI = eventURI
                    draggedDurationMinutes = durationMinutes
                }
            }
            .onEnded { value in
                defer { clearDraggedState() }
                guard let slot = draggedTimeSlot(
                    translation: value.translation,
                    originDayIndex: originDayIndex,
                    originStartMinutes: originStartMinutes,
                    days: weekDays,
                    columnWidth: columnWidth,
                    dayCount: dayCount
                ) else {
                    return
                }
                moveIdea(idea, toDate: slot.date, hour: slot.hour, minute: slot.minute)
            }
    }

    private func appleCalendarEventDragGesture(
        event: AppleCalendarEvent,
        originDayIndex: Int,
        originStartMinutes: Int,
        durationMinutes: Int,
        columnWidth: CGFloat,
        dayCount: Int
    ) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .updating($activeAppleEventDrag) { value, state, transaction in
                transaction.animation = nil
                let translation = value.translation
                state = AppleEventDragState(
                    eventIdentity: event.id,
                    originDayIndex: originDayIndex,
                    originStartMinutes: originStartMinutes,
                    durationMinutes: durationMinutes,
                    translation: translation
                )

                if let slot = appleEventDropSlot(
                    translation: translation,
                    originDayIndex: originDayIndex,
                    originStartMinutes: originStartMinutes,
                    days: weekDays,
                    columnWidth: columnWidth,
                    dayCount: dayCount
                ) {
                    dropTargetSlot = slot
                    draggedIdeaURI = nil
                    draggedDurationMinutes = durationMinutes
                }
            }
            .onEnded { value in
                defer { clearDraggedState() }
                guard let slot = appleEventDropSlot(
                    translation: value.translation,
                    originDayIndex: originDayIndex,
                    originStartMinutes: originStartMinutes,
                    days: weekDays,
                    columnWidth: columnWidth,
                    dayCount: dayCount
                ) else {
                    return
                }
                moveAppleCalendarEvent(event, toDate: slot.date, hour: slot.hour, minute: slot.minute, durationMinutes: durationMinutes)
            }
    }

    private func appleEventDropSlot(
        translation: CGSize,
        originDayIndex: Int,
        originStartMinutes: Int,
        days: [Date],
        columnWidth: CGFloat,
        dayCount: Int
    ) -> TimeSlot? {
        draggedTimeSlot(
            translation: translation,
            originDayIndex: originDayIndex,
            originStartMinutes: originStartMinutes,
            days: days,
            columnWidth: columnWidth,
            dayCount: dayCount
        )
    }

    private func draggedTimeSlot(
        translation: CGSize,
        originDayIndex: Int,
        originStartMinutes: Int,
        days: [Date],
        columnWidth: CGFloat,
        dayCount: Int
    ) -> TimeSlot? {
        guard !days.isEmpty else { return nil }
        let minuteShift = Int((translation.height / hourHeight) * 60.0)
        let snappedMinuteShift = Int((Double(minuteShift) / Double(minuteIncrement)).rounded()) * minuteIncrement

        let dayWidth = columnWidth + dayDividerWidth
        let dayShift = Int((translation.width / max(dayWidth, 1)).rounded())
        let targetDayIndex = min(max(originDayIndex + dayShift, 0), days.count - 1)

        let rawMinutes = originStartMinutes + snappedMinuteShift
        let clampedMinutes = min(max(rawMinutes, startHour * 60), endHour * 60 - minuteIncrement)
        let snappedMinutes = (clampedMinutes / minuteIncrement) * minuteIncrement
        let hour = snappedMinutes / 60
        let minute = snappedMinutes % 60

        return TimeSlot(date: days[targetDayIndex], hour: hour, minute: minute)
    }

    private func dragPreview(_ idea: Idea) -> some View {
        let color = eventColor(for: idea)
        return HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(color)
                .frame(width: 3, height: 18)
            Text(idea.text)
                .font(.custom("Switzer-Medium", size: 12))
                .foregroundStyle(Color.fg.opacity(0.7))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.bgCard)
                .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
        )
        .onAppear {
            draggedIdeaURI = ideaURI(idea)
            draggedDurationMinutes = idea.scheduledDurationMinutes
        }
    }

    private func appleCalendarDragPreview(_ event: AppleCalendarEvent) -> some View {
        let durationMinutes = max(Int(event.endDate.timeIntervalSince(event.startDate) / 60), minuteIncrement)
        return HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.fg.opacity(0.4))
                .frame(width: 3, height: 18)
            Text(event.title)
                .font(.custom("Switzer-Medium", size: 12))
                .foregroundStyle(Color.fg.opacity(0.7))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.bgCard)
                .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
        )
        .onAppear {
            draggedIdeaURI = nil
            draggedDurationMinutes = durationMinutes
        }
    }

    private func moveIdea(_ idea: Idea, toDate date: Date, hour: Int?, minute: Int? = nil) {
        if let hour {
            let resolvedMinute = minute ?? 0
            idea.dueDate = cal.date(bySettingHour: hour, minute: resolvedMinute, second: 0, of: date)
            idea.dueTime = String(format: "%02d:%02d", hour, resolvedMinute)
            if idea.durationMinutes == nil {
                idea.durationMinutes = defaultTimedDurationMinutes
            }
        } else {
            idea.dueDate = cal.startOfDay(for: date)
            idea.dueTime = nil
            idea.durationMinutes = nil
        }
        if draggedIdeaURI == ideaURI(idea) {
            draggedDurationMinutes = idea.scheduledDurationMinutes
        }
        try? modelContext.save()
        AppleCalendarManager.shared.syncIdea(idea, enabled: appleCalendarSyncEnabled)
    }

    private func moveAppleCalendarEvent(_ event: AppleCalendarEvent, toDate date: Date, hour: Int, minute: Int, durationMinutes: Int) {
        guard let targetDate = cal.date(bySettingHour: hour, minute: minute, second: 0, of: date) else { return }
        guard appleCalendarManager.updateEvent(event, title: nil, startDate: targetDate, durationMinutes: durationMinutes) else {
            return
        }
        refreshAppleCalendar(for: weekDays)
    }

    private func openQuickAdd(at date: Date) {
        let hour = cal.component(.hour, from: date)
        let minute = cal.component(.minute, from: date)
        let snappedMinute = (minute / minuteIncrement) * minuteIncrement
        guard let targetDate = cal.date(bySettingHour: hour, minute: snappedMinute, second: 0, of: date) else { return }

        quickAddDate = targetDate
        quickAddText = ""
        showQuickAdd = true
        quickAddFocused = true
        syncQuickAddTimesFromDate()
    }

    // MARK: - Now Indicator

    private func nowIndicator(days: [Date]) -> some View {
        GeometryReader { geo in
            let now = Date()
            let hour = cal.component(.hour, from: now)
            let minute = cal.component(.minute, from: now)
            let lineY = yOffset(forHour: hour, minute: minute)
            let totalWidth = geo.size.width - timeGutterWidth
            let columnWidth = dayColumnWidth(totalWidth: totalWidth, dayCount: days.count)

            if let todayIdx = days.firstIndex(where: { cal.isDateInToday($0) }) {
                let xOffset = dayColumnXOffset(columnIndex: todayIdx, totalWidth: totalWidth, dayCount: days.count)

                HStack(spacing: 0) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                        .offset(x: -4)

                    Rectangle()
                        .fill(Color.red.opacity(0.6))
                        .frame(width: columnWidth, height: 1)
                }
                .offset(x: xOffset, y: lineY - 4)
            }
        }
        .allowsHitTesting(false)
    }

    private func ideaDragPreview(days: [Date]) -> some View {
        GeometryReader { geo in
            guard let drag = activeIdeaDrag,
                  let idea = findIdea(uri: drag.ideaURI),
                  let slot = draggedTimeSlot(
                    translation: drag.translation,
                    originDayIndex: drag.originDayIndex,
                    originStartMinutes: drag.originStartMinutes,
                    days: days,
                    columnWidth: dayColumnWidth(totalWidth: geo.size.width - timeGutterWidth, dayCount: days.count),
                    dayCount: days.count
                  ),
                  let dayIdx = days.firstIndex(where: { cal.isDate($0, inSameDayAs: slot.date) })
            else { return AnyView(EmptyView()) }

            let totalWidth = geo.size.width - timeGutterWidth
            let columnWidth = dayColumnWidth(totalWidth: totalWidth, dayCount: days.count)
            let xOffset = dayColumnXOffset(columnIndex: dayIdx, totalWidth: totalWidth, dayCount: days.count)
            let previewY = yOffset(forHour: slot.hour, minute: slot.minute)
            let previewHeight = height(forDurationMinutes: drag.durationMinutes)
            let color = eventColor(for: idea)

            return AnyView(
                RoundedRectangle(cornerRadius: 4)
                    .fill(color.opacity(0.15))
                    .frame(width: columnWidth - eventColumnInset * 2, height: previewHeight)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(color.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    )
                    .overlay(alignment: .leading) {
                        UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 4)
                            .fill(color)
                            .frame(width: 3)
                    }
                    .overlay(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(idea.text)
                                .font(.custom("Switzer-Medium", size: 11))
                                .foregroundStyle(Color.fg.opacity(0.85))
                                .lineLimit(previewHeight > 40 ? 2 : 1)

                            if previewHeight > 30 {
                                Text(formatTime(slot.date))
                                    .font(.custom("Switzer-Light", size: 10))
                                    .foregroundStyle(Color.fg.opacity(0.4))
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                    }
                    .offset(x: xOffset + eventColumnInset, y: previewY)
            )
        }
        .allowsHitTesting(false)
    }

    // MARK: - Month View

    private var monthView: some View {
        let days = daysInMonthGrid()
        let dayMap = ideasByDayMap()
        let rowCount = max(days.count / 7, 1)

        return VStack(spacing: 0) {
            monthWeekdayHeaders

            GeometryReader { geo in
                let rowHeight = geo.size.height / CGFloat(rowCount)

                VStack(spacing: 0) {
                    ForEach(0..<rowCount, id: \.self) { row in
                        HStack(spacing: 0) {
                            ForEach(0..<7, id: \.self) { col in
                                let index = row * 7 + col
                                let date = index < days.count ? days[index] : nil
                                monthDayCell(date: date, ideasMap: dayMap, cellHeight: rowHeight)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                                if col < 6 {
                                    Rectangle()
                                        .fill(Color.fg.opacity(0.06))
                                        .frame(width: 1)
                                }
                            }
                        }
                        .frame(height: rowHeight)

                        if row < rowCount - 1 {
                            Rectangle()
                                .fill(Color.fg.opacity(0.06))
                                .frame(height: 1)
                        }
                    }
                }
            }
        }
        .task(id: appleCalendarRefreshKey(days: days.compactMap { $0 })) {
            refreshAppleCalendar(for: days.compactMap { $0 })
        }
    }

    private var monthWeekdayHeaders: some View {
        let symbols = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        return HStack(spacing: 0) {
            ForEach(symbols, id: \.self) { symbol in
                Text(symbol)
                    .font(.custom("Switzer-Medium", size: 11))
                    .foregroundStyle(Color.fg.opacity(0.35))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.fg.opacity(0.06))
                .frame(height: 1)
        }
    }

    /// A unified event row for month view — represents either an Idea or an Apple Calendar event.
    private struct MonthEvent: Identifiable {
        let id: String
        let title: String
        let time: String?  // formatted time string e.g. "2:30 PM"
        let color: Color
        let sortKey: String // HH:mm for sorting
        let idea: Idea?
        let isAppleEvent: Bool
    }

    private func monthEventsForDate(_ date: Date, ideasMap: [Date: [Idea]]) -> [MonthEvent] {
        let dayKey = cal.startOfDay(for: date)
        let dayIdeas = ideasMap[dayKey] ?? []

        var events: [MonthEvent] = dayIdeas.map { idea in
            let timeStr: String? = {
                guard let t = idea.dueTime, t.count == 5,
                      let h = Int(t.prefix(2)), let m = Int(t.suffix(2)) else { return nil }
                let period = h < 12 ? "AM" : "PM"
                let displayH = h == 0 ? 12 : (h > 12 ? h - 12 : h)
                return "\(displayH):\(String(format: "%02d", m)) \(period)"
            }()
            return MonthEvent(
                id: "idea-\(idea.persistentModelID)",
                title: idea.text,
                time: timeStr,
                color: eventColor(for: idea),
                sortKey: idea.dueTime ?? "99:99",
                idea: idea,
                isAppleEvent: false
            )
        }

        let appleEvents = appleCalendarManager.visibleEvents.filter {
            !$0.isAllDay && cal.isDate($0.startDate, inSameDayAs: date)
        }
        for event in appleEvents {
            let h = cal.component(.hour, from: event.startDate)
            let m = cal.component(.minute, from: event.startDate)
            let period = h < 12 ? "AM" : "PM"
            let displayH = h == 0 ? 12 : (h > 12 ? h - 12 : h)
            let timeStr = "\(displayH):\(String(format: "%02d", m)) \(period)"
            let sortKey = String(format: "%02d:%02d", h, m)
            events.append(MonthEvent(
                id: "apple-\(event.id)",
                title: event.title,
                time: timeStr,
                color: Color.fg.opacity(0.5),
                sortKey: sortKey,
                idea: nil,
                isAppleEvent: true
            ))
        }

        return events.sorted { $0.sortKey < $1.sortKey }
    }

    private func monthDayCell(date: Date?, ideasMap: [Date: [Idea]], cellHeight: CGFloat) -> some View {
        Group {
            if let date {
                let isToday = cal.isDateInToday(date)
                let inMonth = cal.isDate(date, equalTo: displayedDate, toGranularity: .month)
                let events = monthEventsForDate(date, ideasMap: ideasMap)
                // Each event row is ~16pt, day number ~24pt, padding ~6pt
                let maxVisibleEvents = max(Int((cellHeight - 30) / 16), 1)

                VStack(alignment: .leading, spacing: 0) {
                    // Day number — right-aligned like Google Calendar
                    HStack {
                        Spacer()

                        // Show "Mon X" format for first day or first of month
                        if cal.component(.day, from: date) == 1 {
                            Text(monthDayCellDateString(date))
                                .font(.custom("Switzer-Medium", size: 11))
                                .foregroundStyle(isToday ? Color.bgBase : Color.fg.opacity(inMonth ? 0.5 : 0.15))
                        }

                        Text("\(cal.component(.day, from: date))")
                            .font(.custom("Switzer-Semibold", size: 12))
                            .foregroundStyle(isToday ? Color.bgBase : Color.fg.opacity(inMonth ? 0.6 : 0.15))
                            .frame(width: 24, height: 24)
                            .background(
                                Circle().fill(isToday ? Color.fg : Color.clear)
                            )
                    }
                    .padding(.top, 4)
                    .padding(.trailing, 4)
                    .padding(.bottom, 2)

                    // Event rows
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(events.prefix(maxVisibleEvents)) { event in
                            monthEventRow(event: event)
                        }
                        if events.count > maxVisibleEvents {
                            Text("+\(events.count - maxVisibleEvents) more")
                                .font(.custom("Switzer-Medium", size: 9))
                                .foregroundStyle(Color.fg.opacity(0.25))
                                .padding(.leading, 4)
                                .padding(.top, 1)
                        }
                    }
                    .padding(.horizontal, 2)

                    Spacer(minLength: 0)
                }
                .background(Color.bgDeep.opacity(inMonth ? 1 : 0.4))
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        displayedDate = date
                        viewMode = .week
                    }
                }
                .dropDestination(for: IdeaTransfer.self) { items, _ in
                    guard let item = items.first,
                          let idea = findIdea(uri: item.uriRepresentation) else { return false }
                    moveIdea(idea, toDate: date, hour: nil)
                    return true
                }
            } else {
                Color.bgDeep.opacity(0.2)
            }
        }
    }

    private func monthEventRow(event: MonthEvent) -> some View {
        Button {
            if let idea = event.idea {
                onSelectIdea?(idea)
            }
        } label: {
            HStack(spacing: 0) {
                // Color indicator
                RoundedRectangle(cornerRadius: 1)
                    .fill(event.color)
                    .frame(width: 3, height: 12)
                    .padding(.trailing, 3)

                // Title
                Text(event.title)
                    .font(.custom("Switzer-Regular", size: 10))
                    .foregroundStyle(Color.fg.opacity(event.isAppleEvent ? 0.5 : 0.7))
                    .lineLimit(1)

                Spacer(minLength: 2)

                // Time
                if let time = event.time {
                    Text(time)
                        .font(.custom("Switzer-Light", size: 9))
                        .foregroundStyle(Color.fg.opacity(0.3))
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 1)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let idea = event.idea {
                ideaContextMenu(idea)
            }
        }
    }

    private static let monthDayCellFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM"
        return fmt
    }()

    private func monthDayCellDateString(_ date: Date) -> String {
        Self.monthDayCellFormatter.string(from: date)
    }

    // MARK: - Quick Add Overlay

    private var availableTags: [String] {
        profiles.first?.verifiedTags ?? []
    }

    private var filteredQuickLinkIdeas: [Idea] {
        let query = quickAddLinkSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return allIdeas
            .filter { $0.modelContext != nil }
            .filter { idea in
                guard !query.isEmpty else { return true }
                if idea.text.lowercased().contains(query) { return true }
                return idea.visibleTags.contains { $0.localizedCaseInsensitiveContains(query) }
            }
            .sorted { lhs, rhs in
                if lhs.isDone != rhs.isDone {
                    return !lhs.isDone && rhs.isDone
                }
                return lhs.createdAt > rhs.createdAt
            }
    }

    private var quickAddOverlay: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture {
                    dismissQuickAdd()
                }

            VStack(alignment: .leading, spacing: -1) {
                // Folder tabs — flush with card left edge, overlap card by 1pt
                HStack(spacing: 0) {
                    ForEach(QuickAddMode.allCases, id: \.self) { mode in
                        let isActive = quickAddMode == mode
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                quickAddMode = mode
                                quickAddFocused = mode == .new
                            }
                        } label: {
                            Text(mode.rawValue)
                                .font(.custom("Switzer-Semibold", size: 11))
                                .foregroundStyle(isActive ? Color.fg.opacity(0.85) : Color.fg.opacity(0.35))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(
                                    UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 10)
                                        .fill(isActive ? Color.bgElevated : Color.fg.opacity(0.12))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .zIndex(1) // tabs render above card edge

                // Card body
                VStack(alignment: .leading, spacing: 0) {
                    if quickAddMode == .new {
                        // Kind selector (idea / calendar item)
                        HStack(spacing: 8) {
                            ForEach(QuickAddNewKind.allCases, id: \.self) { kind in
                                Button {
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        quickAddNewKind = kind
                                    }
                                } label: {
                                    Text(kind.rawValue)
                                        .font(.custom("Switzer-Medium", size: 11))
                                        .foregroundStyle(quickAddNewKind == kind ? Color.fg.opacity(0.85) : Color.fg.opacity(0.3))
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(
                                            Capsule()
                                                .fill(quickAddNewKind == kind ? Color.fg.opacity(0.1) : Color.clear)
                                        )
                                        .overlay(
                                            Capsule()
                                                .stroke(quickAddNewKind == kind ? Color.fg.opacity(0.12) : Color.fg.opacity(0.06), lineWidth: 1)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                        .padding(.bottom, 14)

                        // Text input
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(quickAddAccentColor)
                                .frame(width: 3, height: 22)

                            TextField(quickAddNewKind == .idea ? "what's the idea?" : "what's the calendar item?", text: $quickAddText)
                                .font(.custom("Switzer-Regular", size: 15))
                                .textFieldStyle(.plain)
                                .focused($quickAddFocused)
                                .onSubmit { submitQuickAdd() }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 18)

                        // Time row — date + start/end selectors
                        quickAddTimeSection
                            .padding(.horizontal, 20)
                            .padding(.bottom, 16)

                        // Tag selector (ideas only)
                        if quickAddNewKind == .idea && !availableTags.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("tag")
                                    .font(.custom("Switzer-Medium", size: 10))
                                    .foregroundStyle(Color.fg.opacity(0.25))
                                    .textCase(.uppercase)
                                    .tracking(0.5)

                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 6) {
                                        quickAddTagChip(tag: nil, label: "none")
                                        ForEach(availableTags, id: \.self) { tag in
                                            quickAddTagChip(tag: tag, label: tag)
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 20)
                            .padding(.bottom, 16)
                        }

                        if quickAddNewKind == .calendarItem && !appleCalendarManager.hasFullAccess {
                            Text("connect apple calendar in settings to create standalone calendar items")
                                .font(.custom("Switzer-Medium", size: 11))
                                .foregroundStyle(Color.fg.opacity(0.35))
                                .padding(.horizontal, 20)
                                .padding(.bottom, 16)
                        }
                    } else {
                        // Link mode
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("search ideas", text: $quickAddLinkSearch)
                                .font(.custom("Switzer-Regular", size: 14))
                                .textFieldStyle(.plain)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.fg.opacity(0.04))
                                )

                            ScrollView {
                                LazyVStack(spacing: 8) {
                                    ForEach(filteredQuickLinkIdeas, id: \.persistentModelID) { idea in
                                        quickLinkIdeaRow(idea)
                                    }

                                    if filteredQuickLinkIdeas.isEmpty {
                                        Text("no ideas found")
                                            .font(.custom("Switzer-Medium", size: 12))
                                            .foregroundStyle(Color.fg.opacity(0.3))
                                            .frame(maxWidth: .infinity, alignment: .center)
                                            .padding(.vertical, 20)
                                    }
                                }
                            }
                            .frame(minHeight: 240, maxHeight: 320)
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                        .padding(.bottom, 16)
                    }

                // Footer separator
                Rectangle()
                    .fill(Color.fg.opacity(0.06))
                    .frame(maxWidth: .infinity)
                    .frame(height: 1)

                // Action bar
                HStack {
                    Button {
                        dismissQuickAdd()
                    } label: {
                        Text("cancel")
                            .font(.custom("Switzer-Medium", size: 13))
                            .foregroundStyle(Color.fg.opacity(0.35))
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button { submitQuickAdd() } label: {
                        HStack(spacing: 6) {
                            Text(quickAddSubmitLabel)
                                .font(.custom("Switzer-Semibold", size: 13))
                            Image(systemName: "return")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundStyle(quickAddSubmitEnabled ? Color.fg.opacity(0.9) : Color.fg.opacity(0.2))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(quickAddSubmitEnabled ? quickAddAccentColor.opacity(0.15) : Color.fg.opacity(0.04))
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!quickAddSubmitEnabled)
                }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                }
                .background(
                    UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 14, bottomTrailingRadius: 14, topTrailingRadius: 14)
                        .fill(Color.bgElevated)
                )
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 14, bottomTrailingRadius: 14, topTrailingRadius: 14))
                .shadow(color: .black.opacity(0.3), radius: 30, y: 15)
            }
            .frame(maxWidth: 420, alignment: .leading)
            .padding(.horizontal, 32)
        }
    }

    // MARK: - Time section with start/end selectors

    private var quickAddTimeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Date label
            if let date = quickAddDate {
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.fg.opacity(0.3))
                    Text(quickAddDayString(date))
                        .font(.custom("Switzer-Medium", size: 12))
                        .foregroundStyle(Color.fg.opacity(0.45))
                }
            }

            // Start / End time row
            HStack(spacing: 0) {
                // Start time
                VStack(alignment: .leading, spacing: 4) {
                    Text("start")
                        .font(.custom("Switzer-Medium", size: 9))
                        .foregroundStyle(Color.fg.opacity(0.25))
                        .textCase(.uppercase)
                        .tracking(0.5)

                    quickAddTimePicker(hour: $quickAddStartHour, minute: $quickAddStartMinute, onChange: quickAddStartTimeChanged)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.fg.opacity(0.2))
                    .padding(.top, 14)

                // End time
                VStack(alignment: .trailing, spacing: 4) {
                    Text("end")
                        .font(.custom("Switzer-Medium", size: 9))
                        .foregroundStyle(Color.fg.opacity(0.25))
                        .textCase(.uppercase)
                        .tracking(0.5)

                    quickAddTimePicker(hour: $quickAddEndHour, minute: $quickAddEndMinute, onChange: quickAddEndTimeChanged)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.fg.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.fg.opacity(0.06), lineWidth: 1)
            )
        }
    }

    private func quickAddTimePicker(hour: Binding<Int>, minute: Binding<Int>, onChange: @escaping () -> Void) -> some View {
        Menu {
            ForEach(0..<24, id: \.self) { h in
                ForEach([0, 15, 30, 45], id: \.self) { m in
                    Button {
                        hour.wrappedValue = h
                        minute.wrappedValue = m
                        onChange()
                    } label: {
                        Text(formatTime12(hour: h, minute: m))
                    }
                }
            }
        } label: {
            Text(formatTime12(hour: hour.wrappedValue, minute: minute.wrappedValue))
                .font(.custom("Switzer-Semibold", size: 14))
                .foregroundStyle(Color.fg.opacity(0.75))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.fg.opacity(0.05))
                )
        }
        .buttonStyle(.plain)
    }

    private func formatTime12(hour: Int, minute: Int) -> String {
        let period = hour < 12 ? "AM" : "PM"
        let displayHour = hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour)
        return String(format: "%d:%02d %@", displayHour, minute, period)
    }

    private static let quickAddDayFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "EEEE, MMM d"
        return fmt
    }()

    private func quickAddDayString(_ date: Date) -> String {
        Self.quickAddDayFormatter.string(from: date).lowercased()
    }

    private func quickAddStartTimeChanged() {
        // Recompute duration from start/end, minimum 15 minutes
        let startTotal = quickAddStartHour * 60 + quickAddStartMinute
        var endTotal = quickAddEndHour * 60 + quickAddEndMinute
        if endTotal <= startTotal {
            endTotal = startTotal + 60
            quickAddEndHour = endTotal / 60
            quickAddEndMinute = endTotal % 60
        }
        quickAddDuration = endTotal - startTotal

        // Update quickAddDate to reflect new start time
        if let date = quickAddDate {
            var components = cal.dateComponents([.year, .month, .day], from: date)
            components.hour = quickAddStartHour
            components.minute = quickAddStartMinute
            quickAddDate = cal.date(from: components) ?? date
        }
    }

    private func quickAddEndTimeChanged() {
        let startTotal = quickAddStartHour * 60 + quickAddStartMinute
        var endTotal = quickAddEndHour * 60 + quickAddEndMinute
        if endTotal <= startTotal {
            endTotal = startTotal + 15
            quickAddEndHour = endTotal / 60
            quickAddEndMinute = endTotal % 60
        }
        quickAddDuration = endTotal - startTotal
    }

    private func syncQuickAddTimesFromDate() {
        guard let date = quickAddDate else { return }
        quickAddStartHour = cal.component(.hour, from: date)
        quickAddStartMinute = cal.component(.minute, from: date)
        let endTotal = quickAddStartHour * 60 + quickAddStartMinute + quickAddDuration
        quickAddEndHour = min(endTotal / 60, 23)
        quickAddEndMinute = endTotal % 60
    }

    private var quickAddAccentColor: Color {
        if let tag = quickAddSelectedTag,
           let hex = tagColors[tag],
           let color = Color.accent(hex: hex) {
            return color
        }
        return Color.fg.opacity(0.35)
    }

    private var quickAddSubmitEnabled: Bool {
        switch quickAddMode {
        case .new:
            let hasText = !quickAddText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            switch quickAddNewKind {
            case .idea:
                return hasText
            case .calendarItem:
                return hasText && appleCalendarManager.hasFullAccess
            }
        case .link:
            return false
        }
    }

    private var quickAddSubmitLabel: String {
        switch quickAddMode {
        case .new:
            switch quickAddNewKind {
            case .idea:
                return "add idea"
            case .calendarItem:
                return editingAppleCalendarEvent == nil ? "add event" : "save event"
            }
        case .link:
            return "link idea"
        }
    }

    private func selectableChip(
        label: String,
        isSelected: Bool,
        color: Color = Color.fg,
        showBorder: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { action() }
        } label: {
            Text(label)
                .font(.custom("Switzer-Medium", size: 11))
                .foregroundStyle(isSelected ? color.opacity(0.9) : Color.fg.opacity(0.35))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected ? color.opacity(0.15) : Color.fg.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isSelected && showBorder ? color.opacity(0.3) : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func quickAddTagChip(tag: String?, label: String) -> some View {
        let isSelected = quickAddSelectedTag == tag
        let chipColor: Color = {
            if let tag, let hex = tagColors[tag], let c = Color.accent(hex: hex) { return c }
            return Color.fg
        }()
        return selectableChip(label: label, isSelected: isSelected, color: chipColor, showBorder: true) {
            quickAddSelectedTag = tag
        }
    }

    private func quickLinkIdeaRow(_ idea: Idea) -> some View {
        Button {
            linkIdeaToQuickAddDate(idea)
        } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(eventColor(for: idea))
                    .frame(width: 3, height: 26)

                VStack(alignment: .leading, spacing: 4) {
                    Text(idea.text)
                        .font(.custom("Switzer-Medium", size: 13))
                        .foregroundStyle(Color.fg.opacity(0.82))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 6) {
                        if let firstTag = idea.visibleTags.first {
                            Text(firstTag)
                                .font(.custom("Switzer-Medium", size: 10))
                                .foregroundStyle(eventColor(for: idea).opacity(0.9))
                        }

                        if idea.dueDate != nil {
                            Text("scheduled")
                                .font(.custom("Switzer-Medium", size: 10))
                                .foregroundStyle(Color.fg.opacity(0.28))
                        }
                    }
                }

                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.fg.opacity(0.4))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.fg.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.fg.opacity(0.06), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func dismissQuickAdd() {
        showQuickAdd = false
        quickAddMode = .new
        quickAddNewKind = .idea
        editingAppleCalendarEvent = nil
        quickAddText = ""
        quickAddSelectedTag = nil
        quickAddDuration = 60
        quickAddStartHour = 16
        quickAddStartMinute = 0
        quickAddEndHour = 17
        quickAddEndMinute = 0
        quickAddLinkSearch = ""
    }

    private func submitQuickAdd() {
        switch quickAddMode {
        case .new:
            switch quickAddNewKind {
            case .idea:
                createQuickIdea()
            case .calendarItem:
                createQuickCalendarItem()
            }
        case .link:
            break
        }
    }

    private func createQuickIdea() {
        let trimmed = quickAddText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let date = quickAddDate else { return }

        let selectedTags: [String]? = quickAddSelectedTag.map { [$0] }

        if let ideasViewModel {
            ideasViewModel.addIdea(trimmed, scheduledAt: date, durationMinutes: quickAddDuration, tags: selectedTags)
        } else {
            let idea = Idea(text: trimmed)
            idea.dueDate = date
            idea.isProcessing = false

            let hour = cal.component(.hour, from: date)
            let minute = cal.component(.minute, from: date)
            idea.dueTime = String(format: "%02d:%02d", hour, minute)
            idea.durationMinutes = quickAddDuration

            if let tag = quickAddSelectedTag {
                idea.tags = [tag]
            }

            modelContext.insert(idea)
            try? modelContext.save()
        }

        dismissQuickAdd()
    }

    private func createQuickCalendarItem() {
        let trimmed = quickAddText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let date = quickAddDate else { return }

        let success: Bool
        if let event = editingAppleCalendarEvent {
            success = appleCalendarManager.updateEvent(
                event,
                title: trimmed,
                startDate: date,
                durationMinutes: quickAddDuration
            )
        } else {
            success = appleCalendarManager.createStandaloneEvent(
                title: trimmed,
                startDate: date,
                durationMinutes: quickAddDuration
            )
        }

        guard success else {
            return
        }

        refreshAppleCalendar(for: weekDays)
        dismissQuickAdd()
    }

    private func linkIdeaToQuickAddDate(_ idea: Idea) {
        guard let date = quickAddDate else { return }

        idea.dueDate = date
        let hour = cal.component(.hour, from: date)
        let minute = cal.component(.minute, from: date)
        idea.dueTime = String(format: "%02d:%02d", hour, minute)
        idea.durationMinutes = max(idea.durationMinutes ?? quickAddDuration, 15)

        try? modelContext.save()
        dismissQuickAdd()
    }

    // MARK: - Helpers

    private func eventColor(for idea: Idea) -> Color {
        idea.eventColor(from: tagColors)
    }

    private func hourLabel(_ hour: Int) -> String {
        if hour == 0 || hour == 24 { return "12 AM" }
        if hour == 12 { return "12 PM" }
        if hour < 12 { return "\(hour) AM" }
        return "\(hour - 12) PM"
    }

    private func formatTime(_ time: String) -> String {
        formatDueTime(time)
    }

    private static let dayOfWeekFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "EEE"
        return fmt
    }()

    private static let timeOfDayFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "h:mm a"
        return fmt
    }()

    private func dayOfWeekShort(_ date: Date) -> String {
        Self.dayOfWeekFormatter.string(from: date).uppercased()
    }

    private func formatTime(_ date: Date) -> String {
        Self.timeOfDayFormatter.string(from: date).lowercased()
    }

    @ViewBuilder
    private func ideaContextMenu(_ idea: Idea) -> some View {
        Button {
            onSelectIdea?(idea)
        } label: {
            Label("Open", systemImage: "arrow.up.right.square")
        }

        Button {
            idea.isDone.toggle()
            try? modelContext.save()
        } label: {
            Label(idea.isDone ? "Mark as active" : "Mark as done", systemImage: idea.isDone ? "circle" : "checkmark.circle")
        }

        if idea.dueDate != nil {
            if idea.dueTime == nil {
                Button {
                    moveIdea(idea, toDate: cal.startOfDay(for: idea.dueDate ?? Date()), hour: 9, minute: 0)
                } label: {
                    Label("Make timed", systemImage: "clock")
                }
            } else if let dueDate = idea.dueDate {
                Button {
                    moveIdea(idea, toDate: dueDate, hour: nil)
                } label: {
                    Label("Make all-day", systemImage: "calendar")
                }
            }

            Button {
                idea.dueDate = nil
                idea.dueTime = nil
                idea.durationMinutes = nil
                try? modelContext.save()
                AppleCalendarManager.shared.removeSyncedEvent(for: idea)
            } label: {
                Label("Remove from calendar", systemImage: "calendar.badge.minus")
            }
        }

        Divider()

        Button(role: .destructive) {
            ideaToDelete = idea
            showDeleteConfirm = true
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    @ViewBuilder
    private func appleCalendarEventContextMenu(_ event: AppleCalendarEvent) -> some View {
        Button {
            editAppleCalendarEvent(event)
        } label: {
            Label("Edit event", systemImage: "pencil")
        }

        if event.isAllDay {
            Button {
                makeAppleCalendarEventTimed(event)
            } label: {
                Label("Make timed", systemImage: "clock")
            }
        } else {
            Button {
                makeAppleCalendarEventAllDay(event)
            } label: {
                Label("Make all-day", systemImage: "calendar")
            }
        }

        Button {
            convertAppleCalendarEventToIdea(event)
        } label: {
            Label("Convert to idea", systemImage: "arrow.right.circle")
        }

        Divider()

        Button(role: .destructive) {
            deleteAppleCalendarEvent(event)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private func ideaURI(_ idea: Idea) -> String {
        idea.persistentModelID.hashValue.description
    }

    private func convertAppleCalendarEventToIdea(_ event: AppleCalendarEvent) {
        let durationMinutes = max(Int(event.endDate.timeIntervalSince(event.startDate) / 60), minuteIncrement)

        if let ideasViewModel {
            ideasViewModel.addIdea(
                event.title,
                scheduledAt: event.startDate,
                durationMinutes: durationMinutes,
                linkedAppleCalendarEventIdentifier: event.calendarItemIdentifier
            )
        } else {
            let idea = Idea(text: event.title)
            idea.dueDate = event.startDate
            idea.dueTime = String(
                format: "%02d:%02d",
                cal.component(.hour, from: event.startDate),
                cal.component(.minute, from: event.startDate)
            )
            idea.durationMinutes = durationMinutes
            idea.isProcessing = false
            idea.appleCalendarEventIdentifier = event.calendarItemIdentifier
            modelContext.insert(idea)
            try? modelContext.save()
        }

        refreshAppleCalendar(for: weekDays)
    }

    private func editAppleCalendarEvent(_ event: AppleCalendarEvent) {
        editingAppleCalendarEvent = event
        quickAddMode = .new
        quickAddNewKind = .calendarItem
        quickAddDate = event.startDate
        quickAddText = event.title
        quickAddSelectedTag = nil
        quickAddDuration = max(Int(event.endDate.timeIntervalSince(event.startDate) / 60), minuteIncrement)
        quickAddLinkSearch = ""
        syncQuickAddTimesFromDate()
        showQuickAdd = true
        quickAddFocused = true
    }

    private func deleteAppleCalendarEvent(_ event: AppleCalendarEvent) {
        guard appleCalendarManager.deleteEvent(event) else {
            return
        }
        if editingAppleCalendarEvent?.id == event.id {
            dismissQuickAdd()
        }
        refreshAppleCalendar(for: weekDays)
    }

    private func makeAppleCalendarEventAllDay(_ event: AppleCalendarEvent) {
        guard appleCalendarManager.updateEvent(event, title: nil, startDate: cal.startOfDay(for: event.startDate), durationMinutes: nil, isAllDay: true) else {
            return
        }
        refreshAppleCalendar(for: weekDays)
    }

    private func makeAppleCalendarEventTimed(_ event: AppleCalendarEvent) {
        let targetDate = cal.date(bySettingHour: 9, minute: 0, second: 0, of: event.startDate) ?? event.startDate
        guard appleCalendarManager.updateEvent(event, title: nil, startDate: targetDate, durationMinutes: defaultTimedDurationMinutes, isAllDay: false) else {
            return
        }
        refreshAppleCalendar(for: weekDays)
    }

    private func refreshAppleCalendar(for days: [Date]) {
        guard appleCalendarSyncEnabled,
              appleCalendarManager.hasFullAccess else {
            appleCalendarManager.clearVisibleEvents()
            return
        }

        let interval: DateInterval?
        if viewMode == .week {
            guard let start = days.first,
                  let last = days.last,
                  let end = cal.date(byAdding: .day, value: 1, to: last) else {
                appleCalendarManager.clearVisibleEvents()
                return
            }
            interval = DateInterval(start: cal.startOfDay(for: start), end: end)
        } else {
            interval = monthDateInterval()
        }

        guard let interval else {
            appleCalendarManager.clearVisibleEvents()
            return
        }

        for idea in ideasWithDueDate where idea.dueTime != nil {
            appleCalendarManager.syncIdea(idea, enabled: true)
        }
        try? modelContext.save()

        appleCalendarManager.refreshEvents(
            in: interval,
            excluding: Set(allIdeas.compactMap(\.appleCalendarEventIdentifier))
        )
    }

    private func monthDateInterval() -> DateInterval? {
        guard let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: displayedDate)),
              let monthEnd = cal.date(byAdding: DateComponents(month: 1, day: 0), to: monthStart)
        else {
            return nil
        }

        return DateInterval(start: monthStart, end: monthEnd)
    }

    private func deleteIdea(_ idea: Idea) {
        AppleCalendarManager.shared.removeSyncedEvent(for: idea)
        modelContext.delete(idea)
        try? modelContext.save()
        ideaToDelete = nil
    }

    private func resizedDurationMinutes(baseDurationMinutes: Int, idea: Idea, translationHeight: CGFloat) -> Int {
        guard let (hour, minute) = timeComponents(for: idea) else { return defaultTimedDurationMinutes }
        let startMinutes = hour * 60 + minute
        return resizedDurationMinutes(
            baseDurationMinutes: baseDurationMinutes,
            startMinutes: startMinutes,
            translationHeight: translationHeight
        )
    }

    private func resizedDurationMinutes(baseDurationMinutes: Int, startMinutes: Int, translationHeight: CGFloat) -> Int {
        let deltaSlots = Int((translationHeight / timeSlotHeight).rounded())
        let maxDuration = max(endHour * 60 - startMinutes, minuteIncrement)
        let proposed = baseDurationMinutes + deltaSlots * minuteIncrement
        return min(max(proposed, minuteIncrement), maxDuration)
    }

    private func timeComponents(for idea: Idea) -> (hour: Int, minute: Int)? {
        idea.timeComponents
    }

    // MARK: - Navigation

    private func navigateBack() {
        if viewMode == .month {
            displayedDate = cal.date(byAdding: .month, value: -1, to: displayedDate) ?? displayedDate
        } else {
            displayedDate = cal.date(byAdding: .weekOfYear, value: -1, to: displayedDate) ?? displayedDate
        }
    }

    private func navigateForward() {
        if viewMode == .month {
            displayedDate = cal.date(byAdding: .month, value: 1, to: displayedDate) ?? displayedDate
        } else {
            displayedDate = cal.date(byAdding: .weekOfYear, value: 1, to: displayedDate) ?? displayedDate
        }
    }

    // MARK: - Date Calculations

    private func daysInMonthGrid() -> [Date?] {
        guard let range = cal.range(of: .day, in: .month, for: displayedDate),
              let firstDay = cal.date(from: cal.dateComponents([.year, .month], from: displayedDate))
        else { return [] }

        let firstWeekday = cal.component(.weekday, from: firstDay)
        var days: [Date?] = Array(repeating: nil, count: firstWeekday - 1)
        for day in range {
            days.append(cal.date(byAdding: .day, value: day - 1, to: firstDay))
        }
        while days.count % 7 != 0 { days.append(nil) }
        return days
    }
}
