import SwiftUI
import SwiftData

// MARK: - Idea Notes Helpers

extension Idea {
    var attributedNotes: AttributedString {
        get {
            guard !notesData.isEmpty else { return AttributedString() }
            return (try? JSONDecoder().decode(AttributedString.self, from: notesData)) ?? AttributedString()
        }
        set {
            notesData = (try? JSONEncoder().encode(newValue)) ?? Data()
        }
    }
}

// MARK: - Editor Panel

struct IdeaEditorPanel: View {
    @Bindable var idea: Idea
    @Environment(\.tagColors) private var tagColors
    let onClose: () -> Void

    @State private var editingTitle = false
    @State private var titleText: String = ""
    @State private var newSubtaskText = ""
    @State private var showDatePicker = false
    @State private var richText: AttributedString = ""
    @State private var plainNotes: String = ""
    @State private var saveTask: Task<Void, Never>?
    @State private var chatFraction: CGFloat = 0.45
    @GestureState private var dragStartFraction: CGFloat? = nil
    @State private var isDividerHovering = false
    @FocusState private var isTitleFocused: Bool
    @FocusState private var isSubtaskFocused: Bool
    @FocusState private var isEditorFocused: Bool

    private var accent: Color {
        idea.accentColor(from: tagColors) ?? .white
    }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                // Left: AI Chat
                IdeaChatView(idea: idea, onNotesChanged: reloadNotes)
                    .padding(.top, 12)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                    .frame(width: geo.size.width * chatFraction, height: geo.size.height)
                    .background(Color(red: 0.06, green: 0.06, blue: 0.06))

                // Draggable divider
                Rectangle()
                    .fill(Color.white.opacity(isDividerHovering ? 0.15 : 0.05))
                    .frame(width: isDividerHovering ? 3 : 1)
                    .contentShape(Rectangle().inset(by: -3))
                    .onHover { hovering in
                        isDividerHovering = hovering
                        #if os(macOS)
                        if hovering { NSCursor.resizeLeftRight.push() }
                        else { NSCursor.pop() }
                        #endif
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .updating($dragStartFraction) { _, state, _ in
                                if state == nil { state = chatFraction }
                            }
                            .onChanged { value in
                                let start = dragStartFraction ?? chatFraction
                                let delta = value.translation.width / geo.size.width
                                chatFraction = min(max(start + delta, 0.25), 0.75)
                            }
                    )
                    .animation(.easeOut(duration: 0.15), value: isDividerHovering)

