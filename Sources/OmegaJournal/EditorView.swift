import SwiftUI
import UniformTypeIdentifiers

// MARK: - Editor View (with Markdown Shortcuts)

struct EditorView: View {
    @ObservedObject var vm: JournalViewModel
    let entry: JournalEntry
    @ObservedObject private var theme = ThemeManager.shared

    @State private var title = ""
    @State private var bodyText = ""
    @State private var mood: Mood = .neutral
    @State private var tags: [String] = []
    @State private var tagInput = ""
    @State private var saveStatus = "Saved"
    @State private var isBodyFocused = false
    @State private var showAttachSheet = false

    private var isDark: Bool { theme.colorScheme == .dark }
    private var currentWordCount: Int { bodyText.isEmpty ? 0 : bodyText.split(whereSeparator: { $0.isWhitespace }).count }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    TextField("Entry title...", text: $title, axis: .vertical)
                        .font(OmegaTheme.titleFont)
                        .textFieldStyle(.plain)
                        .lineLimit(1...3)
                        .onChange(of: title) { _, _ in autoSave() }

                    HStack(spacing: 12) {
                        Text(entry.createdAt.formatted(date: .complete, time: .shortened))
                            .font(OmegaTheme.metaFont)
                            .foregroundColor(.secondary)
                        Text("·")
                            .font(OmegaTheme.metaFont)
                            .foregroundColor(.secondary.opacity(0.5))
                        Text("\(currentWordCount) words")
                            .font(OmegaTheme.metaFont)
                            .foregroundColor(.secondary)
                        Spacer()
                        saveIndicator
                    }

                    // Mood selector
                    VStack(alignment: .leading, spacing: 10) {
                        Text("How are you feeling?")
                            .font(OmegaTheme.sectionTitleFont)
                        HStack(spacing: 8) {
                            ForEach(Mood.allCases) { moodButton($0) }
                        }
                    }

                    // Tags
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Tags")
                            .font(OmegaTheme.sectionTitleFont)
                        FlowLayout(spacing: 6) {
                            ForEach(tags, id: \.self) { tag in
                                HStack(spacing: 4) {
                                    Text("#\(tag)")
                                        .font(OmegaTheme.captionFont)
                                    Button {
                                        tags.removeAll { $0 == tag }
                                        autoSave()
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(theme.accentColor.opacity(0.12))
                                .clipShape(Capsule())
                            }
                            TextField("Add tag...", text: $tagInput)
                                .font(OmegaTheme.captionFont)
                                .textFieldStyle(.plain)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(theme.cardColor.opacity(0.6))
                                .clipShape(Capsule())
                                .frame(width: 100)
                                .onSubmit {
                                    let t = tagInput.trimmingCharacters(in: .whitespaces)
                                    if !t.isEmpty && !tags.contains(t) { tags.append(t); autoSave() }
                                    tagInput = ""
                                }
                        }
                    }

                    // Body editor
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Entry")
                                .font(OmegaTheme.sectionTitleFont)
                            Spacer()
                            // Markdown formatting buttons
                            HStack(spacing: 4) {
                                formatButton("Bold", shortcut: "⌘B") { wrapSelection(with: "**") }
                                formatButton("Italic", shortcut: "⌘I") { wrapSelection(with: "*") }
                                formatButton("Code", shortcut: "⌘`") { wrapSelection(with: "`") }
                                formatButton("Heading", shortcut: "⌘H") { prefixLine(with: "## ") }
                                formatButton("List", shortcut: "⌘L") { prefixLine(with: "- ") }
                                formatButton("Link", shortcut: "⌘K") { insertLink() }
                            }
                            .font(.system(size: 10))
                        }

