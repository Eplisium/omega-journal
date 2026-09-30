import SwiftUI
import AppKit
import UniformTypeIdentifiers
import OmegaJournalCore

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
    @FocusState private var tagFieldFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Cached counts — recomputed only when the body changes, never per render.
    @State private var wordCount: Int
    @State private var charCount: Int
    @State private var selectionWords = 0
    /// Debounced copy of the body for the preview pane.
    @State private var previewText: String

    init(vm: JournalViewModel, entry: JournalEntry) {
        self.vm = vm
        self.entry = entry
        _title = State(initialValue: entry.title)
        _body_ = State(initialValue: entry.body)
        _mood = State(initialValue: entry.mood)
        _tags = State(initialValue: entry.tags)
        _fontSize = State(initialValue: Double(DatabaseManager.shared.getSetting("editorFontSize", defaultValue: "15")) ?? 15)
        _wordCount = State(initialValue: MarkdownLogic.wordCount(entry.body))
        _charCount = State(initialValue: entry.body.utf16.count)
        _previewText = State(initialValue: entry.body)
    }

    private static let fontSizes: [Double] = [13, 15, 17, 19, 22]

    private func stepFontSize(_ delta: Int) {
        let sizes = Self.fontSizes
        let idx = sizes.enumerated().min { abs($0.element - fontSize) < abs($1.element - fontSize) }?.offset ?? 1
        fontSize = sizes[max(0, min(sizes.count - 1, idx + delta))]
    }

    private var palette: MarkdownEditorPalette {
        MarkdownEditorPalette(
            text: NSColor(theme.bodyTextColor),
            muted: NSColor(theme.secondaryTextColor),
            accent: NSColor(theme.accentColor),
            code: NSColor(theme.accentColor).blended(withFraction: 0.35, of: .systemOrange) ?? .systemOrange,
            link: NSColor(theme.accentColor),
            tag: NSColor(theme.accentColor).withAlphaComponent(0.85))
    }

    private var renderStyle: MarkdownRenderStyle {
        MarkdownRenderStyle(linkColor: theme.accentColor, codeColor: theme.accentColor, mutedColor: theme.secondaryTextColor)
    }

    /// Esc closes transient UI first; a stray Esc never leaves the editor.
    private func handleEscape() -> Bool {
        if controller.isFindBarVisible { controller.hideFindBar(); return true }
        if vm.isZenMode { withAnimation(reduceMotion ? nil : .default) { vm.isZenMode = false }; return true }
        if showTagField { showTagField = false; tagInput = ""; controller.focus(); return true }
        return false
    }

    private var readingTime: String {
        // Empty drafts contribute no fictional minutes (matches JournalEntry).
        let m = OmegaCore.readingMinutes(forWordCount: wordCount)
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
        .onChange(of: body_) { _, new in
            wordCount = MarkdownLogic.wordCount(new)
            charCount = new.utf16.count
            persist()
        }
        .task(id: body_) {
            // Debounce the (relatively expensive) preview render while typing in split mode.
            if previewText != body_ {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if Task.isCancelled { return }
            }
            previewText = body_
        }
        .onExitCommand { _ = handleEscape() }
        .background(shortcutButtons)
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
            .accessibilityLabel("Done editing")
            .help("Done (⌘↩)")

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
                            .scaleEffect(mood == m && !reduceMotion ? 1.05 : 1.0)
                    }
                    .buttonStyle(.plain)
                    .omegaTooltip(m.label)
                    .accessibilityLabel("Mood: \(m.label)")
                    .accessibilityAddTraits(mood == m ? .isSelected : [])
                }
            }
            .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.7), value: mood)

            Spacer()

            // Editor mode switcher
            Picker("", selection: $vm.editorMode) {
                ForEach(JournalViewModel.EditorMode.allCases) { m in
                    Image(systemName: m.icon).accessibilityLabel(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 108)
            .omegaTooltip("Write / Split / Preview")
            .accessibilityLabel("Editor mode")

            Menu {
                ForEach(Self.fontSizes, id: \.self) { size in
                    Button {
                        fontSize = size
                    } label: {
                        if Int(fontSize) == Int(size) { Label("\(Int(size)) pt", systemImage: "checkmark") }
                        else { Text("\(Int(size)) pt") }
                    }
                }
                Divider()
                Button("Larger") { stepFontSize(1) }
                Button("Smaller") { stepFontSize(-1) }
                Divider()
                Toggle("Typewriter Scrolling", isOn: $isTypewriter)
            } label: {
                Image(systemName: "textformat.size")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Text size & typewriter scrolling")
            .accessibilityLabel("Text size")

            ActionButton(icon: "paperclip", color: theme.accentColor, active: !entry.attachments.isEmpty, tooltip: "Attach file") {
                attachFile()
            }
            .accessibilityLabel(entry.attachments.isEmpty ? "Attach file" : "Attach file, \(entry.attachments.count) attached")

            ActionButton(icon: "arrow.up.left.and.arrow.down.right", color: theme.accentColor, active: false, tooltip: "Zen Mode (⌃⌘F)") {
                withAnimation(reduceMotion ? nil : .default) { vm.isZenMode = true }
            }
            .accessibilityLabel("Enter Zen mode")
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
                group([.link, .codeBlock, .divider, .toggleTask])
                sep

                Button { showTagField.toggle(); if showTagField { tagFieldFocused = true } } label: {
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
                .accessibilityLabel(showTagField ? "Hide tag field" : "Add tag")

                ForEach(tags, id: \.self) { tag in
                    HStack(spacing: 3) {
                        Text("#\(tag)").font(.system(size: 10))
                        Button { tags.removeAll { $0 == tag } } label: {
                            Image(systemName: "xmark").font(.system(size: 7, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove tag \(tag)")
                    }
                    .accessibilityElement(children: .contain)
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
                        .focused($tagFieldFocused)
                        .accessibilityLabel("New tag")
                        .onSubmit { commitTag() }

                    ForEach(tagSuggestions, id: \.self) { s in
                        Button { tagInput = s; commitTag() } label: {
                            Text("#\(s)").font(.system(size: 10))
                                .foregroundColor(theme.secondaryTextColor)
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(Capsule().strokeBorder(theme.secondaryTextColor.opacity(0.4), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Suggested tag \(s)")
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(theme.cardColor.opacity(0.3))
    }

    private var tagSuggestions: [String] {
        MarkdownLogic.tagSuggestions(prefix: tagInput, from: vm.allTags.map(\.tag), excluding: tags)
    }

    /// Hidden buttons that carry editor-local shortcuts (font size, task toggle).
    private var shortcutButtons: some View {
        ZStack {
            Button("Larger Text") { stepFontSize(1) }.keyboardShortcut("=", modifiers: .command)
            Button("Smaller Text") { stepFontSize(-1) }.keyboardShortcut("-", modifiers: .command)
            Button("Find in Entry") { controller.showFind() }.keyboardShortcut("f", modifiers: [.command, .option])
            Button("Find and Replace in Entry") { controller.showFind(replace: true) }.keyboardShortcut("f", modifiers: [.command, .option, .shift])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
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
            .omegaTooltip(cmd.label)
            .accessibilityLabel(cmd.label)
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
                        withAnimation(reduceMotion ? nil : .default) { vm.isZenMode = false }
                    } label: {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .font(.system(size: 12))
                            .foregroundColor(theme.secondaryTextColor)
                    }
                    .buttonStyle(.plain)
                    .omegaTooltip("Exit Zen Mode")
                    .accessibilityLabel("Exit Zen mode")
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
            }

            TextField("Title", text: $title)
                .textFieldStyle(.plain)
                .font(.system(size: vm.isZenMode ? 28 : 22, weight: .bold, design: .serif))
                .foregroundColor(theme.titleTextColor)
                .focused($titleFocused)
                .accessibilityLabel("Entry title")
                .padding(.horizontal, vm.isZenMode ? 20 : 18)
                .padding(.top, vm.isZenMode ? 10 : 18)
                .padding(.bottom, 6)

            MarkdownTextEditor(
                text: $body_,
                font: .systemFont(ofSize: fontSize),
                lineSpacing: 7,
                isTypewriterMode: isTypewriter,
                controller: controller,
                palette: palette,
                onCommandReturn: { vm.stopEditing() },
                onEscape: { handleEscape() },
                onSelectionWords: { selectionWords = $0 }
            )
            .overlay(alignment: .topLeading) {
                if body_.isEmpty {
                    Text("Write something…")
                        .font(.system(size: fontSize))
                        .foregroundColor(theme.secondaryTextColor.opacity(0.6))
                        .padding(.horizontal, 13)
                        .padding(.top, 12)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, vm.isZenMode ? 12 : 10)
            .padding(.bottom, 8)
        }
        .frame(maxWidth: vm.isZenMode ? 760 : .infinity)
        .frame(maxWidth: .infinity)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
    }

    /// Dragging files from Finder onto the editor attaches them.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }
        for provider in fileProviders {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var url: URL?
                if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                else if let u = item as? URL { url = u }
                guard let url, url.isFileURL else { return }
                Task { @MainActor in attachURLs([url]) }
            }
        }
        return true
    }

    private var previewPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !title.isEmpty {
                    Text(title)
                        .font(.system(size: 24, weight: .bold, design: .serif))
                        .foregroundColor(theme.titleTextColor)
                }
                if previewText.isEmpty {
                    Text("Nothing to preview yet.")
                        .font(.system(size: 13))
                        .foregroundColor(theme.secondaryTextColor)
                } else {
                    MarkdownBodyView(markdown: previewText, style: renderStyle, textColor: theme.bodyTextColor)
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
            if selectionWords > 0 {
                Text("(\(selectionWords) selected)")
            }
            Text("·")
            Text("\(charCount) chars")
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
                Text(vm.saveState == .pending ? "Saving…" : "Saved")
                    .foregroundColor(theme.secondaryTextColor.opacity(0.7))
                    .accessibilityLabel(vm.saveState == .pending ? "Saving" : "All changes saved")
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
        // Commas are the text-column separator; a comma inside a tag name would
        // be misparsed as two tags on the next reconcile. Strip them at input.
        let t = tagInput.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: ",", with: "")
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

    /// Largest single attachment accepted (files are encrypted and stored in-app).
    static let maxAttachmentBytes = 25 * 1024 * 1024

    private func attachFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.title = "Attach files to this entry"
        guard panel.runModal() == .OK else { return }
        attachURLs(panel.urls)
    }

    private func attachURLs(_ urls: [URL]) {
        let limit = Self.maxAttachmentBytes
        let target = entry
        Task {
            for url in urls {
                // Read off the main thread so large files don't freeze the editor.
                let loaded: Result<Data, AttachError> = await Task.detached(priority: .userInitiated) {
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                    if size > limit { return .failure(.tooLarge(url.lastPathComponent)) }
                    guard let data = try? Data(contentsOf: url) else { return .failure(.unreadable(url.lastPathComponent)) }
                    if data.count > limit { return .failure(.tooLarge(url.lastPathComponent)) }
                    return .success(data)
                }.value
                switch loaded {
                case .success(let data):
                    let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                    vm.addAttachment(to: target, data: data, filename: url.lastPathComponent, mimeType: type)
                case .failure(.tooLarge(let name)):
                    vm.showToast("\(name) is too large to attach (limit \(limit / 1_048_576) MB)", isError: true)
                case .failure(.unreadable(let name)):
                    vm.showToast("Couldn't read \(name)", isError: true)
                }
            }
        }
    }

    private enum AttachError: Error { case tooLarge(String), unreadable(String) }
}

extension Notification.Name {
    static let formatCommand = Notification.Name("OmegaJournal.formatCommand")
}
