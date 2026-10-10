import SwiftUI
import OmegaJournalCore

// MARK: - Template library (pick, create, edit, delete, reorder)

struct TemplatePickerView: View {
    @ObservedObject var vm: JournalViewModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var theme = ThemeManager.shared

    @State private var editing: EntryTemplate?
    @State private var isNew = false
    @State private var pendingDelete: EntryTemplate?

    private let columns = [GridItem(.adaptive(minimum: 170), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Start from a Template")
                        .font(OmegaTheme.font(.bodyLarge, .semibold))
                        .foregroundColor(theme.titleTextColor)
                    Text("Pick a starting point — you can change anything once you're writing.")
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
            }
            .padding(16)

            Divider().opacity(0.25)

            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(vm.templates) { template in
                        templateCard(template)
                    }
                    newTemplateCard
                }
                .padding(16)
            }
            .scrollContentBackground(.hidden)
        }
        .frame(width: 640, height: 480)
        .background(theme.backgroundColor)
        .sheet(item: $editing) { template in
            TemplateEditorView(template: template, isNew: isNew, sortOrder: vm.templates.count) { saved in
                vm.db.saveTemplate(saved)
                vm.loadTemplates()
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

    private func move(_ template: EntryTemplate, by delta: Int) {
        var ids = vm.templates.map(\.id)
        guard let i = ids.firstIndex(of: template.id), ids.indices.contains(i + delta) else { return }
        ids.swapAt(i, i + delta)
        vm.db.reorderTemplates(ids: ids)
        vm.loadTemplates()
    }

    private func previewText(for template: EntryTemplate) -> String {
        guard !template.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "A blank page" }
        let filled = TemplateExpander.expand(template.body, context: TemplateContext(
            date: Date(), prompt: PromptGenerator.today(), moodLabel: Mood.neutral.label))
        let text = MarkdownPlainPreview.text(filled, limit: 4)
        return text.isEmpty ? "A blank page" : text
    }

    private func templateCard(_ template: EntryTemplate) -> some View {
        Button {
            vm.createEntry(from: template)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Image(systemName: template.icon)
                        .font(OmegaTheme.font(.bodyLarge))
                        .foregroundColor(theme.accentColor)
                    Spacer()
                }
                Text(template.name)
                    .font(OmegaTheme.font(.body, .semibold))
                    .foregroundColor(theme.titleTextColor)
                // Rendered, filled-in preview (today's date/prompt) instead of
                // raw Markdown and {{variables}}.
                Text(previewText(for: template))
                    .font(OmegaTheme.font(.meta))
                    .foregroundColor(theme.secondaryTextColor)
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
                if !template.tags.isEmpty {
                    HStack(spacing: 3) {
                        ForEach(template.tags.prefix(3), id: \.self) { tag in
                            Text("#\(tag)")
                                .font(OmegaTheme.font(.meta))
                                .foregroundColor(theme.accentColor)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(theme.accentColor.opacity(0.12)))
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(height: 148, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(theme.cardColor.opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(theme.accentColor.opacity(0.14), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Template \(template.name)")
        .omegaTooltip("Start a new entry from “\(template.name)” · right-click to edit")
        .contextMenu {
            Button { isNew = false; editing = template } label: { Label("Edit Template…", systemImage: "pencil") }
            Button {
                var copy = template
                copy = EntryTemplate(name: template.name + " copy", body: template.body, tags: template.tags,
                                     icon: template.icon, sortOrder: vm.templates.count)
                vm.db.saveTemplate(copy); vm.loadTemplates()
            } label: { Label("Duplicate", systemImage: "doc.on.doc") }
            Divider()
            Button { move(template, by: -1) } label: { Label("Move Earlier", systemImage: "arrow.left") }
            Button { move(template, by: 1) } label: { Label("Move Later", systemImage: "arrow.right") }
            Divider()
            Button(role: .destructive) { pendingDelete = template } label: { Label("Delete Template", systemImage: "trash") }
        }
    }

    private var newTemplateCard: some View {
        Button {
            isNew = true
            editing = EntryTemplate(name: "", body: "", tags: [], icon: "doc.text", sortOrder: vm.templates.count)
        } label: {
            VStack(spacing: 7) {
                Image(systemName: "plus.circle")
                    .font(OmegaTheme.font(.title, .light))
                    .foregroundColor(theme.secondaryTextColor)
                Text("New Template")
                    .font(OmegaTheme.font(.meta, .medium))
                    .foregroundColor(theme.secondaryTextColor)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 148)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundColor(theme.secondaryTextColor.opacity(0.3))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New template")
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
                Button("Save") {
                    onSave(EntryTemplate(id: template.id, name: name.trimmingCharacters(in: .whitespaces),
                                         body: bodyText, tags: tags, icon: icon, sortOrder: template.sortOrder))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(theme.accentColor)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 500)
        .background(theme.backgroundColor)
    }
}