                        TextEditor(text: $bodyText)
                            .font(OmegaTheme.bodyFont)
                            .frame(minHeight: 320)
                            .padding(14)
                            .background(
                                RoundedRectangle(cornerRadius: OmegaTheme.cardRadius)
                                    .fill(theme.cardColor.opacity(0.4))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: OmegaTheme.cardRadius)
                                    .strokeBorder(
                                        isBodyFocused
                                            ? theme.accentColor.opacity(0.5)
                                            : (isDark ? Color.white.opacity(0.10) : Color.black.opacity(0.10)),
                                        lineWidth: 1
                                    )
                            )
                            .onChange(of: bodyText) { _, _ in autoSave() }
                            .lineSpacing(5)
                            .onTapGesture { isBodyFocused = true }
                    }

                    // Attachments
                    if !entry.attachments.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Attachments")
                                .font(OmegaTheme.sectionTitleFont)
                            ForEach(entry.attachments) { attachment in
                                HStack(spacing: 8) {
                                    Image(systemName: attachment.isImage ? "photo" : "doc.fill")
                                        .foregroundColor(theme.accentColor.opacity(0.7))
                                    Text(attachment.filename)
                                        .font(.system(size: 12))
                                        .foregroundColor(.primary)
                                    Spacer()
                                    Button {
                                        vm.deleteAttachment(attachment)
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.system(size: 11))
                                            .foregroundColor(.red.opacity(0.7))
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(theme.cardColor.opacity(0.4))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                }
                .padding(OmegaTheme.contentPadding)
                .frame(maxWidth: OmegaTheme.contentMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }

            // Bottom bar
            HStack {
                Button("Cancel") { vm.stopEditing() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.escape, modifiers: [])
                Spacer()
                Button {
                    showAttachSheet = true
                } label: {
                    Label("Attach", systemImage: "paperclip")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .keyboardShortcut("a", modifiers: [.command, .shift])
                Button("Done") { vm.stopEditing() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.horizontal, OmegaTheme.contentPadding)
            .padding(.vertical, 12)
            .background(theme.sidebarColor)
            .overlay(alignment: .top) {
                Divider()
                    .background(isDark ? Color.white.opacity(0.10) : Color.black.opacity(0.10))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            title = entry.title
            bodyText = entry.body
            mood = entry.mood
            tags = entry.tags
        }
        .fileImporter(
            isPresented: $showAttachSheet,
            allowedContentTypes: [.image, .pdf, .plainText, .data],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                attachFile(url)
            }
        }
        // Keyboard shortcuts for markdown formatting
        .background(
            VStack {
                // These are handled by the command menu in OmegaJournalApp
            }
        )
    }

    // MARK: - Attachment

    private func attachFile(_ url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        do {
            let data = try Data(contentsOf: url)
            let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            vm.addAttachment(to: entry, data: data, filename: url.lastPathComponent, mimeType: mimeType)
        } catch {
            print("Failed to attach file: \(error)")
        }
    }

    // MARK: - Format Helpers

    private func formatButton(_ label: String, shortcut: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(theme.cardColor.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .help(shortcut)
    }

    private func wrapSelection(with marker: String) {
        bodyText = marker + bodyText + marker
    }

    private func prefixLine(with prefix: String) {
        bodyText = prefix + bodyText
    }

    private func insertLink() {
        bodyText += "[link text](url)"
    }

    // MARK: - Save

    private var saveIndicator: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(saveStatus == "Saved" ? Color.green : Color.orange)
                .frame(width: 6, height: 6)
            Text(saveStatus)
                .font(OmegaTheme.captionFont)
                .foregroundColor(.secondary.opacity(0.7))
        }
    }

    private func moodButton(_ m: Mood) -> some View {
        let sel = mood == m
        return Button {
            mood = m
            autoSave()
        } label: {
            VStack(spacing: 4) {
                Text(m.emoji)
                    .font(.system(size: 26))
                Text(m.label)
                    .font(.system(size: 10))
                    .foregroundColor(sel ? .primary : .secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: OmegaTheme.cardRadius)
                    .fill(sel ? theme.accentColor.opacity(0.18) : theme.cardColor.opacity(0.4))
            )
            .overlay(
                RoundedRectangle(cornerRadius: OmegaTheme.cardRadius)
                    .strokeBorder(sel ? theme.accentColor : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    private func autoSave() {
        saveStatus = "Saving..."
        var u = entry
        u.title = title
        u.body = bodyText
        u.mood = mood
        u.tags = tags
        vm.autoSave(u)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000)
            saveStatus = "Saved"
        }
    }
}