                // Right: Properties + Notes
                VStack(alignment: .leading, spacing: 0) {
                    panelHeader
                    divider

                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            titleSection
                                .padding(.horizontal, 24)
                                .padding(.top, 20)
                                .padding(.bottom, 16)

                            divider

                            propertiesSection
                                .padding(.horizontal, 24)
                                .padding(.vertical, 16)

                            subtasksSection
                                .padding(.horizontal, 24)
                                .padding(.top, 16)

                            updatesSection
                                .padding(.horizontal, 24)
                                .padding(.top, 16)

                            divider
                                .padding(.top, 16)

                            notesEditor
                                .padding(.horizontal, 24)
                                .padding(.top, 12)
                                .padding(.bottom, 60)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(red: 0.08, green: 0.08, blue: 0.08))
            }
        }
        .frame(maxHeight: .infinity)
        .onAppear {
            titleText = idea.text
            richText = idea.attributedNotes
            plainNotes = String(richText.characters)
        }
        .onChange(of: richText) { _, newValue in
            saveTask?.cancel()
            saveTask = Task {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                idea.attributedNotes = newValue
            }
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.05))
            .frame(height: 1)
    }

    // MARK: - Header

    private var panelHeader: some View {
        HStack(spacing: 10) {
            Button { onClose() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                    Text("back")
                        .font(.custom("Switzer-Medium", size: 12))
                }
                .foregroundStyle(Color.white.opacity(0.35))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                withAnimation(.easeOut(duration: 0.15)) { idea.isDone.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: idea.isDone ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 11))
                    Text(idea.isDone ? "done" : "to do")
                        .font(.custom("Switzer-Medium", size: 11))
                }
                .foregroundStyle(idea.isDone ? Color.green.opacity(0.8) : Color.white.opacity(0.4))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(idea.isDone ? Color.green.opacity(0.1) : Color.white.opacity(0.04))
                        .stroke(idea.isDone ? Color.green.opacity(0.15) : Color.white.opacity(0.06), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Title

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if editingTitle {
                TextField("untitled", text: $titleText, axis: .vertical)
                    .font(.custom("Gambarino-Regular", size: 26))
                    .foregroundStyle(Color.white.opacity(0.9))
                    .textFieldStyle(.plain)
                    .focused($isTitleFocused)
                    .onSubmit {
                        idea.text = titleText
                        editingTitle = false
                    }
                    .onChange(of: isTitleFocused) { _, focused in
                        if !focused {
                            idea.text = titleText
                            editingTitle = false
                        }
                    }
            } else {
                Text(idea.text)
                    .font(.custom("Gambarino-Regular", size: 26))
                    .foregroundStyle(Color.white.opacity(0.9))
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        titleText = idea.text
                        editingTitle = true
                        isTitleFocused = true
                    }
            }

            Text(idea.createdAt.formatted(.dateTime.month(.wide).day().year()))
                .font(.custom("Switzer-Light", size: 12))
                .foregroundStyle(Color.white.opacity(0.2))
        }
    }

    // MARK: - Properties (Notion-style rows)

    private var propertiesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            propertyRow(icon: "circle.dotted", label: "Status") {
                HStack(spacing: 5) {
                    Circle()
                        .fill(idea.isDone ? Color.green.opacity(0.7) : Color.yellow.opacity(0.6))
                        .frame(width: 7, height: 7)
                    Text(idea.isDone ? "Done" : "In Progress")
                        .font(.custom("Switzer-Regular", size: 13))
                        .foregroundStyle(Color.white.opacity(0.7))
                }
            }

            propertyRow(icon: "flag", label: "Priority") {
                if idea.priorityLevel != .none {
                    HStack(spacing: 4) {
                        Image(systemName: idea.priorityLevel.icon)
                            .font(.system(size: 9))
                        Text(idea.priorityLevel.label.capitalized)
                            .font(.custom("Switzer-Regular", size: 13))
                    }
                    .foregroundStyle(idea.priorityLevel.color)
                    .contentShape(Rectangle())
                    .onTapGesture { cyclePriority() }
                } else {
                    Text("None")
                        .font(.custom("Switzer-Regular", size: 13))
                        .foregroundStyle(Color.white.opacity(0.2))
                        .contentShape(Rectangle())
                        .onTapGesture { cyclePriority() }
                }
            }

            propertyRow(icon: "calendar", label: "Due Date") {
                Button { showDatePicker = true } label: {
                    if let formatted = idea.formattedDueDate {
                        HStack(spacing: 4) {
                            if idea.recurring != nil {
                                Image(systemName: "arrow.trianglehead.2.clockwise")
                                    .font(.system(size: 9))
                            }
                            Text(formatted)
                                .font(.custom("Switzer-Regular", size: 13))
                            if let r = idea.recurring {
                                Text(r.rawValue)
                                    .font(.custom("Switzer-Light", size: 10))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(idea.dueStatus.color.opacity(0.15))
                                    .clipShape(Capsule())
                            }
                        }
                        .foregroundStyle(idea.dueStatus.color)
                    } else {
                        Text("Empty")
                            .font(.custom("Switzer-Regular", size: 13))
                            .foregroundStyle(Color.white.opacity(0.2))
                    }
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showDatePicker) {
                    DatePickerPopover(idea: idea)
                }
            }

            propertyRow(icon: "folder", label: "Category") {
                if !idea.category.isEmpty {
                    Text(idea.category)
                        .font(.custom("Switzer-Regular", size: 13))
                        .foregroundStyle(Color.white.opacity(0.7))
                } else {
                    Text("Empty")
                        .font(.custom("Switzer-Regular", size: 13))
                        .foregroundStyle(Color.white.opacity(0.2))
                }
            }

            propertyRow(icon: "tag", label: "Tags") {
                let visibleTags = idea.visibleTags
                if !visibleTags.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(visibleTags, id: \.self) { tag in
                            let tagColor = tagColors[tag].flatMap { Color(hex: $0) }
                            Text(tag)
                                .font(.custom("Switzer-Regular", size: 11))
                                .foregroundStyle((tagColor ?? .white).opacity(0.8))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background((tagColor ?? .white).opacity(0.1))
                                .clipShape(Capsule())
                        }
                    }
                } else {
                    Text("Empty")
                        .font(.custom("Switzer-Regular", size: 13))
                        .foregroundStyle(Color.white.opacity(0.2))
                }
            }

            let linkCount = idea.allLinks.count
            propertyRow(icon: "link", label: "Links") {
                Text(linkCount > 0 ? "\(linkCount) connection\(linkCount == 1 ? "" : "s")" : "Empty")
                    .font(.custom("Switzer-Regular", size: 13))
                    .foregroundStyle(Color.white.opacity(linkCount > 0 ? 0.7 : 0.2))
            }
        }
    }

    private func propertyRow<Content: View>(icon: String, label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.2))
                    .frame(width: 16)
                Text(label)
                    .font(.custom("Switzer-Regular", size: 13))
                    .foregroundStyle(Color.white.opacity(0.35))
            }
            .frame(width: 120, alignment: .leading)

            content()
            Spacer()
        }
        .padding(.vertical, 8)
    }

    private func cyclePriority() {
        withAnimation(.easeOut(duration: 0.1)) {
            let current = idea.priority
            idea.priority = current >= 4 ? 0 : current + 1
        }
    }

    private func reloadNotes() {
        richText = idea.attributedNotes
        plainNotes = String(richText.characters)
    }

    // MARK: - Notes Editor

    private var notesEditor: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isEditorFocused {
                // Editing mode: plain text
                TextEditor(text: $plainNotes)
                    .font(.custom("Switzer-Regular", size: 15))
                    .foregroundStyle(Color.white.opacity(0.8))
                    .scrollContentBackground(.hidden)
                    .focused($isEditorFocused)
                    .frame(minHeight: 300)
                    .lineSpacing(8)
                    .onChange(of: plainNotes) { _, newValue in
                        idea.attributedNotes = AttributedString(newValue)
                    }
            } else {
                // Display mode: rendered markdown
                if plainNotes.isEmpty {
                    Text("tap to edit notes...")
                        .font(.custom("Switzer-Regular", size: 15))
                        .foregroundStyle(Color.white.opacity(0.12))
                        .frame(maxWidth: .infinity, minHeight: 300, alignment: .topLeading)
                        .contentShape(Rectangle())
                        .onTapGesture { isEditorFocused = true }
                } else {
                    MarkdownNotesView(markdown: plainNotes)
                        .frame(maxWidth: .infinity, minHeight: 300, alignment: .topLeading)
                        .contentShape(Rectangle())
                        .onTapGesture { isEditorFocused = true }
                }
            }
        }
    }

    // MARK: - Subtasks

    private var subtasksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "checklist")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.25))
                Text("Subtasks")
                    .font(.custom("Switzer-Medium", size: 13))
                    .foregroundStyle(Color.white.opacity(0.4))
                if !idea.subtasks.isEmpty {
                    let progress = idea.subtaskProgress
                    Text("\(progress.done)/\(progress.total)")
                        .font(.custom("Switzer-Light", size: 11))
                        .foregroundStyle(Color.white.opacity(0.2))
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(idea.parsedSubtasks.enumerated()), id: \.offset) { index, subtask in
                    HStack(spacing: 8) {
                        Button {
                            withAnimation(.easeOut(duration: 0.15)) {
                                idea.toggleSubtask(at: index)
                            }
                        } label: {
                            Image(systemName: subtask.isDone ? "checkmark.square.fill" : "square")
                                .font(.system(size: 13))
                                .foregroundStyle(accent.opacity(subtask.isDone ? 0.4 : 0.2))
                        }
                        .buttonStyle(.plain)

                        Text(subtask.text)
                            .font(.custom("Switzer-Regular", size: 13))
                            .foregroundStyle(Color.white.opacity(subtask.isDone ? 0.3 : 0.7))
                            .strikethrough(subtask.isDone, color: Color.white.opacity(0.15))

                        Spacer()

                        Button {
                            withAnimation(.easeOut(duration: 0.15)) {
                                idea.removeSubtask(at: index)
                            }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(Color.white.opacity(0.12))
                                .frame(width: 18, height: 18)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.white.opacity(0.02))
                    )
                }

                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.white.opacity(0.15))

                    TextField("add subtask...", text: $newSubtaskText)
                        .textFieldStyle(.plain)
                        .font(.custom("Switzer-Regular", size: 13))
                        .foregroundStyle(Color.white.opacity(0.6))
                        .focused($isSubtaskFocused)
                        .onSubmit {
                            let trimmed = newSubtaskText.trimmingCharacters(in: .whitespaces)
                            if !trimmed.isEmpty {
                                withAnimation(.easeOut(duration: 0.15)) {
                                    idea.addSubtask(trimmed)
                                }
                                newSubtaskText = ""
                                isSubtaskFocused = true
                            }
                        }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 8)
            }
        }
    }

    // MARK: - Updates

    @ViewBuilder
    private var updatesSection: some View {
        if !idea.updates.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.25))
                    Text("Updates")
                        .font(.custom("Switzer-Medium", size: 13))
                        .foregroundStyle(Color.white.opacity(0.4))
                    Spacer()
                }

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(idea.parsedUpdates.reversed(), id: \.text) { update in
                        HStack(alignment: .top, spacing: 10) {
                            Circle()
                                .fill(accent.opacity(0.25))
                                .frame(width: 5, height: 5)
                                .padding(.top, 6)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(update.text)
                                    .font(.custom("Switzer-Regular", size: 13))
                                    .foregroundStyle(Color.white.opacity(0.6))
                                    .lineSpacing(3)
                                Text(update.date.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                                    .font(.custom("Switzer-Light", size: 10))
                                    .foregroundStyle(Color.white.opacity(0.15))
                            }
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 8)
                    }
                }
            }
        }
    }
}

