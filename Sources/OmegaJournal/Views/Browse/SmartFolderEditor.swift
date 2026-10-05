import SwiftUI
import OmegaJournalCore

extension SmartFolder: Hashable {
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct SmartFolderEditor: View {
    @ObservedObject var vm: JournalViewModel
    @State var folder: SmartFolder
    var onDone: (SmartFolder?) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var theme = ThemeManager.shared

    init(vm: JournalViewModel, folder: SmartFolder, onDone: @escaping (SmartFolder?) -> Void) {
        self.vm = vm
        _folder = State(initialValue: folder)
        self.onDone = onDone
    }

    private var isNew: Bool { vm.smartFolder(id: folder.id) == nil }
    private var canSave: Bool { !folder.name.trimmingCharacters(in: .whitespaces).isEmpty && folder.hasCriteria }
    private var previewCount: Int { folder.count(in: vm.entries.map(\.searchRecord), hiddenLocked: vm.hiddenLocked) }

    var body: some View {
        VStack(alignment: .leading, spacing: OmegaTheme.Spacing.l) {
            Text(isNew ? "New Smart Folder" : "Edit Smart Folder")
                .font(OmegaTheme.font(.heading, .semibold, design: .serif)).foregroundColor(theme.titleTextColor)
                .accessibilityAddTraits(.isHeader)
            TextField("Name", text: $folder.name).textFieldStyle(.roundedBorder)
            TextField("Search (optional) — e.g. tag:work has:image budget", text: $folder.query).textFieldStyle(.roundedBorder)

            GroupBox("Moods") {
                HStack(spacing: 6) {
                    ForEach(Mood.allCases) { m in
                        let on = folder.moods.contains(m.rawValue)
                        OmegaChip(title: "\(m.emoji) \(m.label)", isSelected: on) {
                            if on { folder.moods.removeAll { $0 == m.rawValue } } else { folder.moods.append(m.rawValue) }
                        }
                    }
                }.padding(6)
            }
            GroupBox("Tags (any of)") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(vm.allTags.prefix(30), id: \.tag) { item in
                            let on = folder.tags.contains(item.tag)
                            OmegaChip(title: "#\(item.tag)", isSelected: on) {
                                if on { folder.tags.removeAll { $0 == item.tag } } else { folder.tags.append(item.tag) }
                            }
                        }
                        if vm.allTags.isEmpty { Text("No tags yet").font(OmegaTheme.font(.meta)).foregroundColor(theme.secondaryTextColor) }
                    }.padding(6)
                }
            }
            HStack {
                Picker("Date", selection: $folder.dateRange) {
                    ForEach(SmartFolder.DateRange.allCases, id: \.self) { Text($0.label).tag($0) }
                }.frame(maxWidth: 220)
                Toggle("Pin to top", isOn: $folder.isPinned)
                Toggle("Has attachment", isOn: $folder.hasAttachment)
                Stepper("Min words: \(folder.minWords)", value: $folder.minWords, in: 0...5000, step: 50)
            }
            .font(OmegaTheme.font(.caption))

            HStack {
                Text("\(previewCount) matching \(previewCount == 1 ? "entry" : "entries")")
                    .font(OmegaTheme.font(.meta)).foregroundColor(theme.secondaryTextColor)
                Spacer()
                Button("Cancel") { dismiss(); onDone(nil) }
                Button("Save") {
                    if vm.saveSmartFolder(folder) { onDone(folder) }
                    dismiss()
                }
                .buttonStyle(.borderedProminent).tint(theme.accentColor)
                .keyboardShortcut(.defaultAction).disabled(!canSave)
            }
        }
        .padding(OmegaTheme.Spacing.xl)
        .frame(width: 520)
        .background(theme.backgroundColor)
    }
}

struct NotebookEditor: View {
    @ObservedObject var vm: JournalViewModel
    let journal: Journal?
    @State private var name: String
    @State private var colorHex: String
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var theme = ThemeManager.shared

    init(vm: JournalViewModel, journal: Journal?) {
        self.vm = vm; self.journal = journal
        _name = State(initialValue: journal?.name ?? "")
        _colorHex = State(initialValue: journal?.colorHex ?? TagColors.palette[1])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: OmegaTheme.Spacing.l) {
            Text(journal == nil ? "New Notebook" : "Edit Notebook")
                .font(OmegaTheme.font(.heading, .semibold, design: .serif)).foregroundColor(theme.titleTextColor)
                .accessibilityAddTraits(.isHeader)
            TextField("Name (e.g. Work, Dreams)", text: $name).textFieldStyle(.roundedBorder)
            ColorSwatchRow(selectedHex: $colorHex, allowsNone: false)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(journal == nil ? "Create" : "Save") {
                    if let journal { vm.updateJournal(journal, name: name, colorHex: colorHex) }
                    else if let created = vm.createJournal(name: name, colorHex: colorHex) { vm.setActiveJournal(created.id) }
                    dismiss()
                }
                .buttonStyle(.borderedProminent).tint(theme.accentColor).keyboardShortcut(.defaultAction)
                .disabled(JournalDefaults.normalizedName(name) == nil)
            }
        }
        .padding(OmegaTheme.Spacing.xl)
        .frame(width: 380)
        .background(theme.backgroundColor)
    }
}

