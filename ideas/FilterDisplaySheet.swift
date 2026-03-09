import SwiftUI
import SwiftData

// MARK: - Filter State

@Observable
class FilterState {
    var showDone: Bool? = nil          // nil = all, true = done only, false = active only
    var priorityFilter: Set<Int> = []  // empty = all, otherwise specific priority values
    var tagFilter: Set<String> = []    // empty = all
    var categoryFilter: Set<String> = [] // empty = all
    var folderFilter: Folder? = nil    // nil = all folders
    var dueDateFilter: DueDateFilter = .all

    enum DueDateFilter: String, CaseIterable {
        case all = "All"
        case overdue = "Overdue"
        case today = "Today"
        case upcoming = "Upcoming"
        case noDueDate = "No due date"
        case hasDueDate = "Has due date"
    }

    var isActive: Bool {
        showDone != nil || !priorityFilter.isEmpty || !tagFilter.isEmpty
            || !categoryFilter.isEmpty || folderFilter != nil || dueDateFilter != .all
    }

    var activeFilterCount: Int {
        var count = 0
        if showDone != nil { count += 1 }
        if !priorityFilter.isEmpty { count += 1 }
        if !tagFilter.isEmpty { count += 1 }
        if !categoryFilter.isEmpty { count += 1 }
        if folderFilter != nil { count += 1 }
        if dueDateFilter != .all { count += 1 }
        return count
    }

    func reset() {
        showDone = nil
        priorityFilter = []
        tagFilter = []
        categoryFilter = []
        folderFilter = nil
        dueDateFilter = .all
    }

    func matches(_ idea: Idea) -> Bool {
        // Status filter
        if let showDone {
            if showDone && !idea.isDone { return false }
            if !showDone && idea.isDone { return false }
        }

        // Priority filter
        if !priorityFilter.isEmpty && !priorityFilter.contains(idea.priority) {
            return false
        }

        // Tag filter
        if !tagFilter.isEmpty && tagFilter.isDisjoint(with: Set(idea.visibleTags)) {
            return false
        }

        // Category filter
        if !categoryFilter.isEmpty && !categoryFilter.contains(idea.category) {
            return false
        }

        // Folder filter
        if let folder = folderFilter {
            let folderIDs = Set(folder.allIdeas.map { $0.persistentModelID })
            if !folderIDs.contains(idea.persistentModelID) {
                return false
            }
        }

        // Due date filter
        switch dueDateFilter {
        case .all: break
        case .overdue:
            if idea.dueStatus != .overdue { return false }
        case .today:
            if idea.dueStatus != .today { return false }
        case .upcoming:
            if idea.dueStatus != .upcoming && idea.dueStatus != .today { return false }
        case .noDueDate:
            if idea.dueDate != nil { return false }
        case .hasDueDate:
            if idea.dueDate == nil { return false }
        }

        return true
    }
}

// MARK: - Filter / Display Sheet

struct FilterDisplaySheet: View {
    enum Tab: String {
        case filter = "Filter"
        case display = "Display"
    }

    @State var selectedTab: Tab = .filter
    var filterState: FilterState
    @Binding var sortOption: IdeaSort
    @Binding var ideasLayout: IdeasLayout
    @Binding var groupBy: GroupByOption

    let allTags: [String]
    let allCategories: [String]
    @Query private var folders: [Folder]

    @Environment(\.dismiss) private var dismiss

    init(
        filterState: FilterState,
        sortOption: Binding<IdeaSort>,
        ideasLayout: Binding<IdeasLayout>,
        groupBy: Binding<GroupByOption>,
        allTags: [String],
        allCategories: [String]
    ) {
        self.filterState = filterState
        self._sortOption = sortOption
        self._ideasLayout = ideasLayout
        self._groupBy = groupBy
        self.allTags = allTags
        self.allCategories = allCategories
    }