// MARK: - Markdown Notes Renderer

struct MarkdownNotesView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(markdown.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    Spacer().frame(height: 8)
                } else if trimmed.hasPrefix("### ") {
                    Text(LocalizedStringKey(String(trimmed.dropFirst(4))))
                        .font(.custom("Switzer-Medium", size: 17))
                        .foregroundStyle(Color.white.opacity(0.9))
                } else if trimmed.hasPrefix("## ") {
                    Text(LocalizedStringKey(String(trimmed.dropFirst(3))))
                        .font(.custom("Switzer-Medium", size: 20))
                        .foregroundStyle(Color.white.opacity(0.9))
                        .padding(.top, 4)
                } else if trimmed.hasPrefix("# ") {
                    Text(LocalizedStringKey(String(trimmed.dropFirst(2))))
                        .font(.custom("Gambarino-Regular", size: 24))
                        .foregroundStyle(Color.white.opacity(0.9))
                        .padding(.top, 6)
                } else if trimmed.hasPrefix("- ") {
                    HStack(alignment: .top, spacing: 8) {
                        Text("•")
                            .font(.custom("Switzer-Regular", size: 15))
                            .foregroundStyle(Color.white.opacity(0.4))
                        Text(LocalizedStringKey(String(trimmed.dropFirst(2))))
                            .font(.custom("Switzer-Regular", size: 15))
                            .foregroundStyle(Color.white.opacity(0.75))
                            .lineSpacing(5)
                    }
                } else {
                    Text(LocalizedStringKey(trimmed))
                        .font(.custom("Switzer-Regular", size: 15))
                        .foregroundStyle(Color.white.opacity(0.75))
                        .lineSpacing(5)
                }
            }
        }
    }
}

