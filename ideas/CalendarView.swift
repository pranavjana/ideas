import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import EventKit

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
    @State private var quickAddText = ""
    @State private var quickAddSelectedTag: String? = nil
    @State private var quickAddDuration: Int = 60
    @State private var dropTargetSlot: TimeSlot? = nil
    @State private var hoveredEventURI: String? = nil
    @State private var draggedIdeaURI: String? = nil
    @State private var draggedDurationMinutes = 60
    @State private var ideaToDelete: Idea? = nil
    @State private var showDeleteConfirm = false
    @GestureState private var activeResizeDrag: ResizeDragState? = nil
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

    private struct ResizeDragState: Equatable {
        let ideaURI: String
        let translationHeight: CGFloat
        let baseDurationMinutes: Int
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

            let providers = info.itemProviders(for: [UTType.ideaTransfer])
            guard let provider = providers.first else {
                dropTargetSlot = nil
                clearDraggedState()
                return false
            }

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

    private func ideasByDayMap() -> [Int: [Idea]] {
        var dict: [Int: [Idea]] = [:]
        for idea in ideasWithDueDate {
            guard let due = idea.dueDate else { continue }
            let key = cal.ordinality(of: .day, in: .era, for: due) ?? 0
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
                .font(.custom("Gambarino-Regular", size: 22))
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

    private var headerTitle: String {
        let fmt = DateFormatter()
        if viewMode == .week {
            let days = weekDays
            guard let first = days.first, let last = days.last else { return "" }
            if cal.component(.month, from: first) == cal.component(.month, from: last) {
                fmt.dateFormat = "MMMM yyyy"
                return fmt.string(from: first).lowercased()
            } else {
                let mf = DateFormatter(); mf.dateFormat = "MMM"
                let yf = DateFormatter(); yf.dateFormat = "yyyy"
                return "\(mf.string(from: first).lowercased()) – \(mf.string(from: last).lowercased()) \(yf.string(from: last))"
            }
        } else {
            fmt.dateFormat = "MMMM yyyy"
            return fmt.string(from: displayedDate).lowercased()
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
                  activeResizeDrag == nil,
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
            if let slot = dropTargetSlot,
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

    // MARK: - Event Blocks

    private func eventBlocks(days: [Date]) -> some View {
        GeometryReader { geo in
            let totalWidth = geo.size.width - timeGutterWidth
            let columnWidth = dayColumnWidth(totalWidth: totalWidth, dayCount: days.count)

            ForEach(Array(days.enumerated()), id: \.offset) { idx, day in
                let timedIdeas = ideasForDate(day)
                    .filter { $0.dueTime != nil }
                    .sorted { ($0.dueTime ?? "") < ($1.dueTime ?? "") }

                ForEach(timedIdeas) { idea in
                    eventBlock(idea: idea, columnIndex: idx, columnWidth: columnWidth, totalWidth: totalWidth, dayCount: days.count)
                }
            }
        }
    }

    private func appleCalendarEventBlocks(days: [Date]) -> some View {
        GeometryReader { geo in
            let totalWidth = geo.size.width - timeGutterWidth
            let columnWidth = dayColumnWidth(totalWidth: totalWidth, dayCount: days.count)

            ForEach(appleCalendarManager.visibleEvents.filter { !$0.isAllDay }) { event in
                if let columnIndex = days.firstIndex(where: { cal.isDate($0, inSameDayAs: event.startDate) }) {
                    appleCalendarEventBlock(
                        event,
                        columnIndex: columnIndex,
                        columnWidth: columnWidth,
                        totalWidth: totalWidth,
                        dayCount: days.count
                    )
                }
            }
        }
    }

    private func appleCalendarEventBlock(_ event: AppleCalendarEvent, columnIndex: Int, columnWidth: CGFloat, totalWidth: CGFloat, dayCount: Int) -> some View {
        let startHour = cal.component(.hour, from: event.startDate)
        let startMinute = cal.component(.minute, from: event.startDate)
        let durationMinutes = max(Int(event.endDate.timeIntervalSince(event.startDate) / 60), minuteIncrement)
        let xOffset = dayColumnXOffset(columnIndex: columnIndex, totalWidth: totalWidth, dayCount: dayCount) + eventColumnInset
        let topOffset = yOffset(forHour: startHour, minute: startMinute)
        let blockHeight = height(forDurationMinutes: durationMinutes)

        return VStack(alignment: .leading, spacing: 2) {
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
        .frame(width: columnWidth - eventColumnInset * 2, height: blockHeight, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.fg.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.fg.opacity(0.12), lineWidth: 1)
                )
        )
        .offset(x: xOffset, y: topOffset)
        .contextMenu {
            appleCalendarEventContextMenu(event)
        }
    }

    private func eventBlock(idea: Idea, columnIndex: Int, columnWidth: CGFloat, totalWidth: CGFloat, dayCount: Int) -> some View {
        let (topOffset, blockHeight) = eventPosition(idea)
        let color = eventColor(for: idea)
        let xOffset = dayColumnXOffset(columnIndex: columnIndex, totalWidth: totalWidth, dayCount: dayCount) + eventColumnInset
        let eventURI = ideaURI(idea)
        let isHovered = hoveredEventURI == eventURI
        let isResizing = activeResizeDrag?.ideaURI == eventURI
        let cardHeight = max(blockHeight, 22)

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
        .frame(width: columnWidth - eventColumnInset * 2, height: cardHeight, alignment: .topLeading)
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
        .draggable(ideaTransfer(idea)) {
            dragPreview(idea)
        }

        return ZStack(alignment: .bottom) {
            card

            resizeHandle(for: idea, isVisible: isHovered || isResizing)
        }
        .frame(width: columnWidth - eventColumnInset * 2, height: cardHeight, alignment: .top)
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
        .highPriorityGesture(resizeGesture(for: idea))
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

    // MARK: - Drag Helpers

    private func ideaTransfer(_ idea: Idea) -> IdeaTransfer {
        IdeaTransfer(uriRepresentation: idea.persistentModelID.hashValue.description)
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

    // MARK: - Month View

    private var monthView: some View {
        let days = daysInMonthGrid()
        let dayMap = ideasByDayMap()

        return VStack(spacing: 0) {
            monthWeekdayHeaders

            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 1), count: 7), spacing: 1) {
                    ForEach(Array(days.enumerated()), id: \.offset) { _, date in
                        monthDayCell(date: date, ideasMap: dayMap)
                    }
                }
                .padding(.horizontal, 1)
            }
        }
    }

    private var monthWeekdayHeaders: some View {
        let symbols = ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"]
        return HStack(spacing: 0) {
            ForEach(symbols, id: \.self) { symbol in
                Text(symbol)
                    .font(.custom("Switzer-Medium", size: 10))
                    .foregroundStyle(Color.fg.opacity(0.3))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
        }
        #if os(macOS)
        .padding(.horizontal, 24)
        #else
        .padding(.horizontal, 16)
        #endif
    }

    private func monthDayCell(date: Date?, ideasMap: [Int: [Idea]]) -> some View {
        Group {
            if let date {
                let isToday = cal.isDateInToday(date)
                let inMonth = cal.isDate(date, equalTo: displayedDate, toGranularity: .month)
                let dayKey = cal.ordinality(of: .day, in: .era, for: date) ?? 0
                let dayIdeas = ideasMap[dayKey] ?? []

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("\(cal.component(.day, from: date))")
                            .font(.custom("Switzer-Medium", size: 11))
                            .foregroundStyle(isToday ? Color.bgBase : Color.fg.opacity(inMonth ? 0.55 : 0.15))
                            .frame(width: 22, height: 22)
                            .background(
                                Circle().fill(isToday ? Color.fg : Color.clear)
                            )
                        Spacer()
                    }
                    .padding(.top, 3)
                    .padding(.leading, 3)

                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(dayIdeas.prefix(3)) { idea in
                            Button { onSelectIdea?(idea) } label: {
                                HStack(spacing: 3) {
                                    Circle()
                                        .fill(eventColor(for: idea))
                                        .frame(width: 4, height: 4)
                                    Text(idea.text)
                                        .font(.custom("Switzer-Regular", size: 9))
                                        .foregroundStyle(Color.fg.opacity(idea.isDone ? 0.2 : 0.5))
                                        .lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                ideaContextMenu(idea)
                            }
                        }
                        if dayIdeas.count > 3 {
                            Text("+\(dayIdeas.count - 3) more")
                                .font(.custom("Switzer-Light", size: 8))
                                .foregroundStyle(Color.fg.opacity(0.2))
                                .padding(.leading, 7)
                        }
                    }
                    .padding(.horizontal, 3)

                    Spacer(minLength: 0)
                }
                #if os(macOS)
                .frame(minHeight: 85)
                #else
                .frame(minHeight: 65)
                #endif
                .background(Color.bgDeep.opacity(inMonth ? 1 : 0.5))
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
                Color.bgDeep.opacity(0.3)
                    #if os(macOS)
                    .frame(minHeight: 85)
                    #else
                    .frame(minHeight: 65)
                    #endif
            }
        }
    }

    // MARK: - Quick Add Overlay

    private var availableTags: [String] {
        profiles.first?.verifiedTags ?? []
    }

    private var quickAddOverlay: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture {
                    dismissQuickAdd()
                }

            VStack(alignment: .leading, spacing: 0) {
                // Header with date
                if let date = quickAddDate {
                    HStack(spacing: 8) {
                        Image(systemName: "calendar")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.fg.opacity(0.3))
                        Text(quickAddDateString(date))
                            .font(.custom("Switzer-Medium", size: 13))
                            .foregroundStyle(Color.fg.opacity(0.5))
                        Spacer()
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 16)
                    .padding(.bottom, 12)
                }

                // Text input
                HStack(spacing: 10) {
                    let accentColor = quickAddAccentColor
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(accentColor)
                        .frame(width: 3, height: 20)

                    TextField("what's the idea?", text: $quickAddText)
                        .font(.custom("Switzer-Regular", size: 15))
                        .textFieldStyle(.plain)
                        .focused($quickAddFocused)
                        .onSubmit { createQuickIdea() }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 14)

                // Tag selection
                if !availableTags.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("tag")
                            .font(.custom("Switzer-Medium", size: 10))
                            .foregroundStyle(Color.fg.opacity(0.25))
                            .textCase(.uppercase)
                            .tracking(0.5)

                        // Scrollable tag chips
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                quickAddTagChip(tag: nil, label: "none")

                                ForEach(availableTags, id: \.self) { tag in
                                    quickAddTagChip(tag: tag, label: tag)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 14)
                }

                // Duration picker
                VStack(alignment: .leading, spacing: 8) {
                    Text("duration")
                        .font(.custom("Switzer-Medium", size: 10))
                        .foregroundStyle(Color.fg.opacity(0.25))
                        .textCase(.uppercase)
                        .tracking(0.5)

                    HStack(spacing: 6) {
                        ForEach([15, 30, 60, 90, 120], id: \.self) { minutes in
                            quickAddDurationChip(minutes: minutes)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 16)

                Rectangle()
                    .fill(Color.fg.opacity(0.06))
                    .frame(maxWidth: .infinity)
                    .frame(height: 1)

                // Submit button
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

                    Button { createQuickIdea() } label: {
                        HStack(spacing: 6) {
                            Text("add idea")
                                .font(.custom("Switzer-Semibold", size: 13))
                            Image(systemName: "return")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundStyle(quickAddText.isEmpty ? Color.fg.opacity(0.2) : Color.fg.opacity(0.8))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(quickAddText.isEmpty ? Color.fg.opacity(0.04) : quickAddAccentColor.opacity(0.15))
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(quickAddText.isEmpty)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            }
            .frame(maxWidth: 420)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.bgElevated)
                    .shadow(color: .black.opacity(0.3), radius: 30, y: 15)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color.fg.opacity(0.08), lineWidth: 1)
                    )
            )
            .padding(.horizontal, 32)
        }
    }

    private var quickAddAccentColor: Color {
        if let tag = quickAddSelectedTag,
           let hex = tagColors[tag],
           let color = Color.accent(hex: hex) {
            return color
        }
        return Color.fg.opacity(0.35)
    }

    private func quickAddTagChip(tag: String?, label: String) -> some View {
        let isSelected = quickAddSelectedTag == tag
        let chipColor: Color = {
            if let tag, let hex = tagColors[tag], let c = Color.accent(hex: hex) {
                return c
            }
            return Color.fg
        }()

        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                quickAddSelectedTag = tag
            }
        } label: {
            Text(label)
                .font(.custom("Switzer-Medium", size: 11))
                .foregroundStyle(isSelected ? chipColor.opacity(0.9) : Color.fg.opacity(0.35))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected ? chipColor.opacity(0.15) : Color.fg.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isSelected ? chipColor.opacity(0.3) : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func quickAddDurationChip(minutes: Int) -> some View {
        let isSelected = quickAddDuration == minutes
        let label: String = {
            if minutes < 60 { return "\(minutes)m" }
            if minutes == 60 { return "1h" }
            if minutes == 90 { return "1.5h" }
            return "\(minutes / 60)h"
        }()

        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                quickAddDuration = minutes
            }
        } label: {
            Text(label)
                .font(.custom("Switzer-Medium", size: 11))
                .foregroundStyle(isSelected ? Color.fg.opacity(0.8) : Color.fg.opacity(0.3))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected ? Color.fg.opacity(0.1) : Color.fg.opacity(0.04))
                )
        }
        .buttonStyle(.plain)
    }

    private func quickAddDateString(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "EEEE, MMM d 'at' h:mm a"
        return fmt.string(from: date).lowercased()
    }

    private func dismissQuickAdd() {
        showQuickAdd = false
        quickAddText = ""
        quickAddSelectedTag = nil
        quickAddDuration = 60
    }

    private func createQuickIdea() {
        let trimmed = quickAddText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let date = quickAddDate else { return }

        if let ideasViewModel {
            ideasViewModel.addIdea(trimmed, scheduledAt: date, durationMinutes: quickAddDuration)
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

        // If we used the ViewModel path, we still need to set the tag
        // We do this after creation by finding the most recent idea
        if ideasViewModel != nil, let tag = quickAddSelectedTag {
            // Find the idea that was just created (most recent with matching text)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if let newIdea = allIdeas.first(where: {
                    $0.text.contains(trimmed) || trimmed.contains($0.text)
                }) {
                    if newIdea.tags.isEmpty || !newIdea.tags.contains(tag) {
                        newIdea.tags = [tag]
                        try? modelContext.save()
                    }
                }
            }
        }

        dismissQuickAdd()
    }

    // MARK: - Helpers

    private func eventColor(for idea: Idea) -> Color {
        if let accent = idea.accentColor(from: tagColors) { return accent }
        if idea.priorityLevel != .none { return idea.priorityLevel.color }
        return Color.fg.opacity(0.35)
    }

    private func hourLabel(_ hour: Int) -> String {
        if hour == 0 || hour == 24 { return "12 AM" }
        if hour == 12 { return "12 PM" }
        if hour < 12 { return "\(hour) AM" }
        return "\(hour - 12) PM"
    }

    private func formatTime(_ time: String) -> String {
        guard time.count == 5,
              let hour = Int(time.prefix(2)),
              let minute = Int(time.suffix(2)) else { return time }
        let period = hour >= 12 ? "PM" : "AM"
        let displayHour = hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour)
        return minute == 0 ? "\(displayHour) \(period)" : "\(displayHour):\(String(format: "%02d", minute)) \(period)"
    }

    private func dayOfWeekShort(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "EEE"
        return fmt.string(from: date).uppercased()
    }

    private func formatTime(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "h:mm a"
        return fmt.string(from: date).lowercased()
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
            convertAppleCalendarEventToIdea(event)
        } label: {
            Label("Convert to idea", systemImage: "arrow.right.circle")
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
                linkedAppleCalendarEventIdentifier: event.id
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
            idea.appleCalendarEventIdentifier = event.id
            modelContext.insert(idea)
            try? modelContext.save()
        }

        refreshAppleCalendar(for: weekDays)
    }

    private func refreshAppleCalendar(for days: [Date]) {
        guard viewMode == .week,
              appleCalendarSyncEnabled,
              appleCalendarManager.hasFullAccess,
              let start = days.first,
              let last = days.last,
              let end = cal.date(byAdding: .day, value: 1, to: last)
        else {
            appleCalendarManager.clearVisibleEvents()
            return
        }

        for idea in ideasWithDueDate where idea.dueTime != nil {
            appleCalendarManager.syncIdea(idea, enabled: true)
        }
        try? modelContext.save()

        appleCalendarManager.refreshEvents(
            in: DateInterval(start: cal.startOfDay(for: start), end: end),
            excluding: Set(allIdeas.compactMap(\.appleCalendarEventIdentifier))
        )
    }

    private func deleteIdea(_ idea: Idea) {
        AppleCalendarManager.shared.removeSyncedEvent(for: idea)
        modelContext.delete(idea)
        try? modelContext.save()
        ideaToDelete = nil
    }

    private func resizedDurationMinutes(baseDurationMinutes: Int, idea: Idea, translationHeight: CGFloat) -> Int {
        guard let (hour, minute) = timeComponents(for: idea) else { return defaultTimedDurationMinutes }
        let deltaSlots = Int((translationHeight / timeSlotHeight).rounded())
        let startMinutes = hour * 60 + minute
        let maxDuration = max(endHour * 60 - startMinutes, minuteIncrement)
        let proposed = baseDurationMinutes + deltaSlots * minuteIncrement
        return min(max(proposed, minuteIncrement), maxDuration)
    }

    private func timeComponents(for idea: Idea) -> (hour: Int, minute: Int)? {
        guard let timeStr = idea.dueTime,
              timeStr.count == 5,
              let hour = Int(timeStr.prefix(2)),
              let minute = Int(timeStr.suffix(2)) else { return nil }
        return (hour, minute)
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
