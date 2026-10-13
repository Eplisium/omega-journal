import SwiftUI
import OmegaJournalCore

// MARK: - Template library (pick, preview, create, edit, delete, reorder)

/// Two-step picker: choosing a template shows exactly what the new entry will
/// look like (title, tags, rendered body with today's values) before anything
/// is created. Start Writing (Return) or a double-click creates the entry;
/// Cancel / Esc / the close button create nothing.
struct TemplatePickerView: View {
    @ObservedObject var vm: JournalViewModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var theme = ThemeManager.shared

    @State private var selectedId: String?
    @State private var editing: EntryTemplate?
    @State private var isNew = false
    @State private var pendingDelete: EntryTemplate?
    @FocusState private var listFocused: Bool

    /// Fixed for the session so the preview doesn't change while browsing.
    @State private var context = TemplateContext(date: Date(), prompt: PromptGenerator.today(),
                                                 moodLabel: Mood.neutral.label)

    private var selected: EntryTemplate? {
        let id = TemplatePickerPreview.resolveSelection(current: selectedId, available: vm.templates.map(\.id))
        return vm.templates.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.25)
            HStack(spacing: 0) {
                templateList
                    .frame(width: 260)
                Divider().opacity(0.25)
                previewPane
            }
            Divider().opacity(0.25)
            footer
        }
        .frame(width: 780, height: 540)
        .background(theme.backgroundColor)
        .onAppear { listFocused = true }
        .sheet(item: $editing) { template in
            TemplateEditorView(template: template, isNew: isNew, sortOrder: vm.templates.count) { saved in
                vm.db.saveTemplate(saved)
                vm.loadTemplates()
                selectedId = saved.id
            }
        }
        .confirmationDialog("Delete this template?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("Delete “\(pendingDelete?.name ?? "")”", role: .destructive) {
                if let t = pendingDelete { vm.db.deleteTemplate(id: t.id); vm.loadTemplates() }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("Entries already created from it are not affected.")
        }
    }

    // MARK: Header / footer

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Start from a Template")
                    .font(OmegaTheme.font(.bodyLarge, .semibold))
                    .foregroundColor(theme.titleTextColor)
                Text("Choose one to preview it. Nothing is created until you start writing.")
                    .font(OmegaTheme.font(.meta))
                    .foregroundColor(theme.secondaryTextColor)
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(OmegaTheme.font(.bodyLarge))
                    .foregroundColor(theme.secondaryTextColor)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
            .help("Close without creating an entry")
        }
        .padding(16)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let t = selected {
                Button { isNew = false; editing = t } label: { Label("Edit Template…", systemImage: "pencil") }
                    .help("Change this template's name, tags or text")
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button { start() } label: { Label("Start Writing", systemImage: "square.and.pencil") }
                .buttonStyle(.borderedProminent)
                .tint(theme.accentColor)
                .keyboardShortcut(.defaultAction)
                .disabled(selected == nil)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func start(_ template: EntryTemplate? = nil) {
        guard let t = template ?? selected else { return }
        vm.createEntry(from: t)
        dismiss()
    }

    // MARK: List

    private func summary(for t: EntryTemplate) -> TemplatePickerSummary {
        let builtIn = EntryTemplate.builtIns.first { $0.name == t.name && $0.body == t.body }
        return TemplatePickerPreview.summary(
            name: t.name, body: t.body, tags: t.tags,
            knownPurpose: builtIn.flatMap { TemplatePickerPreview.builtInPurposes[$0.name] },
            context: context)
    }

    private var templateList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(Array(vm.templates.enumerated()), id: \.element.id) { index, template in
                        templateRow(template, index: index).id(template.id)
                    }
                    newTemplateRow
                }
                .padding(10)
            }
            .scrollContentBackground(.hidden)
            .focusable()
            .focusEffectDisabled()
            .focused($listFocused)
            .onKeyPress(.upArrow) { moveSelection(-1, proxy); return .handled }
            .onKeyPress(.downArrow) { moveSelection(1, proxy); return .handled }
        }
        .background(theme.sidebarColor.opacity(0.35))
    }

    private func moveSelection(_ delta: Int, _ proxy: ScrollViewProxy) {
        let ids = vm.templates.map(\.id)
        guard let current = selected?.id, let i = ids.firstIndex(of: current) else { return }
        let next = min(max(i + delta, 0), ids.count - 1)
        selectedId = ids[next]
        proxy.scrollTo(ids[next])
    }

    private func templateRow(_ template: EntryTemplate, index: Int) -> some View {
        let info = summary(for: template)
        let isSelected = selected?.id == template.id
        return Button { selectedId = template.id; listFocused = true } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: template.icon)
                    .font(OmegaTheme.font(.body))
                    .foregroundColor(theme.accentColor)
                    .frame(width: 20)
                    .padding(.top, 1)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(info.displayName)
                        .font(OmegaTheme.font(.caption, .semibold))
                        .foregroundColor(theme.titleTextColor)
                        .lineLimit(1)
                    Text(info.purpose)
                        .font(OmegaTheme.font(.meta))
                        .foregroundColor(theme.secondaryTextColor)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? theme.accentColor.opacity(0.16) : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isSelected ? theme.accentColor.opacity(0.55) : .clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded { start(template) })
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(info.displayName) template")
        .accessibilityHint(info.purpose)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help("Double-click to start writing · right-click to edit")
        .contextMenu {
            Button { start(template) } label: { Label("Start Writing", systemImage: "square.and.pencil") }
            Button { isNew = false; editing = template } label: { Label("Edit Template…", systemImage: "pencil") }
            Button {
                let copy = EntryTemplate(name: template.name + " copy", body: template.body, tags: template.tags,
                                         icon: template.icon, sortOrder: vm.templates.count)
                vm.db.saveTemplate(copy); vm.loadTemplates()
                selectedId = copy.id
            } label: { Label("Duplicate", systemImage: "doc.on.doc") }
            Divider()
            Button { move(template, by: -1) } label: { Label("Move Up", systemImage: "arrow.up") }
                .disabled(index == 0)
            Button { move(template, by: 1) } label: { Label("Move Down", systemImage: "arrow.down") }
                .disabled(index == vm.templates.count - 1)
            Divider()
            Button(role: .destructive) { pendingDelete = template } label: { Label("Delete Template", systemImage: "trash") }
        }
    }

    private var newTemplateRow: some View {
        Button {
            isNew = true
            editing = EntryTemplate(name: "", body: "", tags: [], icon: "doc.text", sortOrder: vm.templates.count)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle")
                    .font(OmegaTheme.font(.body))
                    .frame(width: 20)
                Text("New Template…")
                    .font(OmegaTheme.font(.caption, .medium))
                Spacer(minLength: 0)
            }
            .foregroundColor(theme.secondaryTextColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundColor(theme.secondaryTextColor.opacity(0.3))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 6)
        .accessibilityLabel("New template")
    }

    private func move(_ template: EntryTemplate, by delta: Int) {
        var ids = vm.templates.map(\.id)
        guard let i = ids.firstIndex(of: template.id), ids.indices.contains(i + delta) else { return }
        ids.swapAt(i, i + delta)
        vm.db.reorderTemplates(ids: ids)
        vm.loadTemplates()
    }

    // MARK: Preview

    @ViewBuilder
    private var previewPane: some View {
        if let template = selected {
            let info = summary(for: template)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: template.icon)
                            .foregroundColor(theme.accentColor)
                            .accessibilityHidden(true)
                        Text(info.displayName)
                            .font(OmegaTheme.font(.body, .semibold))
                            .foregroundColor(theme.titleTextColor)
                    }
                    Text(info.purpose)
                        .font(OmegaTheme.font(.caption))
                        .foregroundColor(theme.bodyTextColor)
                        .fixedSize(horizontal: false, vertical: true)
                    if !info.tags.isEmpty {
                        HStack(spacing: 4) {
                            Text("Adds tags")
                                .font(OmegaTheme.font(.meta))
                                .foregroundColor(theme.secondaryTextColor)
                            ForEach(info.tags, id: \.self) { tag in
                                Text("#\(tag)")
                                    .font(OmegaTheme.font(.meta))
                                    .foregroundColor(theme.accentColor)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(theme.accentColor.opacity(0.12)))
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }

                    Text("PREVIEW · FILLED IN FOR TODAY")
                        .font(OmegaTheme.font(.meta, .semibold))
                        .tracking(0.5)
                        .foregroundColor(theme.secondaryTextColor)
                        .padding(.top, 4)
                    renderedPage(info)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollContentBackground(.hidden)
            .id(template.id)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(OmegaTheme.font(.title, .light))
                    .foregroundColor(theme.secondaryTextColor)
                Text("No templates yet. Create one to get started.")
                    .font(OmegaTheme.font(.caption))
                    .foregroundColor(theme.secondaryTextColor)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The new entry as the reader will show it: title + rendered Markdown.
    private func renderedPage(_ info: TemplatePickerSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(info.entryTitle.isEmpty ? "Untitled" : info.entryTitle)
                .font(OmegaTheme.font(.heading, .bold, design: .serif))
                .foregroundColor(info.entryTitle.isEmpty ? theme.secondaryTextColor : theme.titleTextColor)
            if info.isBlank {
                Text("An empty page, ready for whatever is on your mind.")
                    .font(OmegaTheme.font(.body))
                    .foregroundColor(theme.secondaryTextColor)
            } else {
                MarkdownBodyView(markdown: info.filledBody, textColor: theme.bodyTextColor)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.cardColor.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.borderColor, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Preview of the new entry")
    }
}

// MARK: - Editor sheet

struct TemplateEditorView: View {
    let template: EntryTemplate
    let isNew: Bool
    let sortOrder: Int
    var onSave: (EntryTemplate) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var theme = ThemeManager.shared
    @State private var name: String
    @State private var bodyText: String
    @State private var tagsText: String
    @State private var icon: String

    private static let icons = ["doc.text", "sun.max", "heart", "calendar.badge.clock", "moon.stars",
                                "arrow.triangle.branch", "star", "book", "lightbulb", "checklist",
                                "figure.walk", "fork.knife", "airplane", "briefcase", "leaf"]

    init(template: EntryTemplate, isNew: Bool, sortOrder: Int, onSave: @escaping (EntryTemplate) -> Void) {
        self.template = template; self.isNew = isNew; self.sortOrder = sortOrder; self.onSave = onSave
        _name = State(initialValue: template.name)
        _bodyText = State(initialValue: template.body)
        _tagsText = State(initialValue: template.tags.joined(separator: ", "))
        _icon = State(initialValue: template.icon)
    }

    private var tags: [String] { TemplateExpander.parseTagField(tagsText) }

    private var preview: String {
        TemplateExpander.expand(bodyText, context: TemplateContext(date: Date(), prompt: PromptGenerator.today(), moodLabel: Mood.neutral.label))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? "New Template" : "Edit Template")
                .font(OmegaTheme.font(.bodyLarge, .semibold))
                .foregroundColor(theme.titleTextColor)

            HStack {
                TextField("Name (also the entry title — variables allowed)", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Template name")
                Menu {
                    ForEach(Self.icons, id: \.self) { i in Button { icon = i } label: { Label(i, systemImage: i) } }
                } label: { Image(systemName: icon) }
                    .menuStyle(.borderlessButton).fixedSize()
                    .accessibilityLabel("Template icon")
            }

            TextField("Default tags (comma separated)", text: $tagsText)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Default tags")

            HStack {
                Text("Body · Markdown; variables fill in when an entry starts")
                    .font(OmegaTheme.font(.meta))
                    .foregroundColor(theme.secondaryTextColor)
                Spacer()
                ForEach(TemplateExpander.variableNames, id: \.self) { v in
                    Button("{{\(v)}}") { bodyText += (bodyText.isEmpty || bodyText.hasSuffix("\n") || bodyText.hasSuffix(" ") ? "" : " ") + "{{\(v)}}" }
                        .buttonStyle(.plain)
                        .font(OmegaTheme.font(.meta, design: .monospaced))
                        .foregroundColor(theme.accentColor)
                        .accessibilityLabel("Insert \(v) variable")
                }
            }
            TextEditor(text: $bodyText)
                .font(OmegaTheme.font(.caption, design: .monospaced))
                .frame(height: 150)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(theme.cardColor.opacity(0.5)))
                .accessibilityLabel("Template body")

            if !TemplateExpander.variables(in: bodyText + name).isEmpty {
                Text("Preview today")
                    .font(OmegaTheme.font(.meta)).foregroundColor(theme.secondaryTextColor)
                ScrollView {
                    Text(preview).font(OmegaTheme.font(.meta)).foregroundColor(theme.bodyTextColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 60)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(theme.cardColor.opacity(0.3)))
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(EntryTemplate(id: template.id, name: name.trimmingCharacters(in: .whitespaces),
                                         body: bodyText, tags: tags, icon: icon, sortOrder: template.sortOrder))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(theme.accentColor)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 500)
        .background(theme.backgroundColor)
    }
}