// MARK: - Slash Command Menu Item

@available(iOS 26, macOS 26, *)
struct SlashCommand: Identifiable {
    let id = UUID()
    let icon: String
    let label: String
    let shortcut: String
    let action: (inout AttributedString, inout AttributedTextSelection) -> Void
}

// MARK: - Rich Text Editor (macOS 26+ / iOS 26+)

@available(iOS 26, macOS 26, *)
struct RichNotesEditor: View {
    @Binding var richText: AttributedString
    @FocusState var isEditorFocused: Bool
    @State private var selection = AttributedTextSelection()
    @State private var showSlashMenu = false
    @State private var slashFilter = ""
    @State private var selectedMenuIndex = 0
    @Environment(\.fontResolutionContext) private var fontResolutionContext

    private var slashCommands: [SlashCommand] {
        [
            SlashCommand(icon: "textformat", label: "Text", shortcut: "") { text, sel in
                text.replaceSelection(&sel, withCharacters: "")
            },
            SlashCommand(icon: "textformat.size.larger", label: "Heading 1", shortcut: "#") { text, sel in
                text.replaceSelection(&sel, withCharacters: "\n")
                text.transformAttributes(in: &sel) { $0.font = .system(size: 24, weight: .bold) }
            },
            SlashCommand(icon: "textformat.size", label: "Heading 2", shortcut: "##") { text, sel in
                text.replaceSelection(&sel, withCharacters: "\n")
                text.transformAttributes(in: &sel) { $0.font = .system(size: 20, weight: .bold) }
            },
            SlashCommand(icon: "textformat.size.smaller", label: "Heading 3", shortcut: "###") { text, sel in
                text.replaceSelection(&sel, withCharacters: "\n")
                text.transformAttributes(in: &sel) { $0.font = .system(size: 17, weight: .semibold) }
            },
            SlashCommand(icon: "list.bullet", label: "Bulleted list", shortcut: "-") { text, sel in
                text.replaceSelection(&sel, withCharacters: "• ")
            },
            SlashCommand(icon: "list.number", label: "Numbered list", shortcut: "1.") { text, sel in
                text.replaceSelection(&sel, withCharacters: "1. ")
            },
            SlashCommand(icon: "checklist", label: "To-do list", shortcut: "[]") { text, sel in
                text.replaceSelection(&sel, withCharacters: "☐ ")
            },
            SlashCommand(icon: "text.quote", label: "Quote", shortcut: ">") { text, sel in
                text.replaceSelection(&sel, withCharacters: "│ ")
            },
            SlashCommand(icon: "minus", label: "Divider", shortcut: "---") { text, sel in
                text.replaceSelection(&sel, withCharacters: "\n———————————————\n")
            },
        ]
    }

