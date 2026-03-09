import SwiftUI
import SwiftData

// MARK: - Folder Browser (sidebar section)

struct FolderBrowserView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<Folder> { $0.parent == nil },
           sort: \Folder.sortOrder)
    private var rootFolders: [Folder]

    @Binding var selectedFolder: Folder?
    var onFolderTap: (() -> Void)? = nil
    @State private var showNewFolder = false
    @State private var editingFolder: Folder?
    @State private var newSubfolderParent: Folder?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Header
            HStack {
                Text("folders")
                    .font(.custom("Switzer-Medium", size: 11))
                    .foregroundStyle(Color.fg.opacity(0.3))
                    .textCase(.uppercase)

                Spacer()

                Button {
                    showNewFolder = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.fg.opacity(0.3))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)

            // "All ideas" row
            folderRow(label: "all ideas", icon: "tray.fill", color: nil, isSelected: selectedFolder == nil, depth: 0) {
                withAnimation(.easeInOut(duration: 0.15)) { selectedFolder = nil }
                onFolderTap?()
            }

            // Folder tree
            ForEach(rootFolders.sorted(by: {
                if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            })) { folder in
                folderTree(folder: folder, depth: 0)
            }
        }
        .sheet(isPresented: $showNewFolder) {
            FolderEditorSheet(parent: nil)
        }
        .sheet(item: $editingFolder) { folder in
            FolderEditorSheet(editing: folder)
        }
        .sheet(item: $newSubfolderParent) { parent in
            FolderEditorSheet(parent: parent)
        }
    }

    private func folderTree(folder: Folder, depth: Int) -> AnyView {
        let isSelected = selectedFolder?.persistentModelID == folder.persistentModelID
        return AnyView(
            VStack(alignment: .leading, spacing: 2) {
                folderRow(
                    label: folder.name,
                    icon: folder.icon,
                    color: folder.color,
                    isSelected: isSelected,
                    depth: depth,
                    count: folder.ideas.count
                ) {
                    withAnimation(.easeInOut(duration: 0.15)) { selectedFolder = folder }
                    onFolderTap?()
                }
                .contextMenu {
                    Button {
                        editingFolder = folder
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }

                    Button {
                        newSubfolderParent = folder
                    } label: {
                        Label("New subfolder", systemImage: "folder.badge.plus")
                    }

                    Button(role: .destructive) {
                        deleteFolder(folder)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }

                ForEach(folder.sortedChildren) { child in
                    folderTree(folder: child, depth: depth + 1)
                }
            }
        )
    }

    private func folderRow(
        label: String,
        icon: String,
        color: Color?,
        isSelected: Bool,
        depth: Int,
        count: Int? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle((color ?? .fg).opacity(isSelected ? 0.7 : 0.35))
                    .frame(width: 16)

                Text(label)
                    .font(.custom("Switzer-Regular", size: 12))
                    .foregroundStyle(Color.fg.opacity(isSelected ? 0.85 : 0.4))
                    .lineLimit(1)

                Spacer()

                if let count, count > 0 {
                    Text("\(count)")
                        .font(.custom("Switzer-Light", size: 10))
                        .foregroundStyle(Color.fg.opacity(0.2))
                }
            }
            .padding(.leading, CGFloat(depth) * 14 + 12)
            .padding(.trailing, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.fg.opacity(isSelected ? 0.06 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func deleteFolder(_ folder: Folder) {
        // Move ideas to parent folder (or nil)
        for idea in folder.ideas {
            idea.folder = folder.parent
        }
        // Move child folders to parent
        for child in folder.children {
            child.parent = folder.parent
        }
        if selectedFolder?.persistentModelID == folder.persistentModelID {
            selectedFolder = folder.parent
        }
        modelContext.delete(folder)
        try? modelContext.save()
    }
}

// MARK: - Folder Editor Sheet

struct FolderEditorSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var icon: String
    @State private var colorHex: String
    private let parent: Folder?
    private let editing: Folder?

    private static let iconOptions = [
        "folder", "folder.fill", "doc", "book", "briefcase", "building.2",
        "graduationcap", "laptopcomputer", "gear", "star", "heart",
        "flag", "bolt", "lightbulb", "brain", "music.note",
        "paintbrush", "hammer", "wrench", "gamecontroller",
        "airplane", "house", "cart", "dollarsign.circle",
        "person.2", "leaf", "flame", "trophy", "target",
        "chart.bar", "wand.and.stars", "flask", "atom"
    ]

    private static let colorOptions: [(name: String, color: Color?)] = [
        ("none", nil),
        ("red", .red), ("orange", .orange), ("yellow", .yellow),
        ("green", .green), ("mint", .mint), ("teal", .teal),
        ("cyan", .cyan), ("blue", .blue), ("indigo", .indigo),
        ("purple", .purple), ("pink", .pink), ("brown", .brown),
    ]

    /// Create new folder under parent
    init(parent: Folder?) {
        self.parent = parent
        self.editing = nil
        _name = State(initialValue: "")
        _icon = State(initialValue: "folder")
        _colorHex = State(initialValue: "")
    }

    /// Edit existing folder
    init(editing: Folder) {
        self.parent = editing.parent
        self.editing = editing
        _name = State(initialValue: editing.name)
        _icon = State(initialValue: editing.icon)
        _colorHex = State(initialValue: editing.colorHex)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Text(editing != nil ? "Edit folder" : "New folder")
                    .font(.custom("Switzer-Semibold", size: 16))
                    .foregroundStyle(Color.fg.opacity(0.85))
                Spacer()
                Button("Cancel") { dismiss() }
                    .font(.custom("Switzer-Regular", size: 13))
                    .foregroundStyle(Color.fg.opacity(0.4))
                    .buttonStyle(.plain)
            }

            // Name
            VStack(alignment: .leading, spacing: 6) {
                Text("Name")
                    .font(.custom("Switzer-Medium", size: 12))
                    .foregroundStyle(Color.fg.opacity(0.5))
                TextField("Folder name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.custom("Switzer-Regular", size: 14))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.fg.opacity(0.04))
                            .stroke(Color.fg.opacity(0.08), lineWidth: 1)
                    )
            }

            // Icon picker
            VStack(alignment: .leading, spacing: 6) {
                Text("Icon")
                    .font(.custom("Switzer-Medium", size: 12))
                    .foregroundStyle(Color.fg.opacity(0.5))
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(32), spacing: 6), count: 9), spacing: 6) {
                    ForEach(Self.iconOptions, id: \.self) { opt in
                        Button {
                            icon = opt
                        } label: {
                            Image(systemName: opt)
                                .font(.system(size: 12))
                                .foregroundStyle(Color.fg.opacity(icon == opt ? 0.85 : 0.3))
                                .frame(width: 32, height: 32)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color.fg.opacity(icon == opt ? 0.1 : 0.03))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .strokeBorder(Color.fg.opacity(icon == opt ? 0.2 : 0), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Color picker
            VStack(alignment: .leading, spacing: 6) {
                Text("Color")
                    .font(.custom("Switzer-Medium", size: 12))
                    .foregroundStyle(Color.fg.opacity(0.5))
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 8), count: 7), spacing: 8) {
                    ForEach(Self.colorOptions, id: \.name) { option in
                        Button {
                            colorHex = option.name == "none" ? "" : option.name
                        } label: {
                            Circle()
                                .fill(option.color ?? Color.fg.opacity(0.15))
                                .frame(width: 28, height: 28)
                                .overlay(
                                    Circle()
                                        .strokeBorder(Color.fg.opacity(
                                            (option.name == "none" && colorHex.isEmpty) ||
                                            colorHex == option.name ? 0.8 : 0
                                        ), lineWidth: 2)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Spacer()

            // Save button
            Button {
                save()
            } label: {
                Text(editing != nil ? "Save" : "Create")
                    .font(.custom("Switzer-Medium", size: 14))
                    .foregroundStyle(Color.fg.opacity(name.trimmingCharacters(in: .whitespaces).isEmpty ? 0.3 : 0.85))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.fg.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(20)
        .frame(width: 380)
        .background(Color.bgElevated)
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        if let editing {
            editing.name = trimmedName
            editing.icon = icon
            editing.colorHex = colorHex
        } else {
            let folder = Folder(name: trimmedName, icon: icon, colorHex: colorHex, parent: parent)
            modelContext.insert(folder)
        }
        try? modelContext.save()
        dismiss()
    }
}