    var body: some View {
        VStack(spacing: 0) {
            // Tab switcher
            HStack(spacing: 0) {
                tabButton(.filter, icon: "line.3.horizontal.decrease")
                tabButton(.display, icon: "slider.horizontal.3")
            }
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.fg.opacity(0.04))
            )
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            ScrollView {
                if selectedTab == .filter {
                    filterContent
                } else {
                    displayContent
                }
            }
        }
        .frame(width: 340)
        #if os(macOS)
        .frame(maxHeight: 520)
        #endif
        .background(Color.bgElevated)
    }

    private func tabButton(_ tab: Tab, icon: String) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { selectedTab = tab }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                Text(tab.rawValue)
                    .font(.custom("Switzer-Medium", size: 13))
            }
            .foregroundStyle(Color.fg.opacity(selectedTab == tab ? 0.85 : 0.35))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.fg.opacity(selectedTab == tab ? 0.08 : 0))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Filter Content

    private var filterContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Clear all filters
            if filterState.isActive {
                HStack {
                    Spacer()
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { filterState.reset() }
                    } label: {
                        Text("clear all")
                            .font(.custom("Switzer-Regular", size: 11))
                            .foregroundStyle(Color.fg.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                }
            }

            // Status
            filterSection("Status", icon: "checkmark.circle") {
                HStack(spacing: 6) {
                    statusPill("All", isActive: filterState.showDone == nil) {
                        filterState.showDone = nil
                    }
                    statusPill("Active", isActive: filterState.showDone == false) {
                        filterState.showDone = false
                    }
                    statusPill("Done", isActive: filterState.showDone == true) {
                        filterState.showDone = true
                    }
                }
            }

            // Priority
            filterSection("Priority", icon: "exclamationmark.triangle") {
                FlowLayout(spacing: 6) {
                    ForEach(Idea.Priority.allCases.filter { $0 != .none }, id: \.rawValue) { priority in
                        let isSelected = filterState.priorityFilter.contains(priority.rawValue)
                        Button {
                            withAnimation(.easeInOut(duration: 0.1)) {
                                if isSelected {
                                    filterState.priorityFilter.remove(priority.rawValue)
                                } else {
                                    filterState.priorityFilter.insert(priority.rawValue)
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: priority.icon)
                                    .font(.system(size: 9))
                                Text(priority.label)
                                    .font(.custom("Switzer-Regular", size: 11))
                            }
                            .foregroundStyle(isSelected ? priority.color : Color.fg.opacity(0.4))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                Capsule()
                                    .fill(isSelected ? priority.color.opacity(0.15) : Color.fg.opacity(0.04))
                            )
                            .overlay(
                                Capsule()
                                    .strokeBorder(isSelected ? priority.color.opacity(0.3) : Color.fg.opacity(0.06), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Due date
            filterSection("Due date", icon: "calendar") {
                FlowLayout(spacing: 6) {
                    ForEach(FilterState.DueDateFilter.allCases, id: \.rawValue) { option in
                        let isSelected = filterState.dueDateFilter == option
                        Button {
                            withAnimation(.easeInOut(duration: 0.1)) {
                                filterState.dueDateFilter = option
                            }
                        } label: {
                            Text(option.rawValue)
                                .font(.custom("Switzer-Regular", size: 11))
                                .foregroundStyle(Color.fg.opacity(isSelected ? 0.85 : 0.4))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    Capsule()
                                        .fill(Color.fg.opacity(isSelected ? 0.1 : 0.04))
                                )
                                .overlay(
                                    Capsule()
                                        .strokeBorder(Color.fg.opacity(isSelected ? 0.2 : 0.06), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Tags
            if !allTags.isEmpty {
                filterSection("Tags", icon: "tag") {
                    FlowLayout(spacing: 6) {
                        ForEach(allTags, id: \.self) { tag in
                            let isSelected = filterState.tagFilter.contains(tag)
                            Button {
                                withAnimation(.easeInOut(duration: 0.1)) {
                                    if isSelected {
                                        filterState.tagFilter.remove(tag)
                                    } else {
                                        filterState.tagFilter.insert(tag)
                                    }
                                }
                            } label: {
                                Text(tag)
                                    .font(.custom("Switzer-Regular", size: 11))
                                    .foregroundStyle(Color.fg.opacity(isSelected ? 0.85 : 0.4))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(
                                        Capsule()
                                            .fill(Color.fg.opacity(isSelected ? 0.1 : 0.04))
                                    )
                                    .overlay(
                                        Capsule()
                                            .strokeBorder(Color.fg.opacity(isSelected ? 0.2 : 0.06), lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            // Categories
            if !allCategories.isEmpty {
                filterSection("Category", icon: "square.grid.2x2") {
                    FlowLayout(spacing: 6) {
                        ForEach(allCategories, id: \.self) { cat in
                            let isSelected = filterState.categoryFilter.contains(cat)
                            Button {
                                withAnimation(.easeInOut(duration: 0.1)) {
                                    if isSelected {
                                        filterState.categoryFilter.remove(cat)
                                    } else {
                                        filterState.categoryFilter.insert(cat)
                                    }
                                }
                            } label: {
                                Text(cat)
                                    .font(.custom("Switzer-Regular", size: 11))
                                    .foregroundStyle(Color.fg.opacity(isSelected ? 0.85 : 0.4))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(
                                        Capsule()
                                            .fill(Color.fg.opacity(isSelected ? 0.1 : 0.04))
                                    )
                                    .overlay(
                                        Capsule()
                                            .strokeBorder(Color.fg.opacity(isSelected ? 0.2 : 0.06), lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            // Folder
            let rootFolders = folders.filter { $0.parent == nil }
            if !rootFolders.isEmpty {
                filterSection("Folder", icon: "folder") {
                    VStack(alignment: .leading, spacing: 2) {
                        // "All" option
                        folderFilterRow(label: "All folders", folder: nil, depth: 0)

                        ForEach(rootFolders.sorted(by: { $0.name < $1.name })) { folder in
                            folderFilterTree(folder: folder, depth: 0)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 20)
    }

    private func folderFilterTree(folder: Folder, depth: Int) -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 2) {
            folderFilterRow(label: folder.name, folder: folder, depth: depth)

            ForEach(folder.sortedChildren) { child in
                folderFilterTree(folder: child, depth: depth + 1)
            }
        })
    }

    private func folderFilterRow(label: String, folder: Folder?, depth: Int) -> some View {
        let isSelected = filterState.folderFilter?.persistentModelID == folder?.persistentModelID
            && (folder != nil || filterState.folderFilter == nil)
        let isAllOption = folder == nil
        let actuallySelected = isAllOption ? filterState.folderFilter == nil : isSelected

        return Button {
            withAnimation(.easeInOut(duration: 0.1)) {
                filterState.folderFilter = folder
            }
        } label: {
            HStack(spacing: 8) {
                if !isAllOption {
                    Image(systemName: folder?.icon ?? "folder")
                        .font(.system(size: 10))
                        .foregroundStyle((folder?.color ?? .fg).opacity(0.6))
                }
                Text(label)
                    .font(.custom("Switzer-Regular", size: 12))
                    .foregroundStyle(Color.fg.opacity(actuallySelected ? 0.85 : 0.4))

                Spacer()

                if actuallySelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.fg.opacity(0.6))
                }
            }
            .padding(.leading, CGFloat(depth) * 16 + (isAllOption ? 0 : 0))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.fg.opacity(actuallySelected ? 0.06 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Display Content

    private var displayContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Layout
            filterSection("Layout", icon: "rectangle.3.group") {
                HStack(spacing: 6) {
                    layoutOption("List", icon: "list.bullet", layout: .list)
                    layoutOption("Board", icon: "rectangle.split.3x1", layout: .board)
                }
            }

            // Grouping (for list view)
            if ideasLayout == .list {
                filterSection("Grouping", icon: "rectangle.3.group.fill") {
                    FlowLayout(spacing: 6) {
                        ForEach(GroupByOption.allCases, id: \.self) { option in
                            let isSelected = groupBy == option
                            Button {
                                withAnimation(.easeInOut(duration: 0.1)) { groupBy = option }
                            } label: {
                                Text(option.label)
                                    .font(.custom("Switzer-Regular", size: 11))
                                    .foregroundStyle(Color.fg.opacity(isSelected ? 0.85 : 0.4))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(
                                        Capsule()
                                            .fill(Color.fg.opacity(isSelected ? 0.1 : 0.04))
                                    )
                                    .overlay(
                                        Capsule()
                                            .strokeBorder(Color.fg.opacity(isSelected ? 0.2 : 0.06), lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            // Ordering
            filterSection("Ordering", icon: "arrow.up.arrow.down") {
                FlowLayout(spacing: 6) {
                    ForEach(IdeaSort.allCases, id: \.self) { option in
                        let isSelected = sortOption == option
                        Button {
                            withAnimation(.easeInOut(duration: 0.1)) { sortOption = option }
                        } label: {
                            Text(option.label)
                                .font(.custom("Switzer-Regular", size: 11))
                                .foregroundStyle(Color.fg.opacity(isSelected ? 0.85 : 0.4))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    Capsule()
                                        .fill(Color.fg.opacity(isSelected ? 0.1 : 0.04))
                                )
                                .overlay(
                                    Capsule()
                                        .strokeBorder(Color.fg.opacity(isSelected ? 0.2 : 0.06), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 20)
    }

    private func layoutOption(_ label: String, icon: String, layout: IdeasLayout) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { ideasLayout = layout }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                Text(label)
                    .font(.custom("Switzer-Medium", size: 11))
            }
            .foregroundStyle(Color.fg.opacity(ideasLayout == layout ? 0.85 : 0.35))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.fg.opacity(ideasLayout == layout ? 0.08 : 0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.fg.opacity(ideasLayout == layout ? 0.15 : 0.04), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private func filterSection<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.fg.opacity(0.3))
                Text(title)
                    .font(.custom("Switzer-Medium", size: 12))
                    .foregroundStyle(Color.fg.opacity(0.5))
            }
            content()
        }
    }

    private func statusPill(_ label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.1)) { action() }
        } label: {
            Text(label)
                .font(.custom("Switzer-Regular", size: 11))
                .foregroundStyle(Color.fg.opacity(isActive ? 0.85 : 0.4))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(Color.fg.opacity(isActive ? 0.1 : 0.04))
                )
                .overlay(
                    Capsule()
                        .strokeBorder(Color.fg.opacity(isActive ? 0.2 : 0.06), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Group By Option

enum GroupByOption: String, CaseIterable {
    case none = "None"
    case tag = "Tag"
    case category = "Category"
    case priority = "Priority"
    case status = "Status"
    case folder = "Folder"
    case dueDate = "Due date"

    var label: String { rawValue }
}

// FlowLayout is defined in SettingsView.swift and shared across the app.