    private var filteredCommands: [SlashCommand] {
        if slashFilter.isEmpty { return slashCommands }
        return slashCommands.filter { $0.label.lowercased().contains(slashFilter.lowercased()) }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if richText.characters.isEmpty && !isEditorFocused {
                Text("Type / for commands...")
                    .font(.custom("Switzer-Regular", size: 15))
                    .foregroundStyle(Color.white.opacity(0.12))
                    .allowsHitTesting(false)
            }

            TextEditor(text: $richText, selection: $selection)
                .foregroundStyle(Color.white.opacity(0.85))
                .scrollContentBackground(.hidden)
                .focused($isEditorFocused)
                .frame(minHeight: 300)
                .lineSpacing(8)
                .onChange(of: richText) { oldValue, newValue in
                    handleTextChange(old: oldValue, new: newValue)
                }
                .onKeyPress(.upArrow) {
                    guard showSlashMenu else { return .ignored }
                    selectedMenuIndex = max(0, selectedMenuIndex - 1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    guard showSlashMenu else { return .ignored }
                    selectedMenuIndex = min(filteredCommands.count - 1, selectedMenuIndex + 1)
                    return .handled
                }
                .onKeyPress(.return) {
                    guard showSlashMenu, !filteredCommands.isEmpty else { return .ignored }
                    applySlashCommand(filteredCommands[selectedMenuIndex])
                    return .handled
                }
                .onKeyPress(.escape) {
                    guard showSlashMenu else { return .ignored }
                    showSlashMenu = false
                    return .handled
                }

            if showSlashMenu {
                slashMenuOverlay
                    .padding(.top, 30)
            }
        }
    }