struct ColorSwatchRow: View {
    @Binding var selectedHex: String
    var allowsNone: Bool
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        HStack(spacing: 8) {
            if allowsNone {
                Button { selectedHex = "" } label: {
                    Image(systemName: selectedHex.isEmpty ? "circle.slash.fill" : "circle.slash")
                        .foregroundColor(theme.secondaryTextColor)
                }
                .buttonStyle(.plain).accessibilityLabel("No color")
            }
            ForEach(TagColors.palette, id: \.self) { hex in
                let rgb = TagColors.rgb(hex: hex)!
                Button { selectedHex = hex } label: {
                    Circle().fill(Color(red: rgb.r, green: rgb.g, blue: rgb.b)).frame(width: 18, height: 18)
                        .overlay(Circle().strokeBorder(theme.titleTextColor, lineWidth: selectedHex == hex ? 2 : 0).padding(-3))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Color \(hex)")
                .accessibilityAddTraits(selectedHex == hex ? .isSelected : [])
            }
        }
    }
}

struct TagManagerView: View {
    @ObservedObject var vm: JournalViewModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var theme = ThemeManager.shared

    @State private var renaming: String?
    @State private var renameText = ""
    @State private var merging: String?
    @State private var deleting: String?

    var body: some View {
        VStack(alignment: .leading, spacing: OmegaTheme.Spacing.m) {
            HStack {
                Text("Tags").font(OmegaTheme.font(.heading, .semibold, design: .serif)).foregroundColor(theme.titleTextColor)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            Text("Use a/b names to nest tags. Renaming a tag renames its children too; merge folds one tag into another.")
                .font(OmegaTheme.font(.meta)).foregroundColor(theme.secondaryTextColor)

            if vm.tagTree.isEmpty {
                OmegaEmptyState(systemImage: "number", title: "No tags yet", message: "Add tags while writing and they'll show up here.")
            } else {
                List {
                    ForEach(TagTree.flatten(vm.tagTree)) { node in
                        tagLine(node)
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .padding(OmegaTheme.Spacing.xl)
        .frame(width: 560, height: 520)
        .background(theme.backgroundColor)
        .alert("Rename tag", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("New name", text: $renameText)
            Button("Rename") { if let r = renaming { vm.renameTagTree(r, to: renameText) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: { Text("Children (a/b → new/b) move with it. If the name exists, the tags merge.") }
        .confirmationDialog("Delete #\(deleting ?? "") from every entry?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete Tag", role: .destructive) { if let d = deleting { vm.deleteTagEverywhere(d) }; deleting = nil }
            Button("Cancel", role: .cancel) { deleting = nil }
        }
    }

    private func tagLine(_ node: TagNode) -> some View {
        let color = vm.color(forTag: node.path) ?? theme.accentColor
        return HStack(spacing: 8) {
            Spacer().frame(width: CGFloat(node.depth) * 14)
            Circle().fill(color).frame(width: 9, height: 9).accessibilityHidden(true)
            Text(node.name).font(OmegaTheme.font(.body)).foregroundColor(theme.titleTextColor)
            Text("\(node.totalCount)").font(OmegaTheme.font(.meta)).foregroundColor(theme.secondaryTextColor)
            Spacer()
            Menu {
                ForEach(TagColors.palette, id: \.self) { hex in
                    Button("Color \(hex)") { vm.setTagColor(node.path, hex: hex) }
                }
                Button("Clear color") { vm.setTagColor(node.path, hex: nil) }
            } label: { Image(systemName: "paintpalette") }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Color for \(node.path)")
            Button { renaming = node.path; renameText = node.path } label: { Image(systemName: "pencil") }
                .buttonStyle(.plain).accessibilityLabel("Rename \(node.path)")
            Menu {
                ForEach(vm.allTags.map(\.tag).filter { !TagPath.isSameOrDescendant($0, of: node.path) }, id: \.self) { t in
                    Button("Merge into #\(t)") { vm.mergeTag(node.path, into: t) }
                }
            } label: { Image(systemName: "arrow.triangle.merge") }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Merge \(node.path) into another tag")
            Button { deleting = node.path } label: { Image(systemName: "trash") }
                .buttonStyle(.plain).foregroundColor(.red).accessibilityLabel("Delete \(node.path)")
        }
    }
}
