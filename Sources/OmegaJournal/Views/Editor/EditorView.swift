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
    @AppStorage(ReadingPreferences.editorTypewriterKey) private var isTypewriter = false
    @AppStorage(ReadingPreferences.editorDimParagraphsKey) private var dimOthers = false
    @AppStorage(ReadingPreferences.editorFontKey) private var fontChoiceRaw = EditorFontChoice.system.rawValue
    @AppStorage(ReadingPreferences.editorLineHeightKey) private var lineHeight = WritingFocusLogic.defaultLineHeight
    @AppStorage(ReadingPreferences.editorColumnWidthKey) private var columnWidth = WritingFocusLogic.defaultColumnWidth
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

    // Writing session (footer): timer, sprint, goal ring.
    @State private var sessionStart = Date()
    @State private var sessionStartWords: Int
    @State private var otherWordsToday = 0
    @State private var sprint: WritingSprint?
    @State private var sprintNotified = false

    // Optional place/weather stamp (stored as a trailing comment line in the body).
    @State private var stamp: EntryStamp
    @State private var showStampPopover = false
    @State private var showFocusPopover = false
    @State private var showRecorder = false
    @State private var showHistory = false

    // Slash / [[ popover.
    @State private var suggestion: EditorSuggestion?
    @State private var suggestionIndex = 0

    // Split layout: measured content width, and the visible tab when Split
    // falls back to one pane at a time in a narrow column.
    @State private var contentWidth: Double = 0
    @State private var splitTabShowsPreview = false

    init(vm: JournalViewModel, entry: JournalEntry) {
        self.vm = vm
        self.entry = entry
        let parts = EntryStampCodec.split(entry.body)
        _title = State(initialValue: entry.title)
        _body_ = State(initialValue: parts.rest)
        _stamp = State(initialValue: parts.stamp ?? EntryStamp())
        _mood = State(initialValue: entry.mood)
        _tags = State(initialValue: entry.tags)
        _fontSize = State(initialValue: vm.editorFontSize)
        _wordCount = State(initialValue: MarkdownLogic.wordCount(parts.rest))
        _sessionStartWords = State(initialValue: MarkdownLogic.wordCount(parts.rest))
        _charCount = State(initialValue: parts.rest.utf16.count)
        _previewText = State(initialValue: parts.rest)
    }

    private var fontChoice: EditorFontChoice { EditorFontChoice.from(raw: fontChoiceRaw) }
    private var editorNSFont: NSFont { ReadingPreferences.editorFont(fontChoice, size: fontSize) }

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
        .onChange(of: stamp) { _, _ in persist() }
        .onChange(of: fontSize) { _, new in
            vm.editorFontSize = new
        }
        .onDisappear {
            vm.flushPendingSave()
            // Edit session over: take a (throttled) version-history snapshot of the in-memory entry,
            // which `autoSave` keeps current. Hidden entries' revisions are sealed like their bodies.
            if let current = vm.entry(id: entry.id) { vm.snapshotRevision(of: current) }
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { now in
            if let sprint, !sprintNotified, sprint.isFinished(at: now) {
                sprintNotified = true
                vm.showToast("Sprint complete — +\(sprint.wordsWritten(currentWords: wordCount)) words")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .formatCommand)) { note in
            if let cmd = note.object as? MarkdownCommand { controller.apply(cmd) }
        }
        .onAppear {
            if title.isEmpty { titleFocused = true }
            loadGoalBaseline()
            // Entries from before version history existed get a kept baseline so the first edit is undoable.
            if vm.db.revisionCount(entryId: entry.id) == 0 {
                vm.db.snapshotRevision(of: entry, isAuto: false)
            }
        }
    }

    // MARK: Goal ring

    private var entryCountsTowardToday: Bool { entry.createdAt >= Calendar.current.startOfDay(for: Date()) }

    /// Words written today in OTHER entries (the goal counts entries created today, like the Today view).
    private func loadGoalBaseline() {
        let total = vm.db.wordCountSum(since: Calendar.current.startOfDay(for: Date()))
        otherWordsToday = max(0, total - (entryCountsTowardToday ? entry.wordCount : 0))
    }

    private var goalRing: GoalRingState {
        let target = GoalManager.shared.goals.first { $0.type == .dailyWords }?.target ?? 0
        return WritingSessionMath.goalRing(otherWordsToday: otherWordsToday,
                                           liveEntryWords: entryCountsTowardToday ? wordCount : 0, target: target)
    }

    // MARK: Top bar

    /// Picks the widest top bar that fits. At the 940pt minimum window the
    /// detail column is ~458pt; the old single layout needed ~540pt of
    /// fixed-size controls, so the whole split view overflowed the window and
    /// clipped prose, the formatting row and the save status on the right.
    private var topBar: some View {
        ViewThatFits(in: .horizontal) {
            topBarRow(compactMood: false, iconModes: false)
            topBarRow(compactMood: true, iconModes: false)
            topBarRow(compactMood: true, iconModes: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        // Popovers/sheets live outside ViewThatFits so they're attached once,
        // anchored at the trailing tools.
        .overlay(alignment: .trailing) {
            Color.clear.frame(width: 110, height: 1)
                .popover(isPresented: $showFocusPopover, arrowEdge: .bottom) { WritingFocusSettingsView() }
                .background(Color.clear.popover(isPresented: $showStampPopover, arrowEdge: .bottom) { EntryStampEditor(stamp: $stamp) })
                .background(Color.clear.popover(isPresented: $showRecorder, arrowEdge: .bottom) { AudioRecorderPopover(vm: vm, entry: entry) })
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
        .sheet(isPresented: $showHistory) {
            RevisionHistoryView(vm: vm, entry: vm.entry(id: entry.id) ?? entry) { newTitle, newBody in
                title = newTitle
                let parts = EntryStampCodec.split(newBody)
                body_ = parts.rest
                stamp = parts.stamp ?? EntryStamp()
            }
        }
    }

    private func topBarRow(compactMood: Bool, iconModes: Bool) -> some View {
        HStack(spacing: 10) {
            Button {
                vm.stopEditing()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(OmegaTheme.font(.meta, .semibold))
                    Text("Done").font(OmegaTheme.font(.caption, .medium))
                }
                .foregroundColor(theme.accentColor)
                .fixedSize()
            }
            .buttonStyle(.plain)
            .layoutPriority(2)
            .accessibilityLabel("Done editing")
            .help("Done (⌘↩)")

            Divider().frame(height: 16).opacity(0.25)

            if compactMood { moodMenu } else { moodRow }

            Spacer(minLength: 4)

            modePicker(iconOnly: iconModes)

            ActionButton(icon: "text.alignleft", color: theme.accentColor, active: isTypewriter || dimOthers || columnWidth > 0, tooltip: "Focus & typography") {
                showFocusPopover.toggle()
            }
            .accessibilityLabel("Focus and typography")

            ActionButton(icon: "paperclip", color: theme.accentColor, active: !entry.attachments.isEmpty, tooltip: "Attach file") {
                attachFile()
            }
            .accessibilityLabel(entry.attachments.isEmpty ? "Attach file" : "Attach file, \(entry.attachments.count) attached")

            moreMenu
        }
        .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.7), value: mood)
    }

    private var moodRow: some View {
        HStack(spacing: 2) {
            ForEach(Mood.allCases) { m in
                Button { mood = m } label: {
                    Text(m.emoji)
                        .font(OmegaTheme.font(.bodyLarge))
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
    }

    private var moodMenu: some View {
        Menu {
            ForEach(Mood.allCases) { m in
                Button("\(m.emoji)  \(m.label)") { mood = m }
            }
        } label: {
            Text(mood.emoji).font(OmegaTheme.font(.bodyLarge))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Mood: \(mood.label). Change mood")
    }

    /// Labeled Write / Split / Preview; icon-only (still named for VoiceOver
    /// and tooltips) when the column is too narrow for the words.
    private func modePicker(iconOnly: Bool) -> some View {
        Picker("Editor mode", selection: $vm.editorMode) {
            ForEach(JournalViewModel.EditorMode.allCases) { m in
                if iconOnly {
                    Label(m.rawValue, systemImage: m.icon).labelStyle(.iconOnly).tag(m)
                } else {
                    Text(m.rawValue).tag(m)
                }
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .omegaTooltip("Write, split view, or preview")
        .accessibilityLabel("Editor mode")
    }

    /// Less frequent tools share one menu: place/weather, voice memo, history,
    /// text size, find & replace and Zen. Their keyboard shortcuts still work
    /// (hidden buttons + app menus) and are shown here.
    private var moreMenu: some View {
        Menu {
            Button { showStampPopover = true } label: {
                Label(stamp.isEmpty ? "Add Place & Weather…" : "Edit Place & Weather…", systemImage: "mappin.and.ellipse")
            }
            Button { showRecorder = true } label: {
                Label("Record Voice Memo…", systemImage: "mic")
            }
            Button {
                vm.flushPendingSave()
                if let current = vm.entry(id: entry.id) { vm.snapshotRevision(of: current) }
                showHistory = true
            } label: {
                Label("Version History…", systemImage: "clock.arrow.circlepath")
            }
            Divider()
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
                Button("Larger  ⌘=") { stepFontSize(1) }
                Button("Smaller  ⌘-") { stepFontSize(-1) }
            } label: {
                Label("Text Size (\(Int(fontSize)) pt)", systemImage: "textformat.size")
            }
            Button { controller.showFind(replace: true) } label: {
                Label("Find and Replace…  ⌥⇧⌘F", systemImage: "magnifyingglass")
            }
            .disabled(!paneLayout.showsSource)
            Button {
                withAnimation(reduceMotion ? nil : .default) { vm.isZenMode = true }
            } label: {
                Label("Zen Mode  ⌃⌘F", systemImage: "arrow.up.left.and.arrow.down.right")
            }
        } label: {
            // The Label title is what VoiceOver reads for a Menu (a modifier
            // label on the Menu itself is ignored).
            Label("More editor tools", systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
                .font(OmegaTheme.font(.bodyLarge, .medium))
                .foregroundColor(.secondary)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More: place & weather, voice memo, version history, text size, find & replace, Zen mode")
        .accessibilityLabel("More editor tools")
    }

    // MARK: Formatting toolbar

    /// Everyday formatting as icons, then one labeled Format menu holding
    /// every command (with its shortcut), then tags. The old row of 15 icons
    /// scrolled the Tags control out of a narrow column.
    private var formattingToolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                group(MarkdownCommand.toolbarPrimary)
                    .disabled(!paneLayout.showsSource)
                formatMenu
                sep

                Button { showTagField.toggle(); if showTagField { tagFieldFocused = true } } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "number").font(OmegaTheme.font(.meta))
                        Text("Tags").font(OmegaTheme.font(.meta, .medium))
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
                        Text("#\(tag)").font(OmegaTheme.font(.meta))
                        Button { tags.removeAll { $0 == tag } } label: {
                            Image(systemName: "xmark").font(OmegaTheme.font(.meta, .bold))
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
                        .font(OmegaTheme.font(.meta))
                        .frame(width: 70)
                        .foregroundColor(theme.titleTextColor)
                        .focused($tagFieldFocused)
                        .accessibilityLabel("New tag")
                        .onSubmit { commitTag() }

                    ForEach(tagSuggestions, id: \.self) { s in
                        Button { tagInput = s; commitTag() } label: {
                            Text("#\(s)").font(OmegaTheme.font(.meta))
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

    private var formatMenu: some View {
        Menu {
            ForEach(Array(MarkdownCommand.formatMenuSections.enumerated()), id: \.offset) { index, section in
                if index > 0 { Divider() }
                ForEach(section, id: \.label) { cmd in
                    Button { controller.apply(cmd) } label: {
                        Label("\(cmd.label)  \(cmd.shortcutHint)", systemImage: cmd.icon)
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text("Format").font(OmegaTheme.font(.meta, .medium))
                Image(systemName: "chevron.down").font(OmegaTheme.font(.meta))
                    .accessibilityHidden(true)
            }
            .foregroundColor(theme.bodyTextColor)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Format")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 4)
        .disabled(!paneLayout.showsSource)
        .help("All formatting commands and their shortcuts")
        .accessibilityLabel("Format")
    }

    private var tagSuggestions: [String] {
        TagPath.suggestions(prefix: tagInput, from: vm.allTags.map(\.tag), excluding: tags, limit: 5)
    }

    /// Hidden buttons that carry editor-local shortcuts (font size, task toggle).
    private var shortcutButtons: some View {
        ZStack {
            Button("Larger Text") { stepFontSize(1) }.keyboardShortcut("=", modifiers: .command)
            Button("Smaller Text") { stepFontSize(-1) }.keyboardShortcut("-", modifiers: .command)
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
                    .font(OmegaTheme.font(.meta, .medium))
                    .foregroundColor(theme.bodyTextColor)
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .omegaTooltip("\(cmd.label) (\(cmd.shortcutHint))")
            .accessibilityLabel(cmd.label)
        }
    }

    // MARK: Content

    private var paneMode: EditorPaneMode {
        switch vm.editorMode {
        case .write: .write
        case .split: .split
        case .preview: .preview
        }
    }

    private var paneLayout: EditorPaneLayout {
        EditorLayoutPolicy.layout(mode: paneMode, availableWidth: contentWidth, tabShowsPreview: splitTabShowsPreview)
    }

    /// The writing pane keeps one structural position in every mode, so
    /// write → split → preview → write never rebuilds the NSTextView: caret,
    /// selection, scroll position and undo all survive. In Preview the source
    /// stays mounted underneath (hidden, unfocusable) and the preview covers it.
    private var contentArea: some View {
        let layout = paneLayout
        return VStack(spacing: 0) {
            if case .tabbed(let showingPreview) = layout {
                splitTabs(showingPreview: showingPreview)
                Divider().opacity(0.25)
            }
            HStack(spacing: 0) {
                ZStack {
                    writingPane
                        .opacity(layout.showsSource ? 1 : 0)
                        .allowsHitTesting(layout.showsSource)
                        .accessibilityHidden(!layout.showsSource)
                    if layout.previewCoversSource {
                        previewPane
                            .background(theme.backgroundColor)
                    }
                }
                .frame(maxWidth: .infinity)
                if layout == .sideBySide {
                    Divider().opacity(0.25)
                    previewPane
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { contentWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, w in contentWidth = w }
            }
        )
        .onChange(of: layout.showsSource) { _, shows in
            // Coming back from the preview: the caret is where the writer left it.
            if shows && !vm.isZenMode { DispatchQueue.main.async { controller.focus() } }
        }
    }

    /// Split in a column too narrow for two readable panes: one pane at a time.
    private func splitTabs(showingPreview: Bool) -> some View {
        HStack(spacing: 8) {
            Picker("Split pane", selection: $splitTabShowsPreview) {
                Text("Source").tag(false)
                Text("Preview").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Split pane")
            Text("Widen to see both")
                .font(OmegaTheme.font(.meta))
                .foregroundColor(theme.secondaryTextColor)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
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
                            .font(OmegaTheme.font(.caption))
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
                .font(OmegaTheme.font(.title, .bold, design: .serif))
                .foregroundColor(theme.titleTextColor)
                .focused($titleFocused)
                .disabled(!paneLayout.showsSource)
                .accessibilityLabel("Entry title")
                .padding(.horizontal, vm.isZenMode ? 20 : 18)
                .padding(.top, vm.isZenMode ? 10 : 18)
                .padding(.bottom, 6)

            MarkdownTextEditor(
                text: $body_,
                font: editorNSFont,
                lineSpacing: CGFloat(WritingFocusLogic.lineSpacing(fontSize: fontSize, lineHeight: lineHeight)),
                isTypewriterMode: isTypewriter,
                isFocusMode: dimOthers,
                columnWidth: columnWidth,
                onSuggestion: { newValue in
                    if newValue != suggestion { suggestionIndex = 0 }
                    suggestion = newValue
                },
                onSuggestionKey: { handleSuggestionKey($0) },
                controller: controller,
                palette: palette,
                onCommandReturn: { vm.stopEditing() },
                onEscape: { handleEscape() },
                onSelectionWords: { selectionWords = $0 },
                onPasteImage: { data, ext in pasteImage(data, ext: ext) },
                isActive: paneLayout.showsSource,
                selectionMemoryKey: entry.id
            )
            .overlay(alignment: .topLeading) {
                if let popover = suggestionPopover { popover }
            }
            .overlay(alignment: .topLeading) {
                if body_.isEmpty {
                    Text("Write something…")
                        .font(Font(editorNSFont))
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
                        .font(OmegaTheme.font(.title, .bold, design: .serif))
                        .foregroundColor(theme.titleTextColor)
                }
                if previewText.isEmpty {
                    Text("Nothing to preview yet.")
                        .font(OmegaTheme.font(.body))
                        .foregroundColor(theme.secondaryTextColor)
                } else {
                    MarkdownBodyView(markdown: previewText, style: renderStyle, textColor: theme.bodyTextColor,
                                     attachments: entry.attachments, db: vm.db,
                                     onResizeImage: { line, width in
                                         if let updated = ImageRefs.resizing(body: body_, lineIndex: line, width: width) { body_ = updated }
                                     })
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
        WritingFooterView(
            wordCount: wordCount, charCount: charCount, selectionWords: selectionWords,
            readingTime: readingTime, attachmentCount: entry.attachments.count,
            sessionStart: sessionStart, sessionStartWords: sessionStartWords,
            ring: goalRing, sprint: sprint, sprintFinished: sprint?.isFinished(at: Date()) ?? false,
            isZen: vm.isZenMode, saveState: vm.saveState,
            onStartSprint: { minutes in
                sprint = WritingSprint(minutes: minutes, startedAt: Date(), startWords: wordCount)
                sprintNotified = false
            },
            onStopSprint: { sprint = nil })
    }

    // MARK: Slash / wiki suggestions

    private var suggestionItems: [SuggestionItem] {
        guard let suggestion else { return [] }
        switch suggestion {
        case .slash(let ctx, _):
            var items = SlashCommands.filter(ctx.query)
                .filter { $0.kind != .template }
                .map { SuggestionItem(id: $0.id, icon: $0.icon, title: $0.title, subtitle: $0.subtitle, action: .command($0.kind)) }
            let q = ctx.query.trimmingCharacters(in: .whitespaces)
            let templates = vm.templates.filter { !$0.body.isEmpty && (q.isEmpty || OmegaCore.fuzzyScore(q, $0.name) != nil) }
            items += templates.prefix(q.isEmpty ? 3 : 6).map {
                SuggestionItem(id: "tpl-" + $0.id, icon: $0.icon, title: $0.name, subtitle: "Insert template", action: .template($0.id))
            }
            return items
        case .wiki(let ctx, _):
            let titles = vm.linkCandidateTitles(excluding: entry.id)
            return MarkdownLogic.wikiTitleSuggestions(query: ctx.query, from: titles, limit: 8)
                .map { SuggestionItem(id: "wiki-" + $0, icon: "link", title: $0, subtitle: "Link to entry", action: .wiki($0)) }
        }
    }

    private var suggestionPopover: AnyView? {
        guard let suggestion else { return nil }
        let items = suggestionItems
        guard !items.isEmpty else { return nil }
        let rect = suggestion.caretRect
        return AnyView(
            SuggestionPopoverView(items: items, selected: min(suggestionIndex, items.count - 1)) { pick($0) }
                .offset(x: max(8, rect.minX), y: rect.maxY + 6)
        )
    }

    private func handleSuggestionKey(_ key: SuggestionKey) -> Bool {
        let items = suggestionItems
        guard !items.isEmpty else { return false }
        switch key {
        case .up: suggestionIndex = (suggestionIndex - 1 + items.count) % items.count; return true
        case .down: suggestionIndex = (suggestionIndex + 1) % items.count; return true
        case .accept: pick(items[min(suggestionIndex, items.count - 1)]); return true
        case .dismiss: return false
        }
    }

    private func pick(_ item: SuggestionItem) {
        guard let current = suggestion else { return }
        suggestion = nil
        let text = controller.text
        switch (current, item.action) {
        case (.slash(let ctx, _), .command(let kind)):
            let lineStart = (text as NSString).lineRange(for: NSRange(location: ctx.range.location, length: 0)).location
            let before = (text as NSString).substring(with: NSRange(location: lineStart, length: ctx.range.location - lineStart))
            let atStart = before.trimmingCharacters(in: .whitespaces).isEmpty
            let tctx = TemplateContext(date: Date(), prompt: "", moodLabel: mood.label)
            guard let exp = SlashCommands.expansion(
                for: kind,
                dateText: TemplateExpander.value(for: "date", context: tctx) ?? "",
                timeText: TemplateExpander.value(for: "time", context: tctx) ?? "",
                moodText: "\(mood.emoji) \(mood.label)", atLineStart: atStart) else { return }
            let edit = MarkdownLogic.slashEdit(context: ctx, expansion: exp)
            controller.apply(edit, selecting: exp.selectionLength, at: edit.range.location + exp.caretOffset)
        case (.slash(let ctx, _), .template(let id)):
            guard let template = vm.templates.first(where: { $0.id == id }) else { return }
            let expanded = TemplateExpander.expand(template.body, context: TemplateContext(
                date: Date(), prompt: PromptGenerator.today(), moodLabel: mood.label))
            let exp = SlashExpansion(text: expanded, caretOffset: (expanded as NSString).length, selectionLength: 0)
            controller.apply(MarkdownLogic.slashEdit(context: ctx, expansion: exp))
            for tag in template.tags where !tags.contains(tag) { tags.append(tag) }
        case (.wiki(let ctx, _), .wiki(let title)):
            controller.apply(MarkdownLogic.wikiCompletionEdit(in: text, context: ctx, title: title))
        default: break
        }
    }

    // MARK: Actions

    private func commitTag() {
        // Commas are the text-column separator; a comma inside a tag name would
        // be misparsed as two tags on the next reconcile. Strip them at input.
        let t = TagPath.normalize(tagInput) ?? ""
        if !t.isEmpty && !tags.contains(t) { tags.append(t) }
        tagInput = ""
    }

    private func persist() {
        var updated = entry
        updated.title = title
        updated.body = EntryStampCodec.join(stamp: stamp, rest: body_)
        updated.mood = mood
        updated.tags = tags
        vm.autoSave(updated)
    }

    /// Pasted images become attachments (there is no inline image storage in the body).
    private func pasteImage(_ data: Data, ext: String) -> Bool {
        guard data.count <= Self.maxAttachmentBytes else {
            vm.showToast("Pasted image is too large to attach (limit \(Self.maxAttachmentBytes / 1_048_576) MB)", isError: true)
            return true
        }
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: "-")
        let mime = ext == "png" ? "image/png" : "image/tiff"
        let name = "Pasted image \(stamp).\(ext)"
        vm.addAttachment(to: entry, data: data, filename: name, mimeType: mime)
        insertImageReference(filename: name)
        return true
    }

    /// Drops a `![](omega-attachment://name)` line at the caret so the image renders inline in the
    /// preview and reader (the attachment itself stays encrypted on disk).
    private func insertImageReference(filename: String) {
        let text = controller.text
        let loc = controller.caretLocation ?? (text as NSString).length
        let atLineStart = loc == 0 || (text as NSString).character(at: min(loc, (text as NSString).length) - 1) == 10
        controller.insert((atLineStart ? "" : "\n") + ImageRefs.markdown(alt: "", filename: filename) + "\n")
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
                    if type.hasPrefix("image/") { insertImageReference(filename: url.lastPathComponent) }
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
