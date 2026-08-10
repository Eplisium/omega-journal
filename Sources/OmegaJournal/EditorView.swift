import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Editor

struct EditorView: View {
    @ObservedObject var vm: JournalViewModel
    let entry: JournalEntry

    @ObservedObject private var theme = ThemeManager.shared
    @StateObject private var controller = MarkdownEditorController()

    @State private var title: String
    @State private var body_: String
    @State private var mood: Mood
    @State private var tags: [String]
    @State private var tagInput = ""
    @State private var showTagField = false
    @State private var isTypewriter = false
    @State private var fontSize: Double
    @FocusState private var titleFocused: Bool

    init(vm: JournalViewModel, entry: JournalEntry) {
        self.vm = vm
        self.entry = entry
        _title = State(initialValue: entry.title)
        _body_ = State(initialValue: entry.body)
        _mood = State(initialValue: entry.mood)
        _tags = State(initialValue: entry.tags)
        _fontSize = State(initialValue: Double(DatabaseManager.shared.getSetting("editorFontSize", defaultValue: "15")) ?? 15)
    }

    private var wordCount: Int {
        body_.isEmpty ? 0 : body_.split(whereSeparator: { $0.isWhitespace }).count
    }

    private var readingTime: String {
        let m = max(1, Int(ceil(Double(wordCount) / 220.0)))
        return m == 1 ? "1 min read" : "\(m) min read"
    }