    // MARK: - Text Change Handling

    private func handleTextChange(old: AttributedString, new: AttributedString) {
        let newView = new.characters
        let oldView = old.characters

        // Detect newline → reset typing attributes to plain text
        if newView.count > oldView.count && newView.last == "\n" {
            richText.transformAttributes(in: &selection) {
                $0.font = nil // Reset to default
                $0.underlineStyle = nil
                $0.strikethroughStyle = nil
            }
        }

        // Detect "/" typed
        if newView.count == oldView.count + 1 && newView.last == "/" {
            showSlashMenu = true
            slashFilter = ""
            selectedMenuIndex = 0
            return
        }

        // Update filter while slash menu is open
        if showSlashMenu {
            let newChars = String(newView)
            if let slashIdx = newChars.lastIndex(of: "/") {
                let afterSlash = String(newChars[newChars.index(after: slashIdx)...])
                if afterSlash.contains("\n") || afterSlash.contains(" ") {
                    showSlashMenu = false
                } else {
                    slashFilter = afterSlash
                    selectedMenuIndex = 0
                }
            } else {
                showSlashMenu = false
            }
        }
    }

    // MARK: - Slash Menu

    private var slashMenuOverlay: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Basic blocks")
                .font(.custom("Switzer-Medium", size: 11))
                .foregroundStyle(Color.white.opacity(0.3))
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 6)

            ForEach(Array(filteredCommands.enumerated()), id: \.element.id) { index, cmd in
                slashMenuItem(cmd: cmd, isHighlighted: index == selectedMenuIndex)
            }

            if filteredCommands.isEmpty {
                Text("No results")
                    .font(.custom("Switzer-Light", size: 13))
                    .foregroundStyle(Color.white.opacity(0.2))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }
        }
        .padding(.bottom, 8)
        .frame(width: 250)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(red: 0.12, green: 0.12, blue: 0.12))
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
    }

    private func slashMenuItem(cmd: SlashCommand, isHighlighted: Bool) -> some View {
        Button {
            applySlashCommand(cmd)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: cmd.icon)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white.opacity(isHighlighted ? 0.8 : 0.5))
                    .frame(width: 26, height: 26)
                    .background(Color.white.opacity(isHighlighted ? 0.08 : 0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 5))

                Text(cmd.label)
                    .font(.custom("Switzer-Regular", size: 14))
                    .foregroundStyle(Color.white.opacity(isHighlighted ? 1.0 : 0.7))

                Spacer()

                if !cmd.shortcut.isEmpty {
                    Text(cmd.shortcut)
                        .font(.custom("Switzer-Light", size: 12))
                        .foregroundStyle(Color.white.opacity(0.2))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(isHighlighted ? 0.06 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
    }

    private func applySlashCommand(_ cmd: SlashCommand) {
        // Remove the "/" and any filter text
        let chars = String(richText.characters)
        if let slashIdx = chars.lastIndex(of: "/") {
            let offset = chars.distance(from: chars.startIndex, to: slashIdx)
            let attrStart = richText.index(richText.startIndex, offsetByCharacters: offset)
            richText.characters.removeSubrange(attrStart..<richText.characters.endIndex)
            selection = .init(range: richText.endIndex..<richText.endIndex)
        }

        cmd.action(&richText, &selection)

        showSlashMenu = false
        slashFilter = ""
        selectedMenuIndex = 0
    }
}
