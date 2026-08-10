import SwiftUI

// MARK: - Template Picker

struct TemplatePickerView: View {
    @ObservedObject var vm: JournalViewModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var theme = ThemeManager.shared

    @State private var showingEditor = false
    @State private var draftName = ""
    @State private var draftBody = ""
    @State private var draftTags = ""

    private let columns = [GridItem(.adaptive(minimum: 170), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Start from a Template")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(theme.titleTextColor)
                    Text("Reusable structures for recurring entries")
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryTextColor)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundColor(theme.secondaryTextColor)
                }
                .buttonStyle(.plain)
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
        .frame(width: 620, height: 460)
        .background(theme.backgroundColor)
        .sheet(isPresented: $showingEditor) { templateEditor }
    }

    private func templateCard(_ template: EntryTemplate) -> some View {
        Button {
            vm.createEntry(from: template)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Image(systemName: template.icon)
                        .font(.system(size: 15))
                        .foregroundColor(theme.accentColor)
                    Spacer()
                }
                Text(template.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.titleTextColor)
                Text(template.body.isEmpty ? "Empty page" : template.body)
                    .font(.system(size: 10))
                    .foregroundColor(theme.secondaryTextColor)
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
                if !template.tags.isEmpty {
                    HStack(spacing: 3) {
                        ForEach(template.tags.prefix(3), id: \.self) { tag in
                            Text("#\(tag)")
                                .font(.system(size: 8.5))
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
        .contextMenu {
            Button(role: .destructive) {
                vm.db.deleteTemplate(id: template.id)
                vm.loadTemplates()
            } label: { Label("Delete Template", systemImage: "trash") }
        }
    }

    private var newTemplateCard: some View {
        Button {
            draftName = ""; draftBody = ""; draftTags = ""
            showingEditor = true
        } label: {
            VStack(spacing: 7) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 20, weight: .light))
                    .foregroundColor(theme.secondaryTextColor)
                Text("New Template")
                    .font(.system(size: 11, weight: .medium))
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
    }

    private var templateEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Template")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(theme.titleTextColor)

            TextField("Name", text: $draftName)
                .textFieldStyle(.roundedBorder)

            TextField("Tags (comma separated)", text: $draftTags)
                .textFieldStyle(.roundedBorder)

            Text("Body")
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryTextColor)
            TextEditor(text: $draftBody)
                .font(.system(size: 12, design: .monospaced))
                .frame(height: 180)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(theme.cardColor.opacity(0.5)))

            HStack {
                Spacer()
                Button("Cancel") { showingEditor = false }
                Button("Save") {
                    let tags = draftTags.split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    let t = EntryTemplate(
                        name: draftName.isEmpty ? "Untitled Template" : draftName,
                        body: draftBody,
                        tags: tags,
                        sortOrder: vm.templates.count
                    )
                    vm.db.saveTemplate(t)
                    vm.loadTemplates()
                    showingEditor = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(draftName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 460)
        .background(theme.backgroundColor)
    }
}