    var body: some View {
        VStack(spacing: 0) {
            if !vm.isZenMode {
                topBar
                Divider().opacity(0.25)
                formattingToolbar
                Divider().opacity(0.25)
            }

            contentArea

            Divider().opacity(0.25)
            statusBar
        }
        .background(theme.backgroundColor)
        .onChange(of: body_) { _, _ in persist() }
        .onChange(of: title) { _, _ in persist() }
        .onChange(of: mood) { _, _ in persist() }
        .onChange(of: tags) { _, _ in persist() }
        .onChange(of: fontSize) { _, new in
            DatabaseManager.shared.setSetting("editorFontSize", value: "\(Int(new))")
        }
        .onDisappear { vm.flushPendingSave() }
        .onReceive(NotificationCenter.default.publisher(for: .formatCommand)) { note in
            if let cmd = note.object as? MarkdownCommand { controller.apply(cmd) }
        }
        .onAppear {
            if title.isEmpty { titleFocused = true }
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            Button {
                vm.stopEditing()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                    Text("Done").font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(theme.accentColor)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])

            Divider().frame(height: 16).opacity(0.25)

            // Mood picker
            HStack(spacing: 2) {
                ForEach(Mood.allCases) { m in
                    Button { mood = m } label: {
                        Text(m.emoji)
                            .font(.system(size: 14))
                            .frame(width: 26, height: 24)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(mood == m ? m.color.opacity(0.28) : .clear)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(mood == m ? m.color.opacity(0.65) : .clear, lineWidth: 1)
                            )
                            .scaleEffect(mood == m ? 1.05 : 1.0)
                    }
                    .buttonStyle(.plain)
                    .help(m.label)
                }
            }
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: mood)

            Spacer()

            // Editor mode switcher
            Picker("", selection: $vm.editorMode) {
                ForEach(JournalViewModel.EditorMode.allCases) { m in
                    Image(systemName: m.icon).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 108)
            .help("Write / Split / Preview")

            ActionButton(icon: "textformat.size", color: theme.accentColor, active: false, tooltip: "Text size") {}
                .overlay {
                    Menu {
                        ForEach([13.0, 15.0, 17.0, 19.0, 22.0], id: \.self) { size in
                            Button("\(Int(size)) pt") { fontSize = size }
                        }
                        Divider()
                        Toggle("Typewriter Scrolling", isOn: $isTypewriter)
                    } label: { Color.clear }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .opacity(0.02)
                }

            ActionButton(icon: "paperclip", color: theme.accentColor, active: !entry.attachments.isEmpty, tooltip: "Attach file") {
                attachFile()
            }

            ActionButton(icon: "arrow.up.left.and.arrow.down.right", color: theme.accentColor, active: false, tooltip: "Zen Mode (⌃⌘F)") {
                withAnimation { vm.isZenMode = true }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    // MARK: Formatting toolbar

    private var formattingToolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                group([.bold, .italic, .strikethrough, .code])
                sep
                group([.heading1, .heading2, .heading3])
                sep
                group([.bulletList, .numberedList, .checkbox, .quote])
                sep
                group([.link, .codeBlock, .divider])
                sep

                Button { showTagField.toggle() } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "number").font(.system(size: 10))
                        Text("Tags").font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(theme.accentColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(theme.accentColor.opacity(0.14)))
                }
                .buttonStyle(.plain)

                ForEach(tags, id: \.self) { tag in
                    HStack(spacing: 3) {
                        Text("#\(tag)").font(.system(size: 10))
                        Button { tags.removeAll { $0 == tag } } label: {
                            Image(systemName: "xmark").font(.system(size: 7, weight: .bold))
                        }
                        .buttonStyle(.plain)
                    }
                    .foregroundColor(theme.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(theme.accentColor.opacity(0.12)))
                }

                if showTagField {
                    TextField("tag", text: $tagInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 10))
                        .frame(width: 70)
                        .foregroundColor(theme.titleTextColor)
                        .onSubmit { commitTag() }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(theme.cardColor.opacity(0.3))
    }

    private var sep: some View {
        Divider().frame(height: 14).opacity(0.25).padding(.horizontal, 3)
    }

    private func group(_ commands: [MarkdownCommand]) -> some View {
        ForEach(commands, id: \.label) { cmd in
            Button { controller.apply(cmd) } label: {
                Image(systemName: cmd.icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.bodyTextColor)
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(cmd.label)
        }
    }

    // MARK: Content

    private var contentArea: some View {
        HStack(spacing: 0) {
            if vm.editorMode != .preview {
                writingPane
                    .frame(maxWidth: vm.editorMode == .split ? .infinity : nil)
            }
            if vm.editorMode == .split {
                Divider().opacity(0.25)
            }
            if vm.editorMode != .write {
                previewPane
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var writingPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            if vm.isZenMode {
                HStack {
                    Spacer()
                    Button {
                        withAnimation { vm.isZenMode = false }
                    } label: {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .font(.system(size: 12))
                            .foregroundColor(theme.secondaryTextColor)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.escape, modifiers: [])
                    .help("Exit Zen Mode")
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
            }

            TextField("Title", text: $title)
                .textFieldStyle(.plain)
                .font(.system(size: vm.isZenMode ? 28 : 22, weight: .bold, design: .serif))
                .foregroundColor(theme.titleTextColor)
                .focused($titleFocused)
                .padding(.horizontal, vm.isZenMode ? 20 : 18)
                .padding(.top, vm.isZenMode ? 10 : 18)
                .padding(.bottom, 6)

            MarkdownTextEditor(
                text: $body_,
                font: .systemFont(ofSize: fontSize),
                lineSpacing: 7,
                isTypewriterMode: isTypewriter,
                controller: controller,
                onCommandReturn: { vm.stopEditing() }
            )
            .padding(.horizontal, vm.isZenMode ? 12 : 10)
            .padding(.bottom, 8)
        }
        .frame(maxWidth: vm.isZenMode ? 760 : .infinity)
        .frame(maxWidth: .infinity)
    }

    private var previewPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !title.isEmpty {
                    Text(title)
                        .font(.system(size: 24, weight: .bold, design: .serif))
                        .foregroundColor(theme.titleTextColor)
                }
                if body_.isEmpty {
                    Text("Nothing to preview yet.")
                        .font(.system(size: 13))
                        .foregroundColor(theme.secondaryTextColor)
                } else {
                    Text(MarkdownRenderer.render(body_))
                        .foregroundColor(theme.bodyTextColor)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .background(theme.cardColor.opacity(0.18))
    }

    // MARK: Status bar

    private var statusBar: some View {
        HStack(spacing: 12) {
            Label("\(wordCount) words", systemImage: "text.word.spacing")
            Text("·")
            Text("\(body_.count) chars")
            Text("·")
            Text(readingTime)
            if !entry.attachments.isEmpty {
                Text("·")
                Label("\(entry.attachments.count)", systemImage: "paperclip")
            }
            Spacer()
            if vm.isZenMode {
                Text("⎋ exit zen").foregroundColor(theme.secondaryTextColor.opacity(0.7))
            } else {
                Text("Autosaved").foregroundColor(theme.secondaryTextColor.opacity(0.7))
            }
        }
        .font(.system(size: 10))
        .foregroundColor(theme.secondaryTextColor)
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(theme.cardColor.opacity(0.3))
    }

    // MARK: Actions

    private func commitTag() {
        let t = tagInput.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        if !t.isEmpty && !tags.contains(t) { tags.append(t) }
        tagInput = ""
    }

    private func persist() {
        var updated = entry
        updated.title = title
        updated.body = body_
        updated.mood = mood
        updated.tags = tags
        vm.autoSave(updated)
    }

    private func attachFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.title = "Attach files to this entry"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let data = try? Data(contentsOf: url) else { continue }
            let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            vm.addAttachment(to: entry, data: data, filename: url.lastPathComponent, mimeType: type)
        }
    }
}

extension Notification.Name {
    static let formatCommand = Notification.Name("OmegaJournal.formatCommand")
}
