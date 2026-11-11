import SwiftUI
import AppKit
import UniformTypeIdentifiers
import OmegaJournalCore

// MARK: - Editor

struct EditorView: View {
    @Bindable var vm: JournalViewModel
    let entry: JournalEntry

    private let theme = ThemeManager.shared
    @State private var controller = MarkdownEditorController()

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
    @State private var showContext = false

    // On-device writing help: shown only when switched on AND Apple Intelligence is
    // available, never for hidden entries (re-checked on every request).
    @State private var assistOffered = false
    @State private var writingHelp = WritingHelpModel()
    @State private var showWritingHelp = false
    @State private var goDeeper = GoDeeperModel()
    @State private var showGoDeeper = false
    /// The voice memo being transcribed (sheet).
    @State private var transcribing: Attachment?

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
        // A tag rename/delete elsewhere rewrites this editor's tag list the
        // same way, so the next keystroke can't save the old tag back.
        .onChange(of: vm.tagRewriteGeneration) { _, _ in
            guard let rewrite = vm.lastTagRewrite else { return }
            let rewritten = rewrite.apply(to: tags)
            if rewritten != tags { tags = rewritten }
        }
        .onChange(of: stamp) { _, _ in persist() }
        .onChange(of: fontSize) { _, new in
            vm.editorFontSize = new
        }
        .onDisappear {
            writingHelp.cancel()
            goDeeper.cancel()
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
            // Menu shortcuts only format the body when it (or nothing text-like) has focus.
            if let cmd = note.object as? MarkdownCommand { controller.applyMenuCommand(cmd) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .smartAssistSettingChanged)) { _ in refreshAssistOffer() }
        // Hiding the entry while it's open withdraws writing help at once.
        .onChange(of: liveEntry.isHidden) { _, _ in refreshAssistOffer() }
        .onReceive(NotificationCenter.default.publisher(for: .suggestTitleAndTags)) { _ in openWritingHelp() }
        .onReceive(NotificationCenter.default.publisher(for: .goDeeperInEntry)) { _ in openGoDeeper() }
        .sheet(item: $transcribing) { memo in
            MemoTranscriptPanel(attachment: memo, db: vm.db, onInsert: { insertTranscript($0) },
                                onClose: { transcribing = nil })
        }
        .onAppear {
            refreshAssistOffer()
            if title.isEmpty { titleFocused = true }
            loadGoalBaseline()
            // Entries from before version history existed get a kept baseline so the first edit is undoable.
            if vm.db.revisionCount(entryId: entry.id) == 0 {
                vm.db.snapshotRevision(of: entry, isAuto: false)
            }
        }
    }

    // MARK: Goal ring

    private var entryCountsTowardToday: Bool { Self.countsTowardToday(createdAt: entry.createdAt) }

    /// The daily goal counts entries dated today — not earlier days and not
    /// future-dated ones (same `[startOfToday, endOfToday)` window as
    /// `wordCountSum`), so a planned entry open in the editor never moves the ring.
    static func countsTowardToday(createdAt: Date, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        createdAt >= calendar.startOfDay(for: now)
            && createdAt < DatabaseManager.endOfToday(now: now, calendar: calendar)
    }

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
            topBarRow(Self.topBarVariants[0])
            topBarRow(Self.topBarVariants[1])
            topBarRow(Self.topBarVariants[2])
            topBarRow(Self.topBarVariants[3])
        }
        .padding(.horizontal, 14)
        .padding(.vertical, GlassSupport.usesGlass(.toolbarControl) ? 7 : 9)
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
        .sheet(isPresented: $showContext) {
            ContextSheet(service: .shared) { transform, photos in
                applyContext(transform)
                for p in photos {
                    insertImageReference(for: vm.addAttachment(to: entry, data: p.data, filename: p.filename, mimeType: p.mimeType))
                }
            }
        }
        // Automatic context for a brand-new, still-empty entry — only when
        // the user turned that on (and the sources) in Settings › Writing.
        .task(id: entry.id) { await addAutomaticContextIfWanted() }
    }

    /// Top bar layouts from widest to narrowest. The last one folds Focus and
    /// Attach into the More menu, so the bar fits the narrowest detail column
    /// (414pt) even with the writing-help button, and never clips.
    struct TopBarVariant: Hashable {
        let compactMood: Bool, iconModes: Bool, compactTools: Bool
    }

    static let topBarVariants: [TopBarVariant] = [
        TopBarVariant(compactMood: false, iconModes: false, compactTools: false),
        TopBarVariant(compactMood: true, iconModes: false, compactTools: false),
        TopBarVariant(compactMood: true, iconModes: true, compactTools: false),
        TopBarVariant(compactMood: true, iconModes: true, compactTools: true),
    ]

    private func topBarRow(_ variant: TopBarVariant) -> some View {
        topBarRow(compactMood: variant.compactMood, iconModes: variant.iconModes, compactTools: variant.compactTools)
    }

    private func topBarRow(compactMood: Bool, iconModes: Bool, compactTools: Bool) -> some View {
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
            .ojGlassButtonStyle(prominent: false)
            .layoutPriority(2)
            .accessibilityLabel("Done editing")
            .help("Done (⌘↩)")

            if !GlassSupport.usesGlass(.toolbarControl) { Divider().frame(height: 16).opacity(0.25) }

            Group { if compactMood { moodMenu } else { moodRow } }
                .ojGlassCluster(horizontal: compactMood ? 10 : 4, vertical: compactMood ? 7 : 4)

            Spacer(minLength: 4)

            modePicker(iconOnly: iconModes)

            HStack(spacing: 4) {
            if assistOffered {
                ActionButton(icon: "sparkles", color: theme.accentColor, active: showWritingHelp, tooltip: "Suggest title & tags (on this Mac)") {
                    openWritingHelp()
                }
                .accessibilityLabel("Suggest title and tags")
            }

            if !compactTools {
                ActionButton(icon: "text.alignleft", color: theme.accentColor, active: isTypewriter || dimOthers || columnWidth > 0, tooltip: "Focus & typography") {
                    showFocusPopover.toggle()
                }
                .accessibilityLabel("Focus and typography")

                ActionButton(icon: "paperclip", color: theme.accentColor, active: !currentAttachments.isEmpty, tooltip: "Attach file") {
                    attachFile()
                }
                .accessibilityLabel(currentAttachments.isEmpty ? "Attach file" : "Attach file, \(currentAttachments.count) attached")

                ActionButton(icon: "location.viewfinder", color: theme.accentColor, active: false, tooltip: "Add context") {
                    showContext = true
                }
                .accessibilityLabel("Add context")
            }

            moreMenu(includesPrimaryTools: compactTools)
            }
            .ojGlassCluster()
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
        // Match the height of the glass controls beside it on macOS 26.
        .controlSize(GlassSupport.usesGlass(.toolbarControl) ? .large : .regular)
        .fixedSize()
        .omegaTooltip("Write, split view, or preview")
        .accessibilityLabel("Editor mode")
    }

    /// Less frequent tools share one menu: place/weather, voice memo, history,
    /// text size, find & replace and Zen. Their keyboard shortcuts still work
    /// (hidden buttons + app menus) and are shown here.
    private func moreMenu(includesPrimaryTools: Bool) -> some View {
        Menu {
            if includesPrimaryTools {
                Button { showFocusPopover = true } label: {
                    Label("Focus & Typography…", systemImage: "text.alignleft")
                }
                Button { attachFile() } label: {
                    Label(currentAttachments.isEmpty ? "Attach File…" : "Attach File… (\(currentAttachments.count) attached)",
                          systemImage: "paperclip")
                }
                Button { showContext = true } label: {
                    Label("Add Context…", systemImage: "location.viewfinder")
                }
                Divider()
            }
            if assistOffered {
                Button { openWritingHelp() } label: {
                    Label("Suggest Title & Tags…", systemImage: "sparkles")
                }
                Button { openGoDeeper() } label: {
                    Label("Go Deeper…", systemImage: "text.bubble")
                }
                .disabled(body_.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Divider()
            }
            Button { showStampPopover = true } label: {
                Label(stamp.isEmpty ? "Add Place & Weather…" : "Edit Place & Weather…", systemImage: "mappin.and.ellipse")
            }
            Button { showRecorder = true } label: {
                Label("Record Voice Memo…", systemImage: "mic")
            }
            transcribeMenu
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

    /// Voice memos on this entry, newest first.
    private var currentAttachments: [Attachment] { entry.attachments }

    /// "Transcribe Voice Memo" (one memo) or a submenu (several). Hidden when
    /// on-device transcription isn't available or there's no memo.
    @ViewBuilder
    private var transcribeMenu: some View {
        let memos = currentAttachments.filter(\.isAudio).sorted { $0.createdAt > $1.createdAt }
        if !memos.isEmpty && MemoTranscription.availability.isAvailable {
            if memos.count == 1, let memo = memos.first {
                Button { transcribing = memo } label: {
                    Label("Transcribe Voice Memo…", systemImage: "text.bubble")
                }
            } else {
                Menu {
                    ForEach(memos) { memo in
                        Button(memo.createdAt.formatted(date: .abbreviated, time: .shortened)) { transcribing = memo }
                    }
                } label: {
                    Label("Transcribe Voice Memo", systemImage: "text.bubble")
                }
            }
        }
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
        // Writing help hangs off the top-trailing corner of the page (present in
        // Zen mode too, where the toolbar is hidden).
        .overlay(alignment: .topTrailing) {
            Color.clear.frame(width: 1, height: 1)
                .padding(.trailing, 28)
                .popover(isPresented: $showWritingHelp, arrowEdge: .top) {
                    WritingHelpPopover(model: writingHelp, currentTitle: title, currentTags: tags,
                                       onRetry: { startWritingHelp() },
                                       onApply: { applyWritingHelp() },
                                       onClose: { showWritingHelp = false })
                }
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
        .onChange(of: showWritingHelp) { _, shown in if !shown { writingHelp.cancel() } }
        .overlay(alignment: .bottomTrailing) {
            if showGoDeeper {
                GoDeeperPanel(model: goDeeper,
                              onInsert: { question, style in insertFollowUp(question, style: style) },
                              onRetry: { startGoDeeper() },
                              onClose: { closeGoDeeper() })
                    .padding(16)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: showGoDeeper)
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
            onStopSprint: { sprint = nil },
            onRetrySave: { vm.retryFailedSaves() },
            onGoDeeper: offersGoDeeper ? { openGoDeeper() } : nil)
    }

    // MARK: Slash / wiki suggestions

    private var suggestionItems: [SuggestionItem] {
        guard let suggestion else { return [] }
        switch suggestion {
        case .slash(let ctx, _):
            var items = SlashCommands.filter(ctx.query, in: SlashCommands.visible(assistOffered: assistOffered))
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
        case (.slash(let ctx, _), .command(let kind)) where kind.isAssist:
            // Writing help: remove the "/query" token, then open the panel.
            controller.apply(MarkdownLogic.slashEdit(context: ctx, expansion: SlashExpansion(text: "", caretOffset: 0)))
            DispatchQueue.main.async {
                if kind == .suggestTitleTags { openWritingHelp() } else { openGoDeeper() }
            }
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

    // MARK: Writing help

    private var liveEntry: JournalEntry { vm.entry(id: entry.id) ?? entry }

    private var offersGoDeeper: Bool {
        assistOffered && wordCount >= AssistEntryPoint.goDeeperMinimumWords
    }

    private func refreshAssistOffer() {
        let offered = SmartAssist.isOffered(for: liveEntry, db: vm.db)
        if offered != assistOffered { assistOffered = offered }
        if !offered {
            showWritingHelp = false
            closeGoDeeper()
        }
    }

    private func openWritingHelp() {
        refreshAssistOffer()
        guard assistOffered else { return }
        startWritingHelp()
        showWritingHelp = true
    }

    private func startWritingHelp() {
        writingHelp.start(body: body_, isHidden: liveEntry.isHidden, enabled: SmartAssist.isEnabled(vm.db),
                          currentTitle: title, currentTags: tags)
    }

    /// Applies the kept parts through the editor's own fields: title and tags
    /// via their state (autosave picks them up like typing), the summary as an
    /// undoable edit at the top of the body.
    private func applyWritingHelp() {
        defer { showWritingHelp = false }
        guard let out = writingHelp.applied(to: AssistDraft(title: title, body: body_, tags: tags)) else { return }
        if out.title != title { title = out.title }
        if out.tags != tags { tags = out.tags }
        if out.body != body_ {
            let prefix = out.body.hasSuffix(body_) ? String(out.body.dropLast(body_.count)) : ""
            if !prefix.isEmpty, controller.text == body_ {
                let caret = (controller.caretLocation ?? 0) + (prefix as NSString).length
                controller.apply(CompletionEdit(range: NSRange(location: 0, length: 0), replacement: prefix, caret: caret))
            } else {
                body_ = out.body
            }
        }
        vm.showToast("Writing help applied")
    }

    private func openGoDeeper() {
        refreshAssistOffer()
        guard assistOffered else { return }
        startGoDeeper()
        showGoDeeper = true
    }

    private func startGoDeeper() {
        goDeeper.start(body: body_, isHidden: liveEntry.isHidden, enabled: SmartAssist.isEnabled(vm.db))
    }

    private func closeGoDeeper() {
        goDeeper.cancel()
        showGoDeeper = false
    }

    private func insertFollowUp(_ question: String, style: AssistFollowUps.InsertStyle) {
        insertBlock { atLineStart in AssistFollowUps.insertion(question, style: style, atLineStart: atLineStart) }
        closeGoDeeper()
    }

    private func insertTranscript(_ transcript: String) {
        insertBlock { atLineStart in TranscriptText.block(transcript, atLineStart: atLineStart) }
        vm.showToast("Transcript added to the entry")
    }

    /// Inserts block text at the caret (end of the entry when there's no caret).
    private func insertBlock(_ make: (Bool) -> String) {
        let text = controller.text
        let ns = text as NSString
        guard text == body_ else {
            // No live text view (e.g. not laid out yet): append through the binding.
            let block = make(body_.isEmpty || body_.hasSuffix("\n"))
            body_ += block
            return
        }
        let loc = min(controller.caretLocation ?? ns.length, ns.length)
        let atLineStart = loc == 0 || ns.character(at: loc - 1) == 10
        controller.insert(make(atLineStart))
        controller.focus()
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

    /// Runs a context transform (place stamp, today's events) over the full
    /// body — text plus stamp — and splits the result back into the editor's
    /// separate body and stamp state.
    private func applyContext(_ transform: (String) -> String) {
        let parts = EntryStampCodec.split(transform(EntryStampCodec.join(stamp: stamp, rest: body_)))
        body_ = parts.rest
        stamp = parts.stamp ?? EntryStamp()
    }

    private func addAutomaticContextIfWanted() async {
        let service = ContextService.shared
        guard vm.newDraftId == entry.id, body_.isEmpty, stamp.isEmpty,
              service.autoOnNewEntry, !service.enabled.isEmpty else { return }
        let snap = await service.gather(.newEntry)
        guard !Task.isCancelled, !snap.isEmpty, vm.editingEntryId == entry.id else { return }
        applyContext { ContextService.apply(snap, to: $0) }
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
        insertImageReference(for: vm.addAttachment(to: entry, data: data, filename: name, mimeType: mime))
        return true
    }

    /// The inline reference for a just-saved attachment: images only, keyed by
    /// the STORED filename (sanitized and unique per entry — the name the
    /// preview/reader resolve), and nothing when the save failed.
    static func inlineImageMarkdown(for saved: Attachment?) -> String? {
        guard let saved, saved.isImage else { return nil }
        return ImageRefs.markdown(alt: "", filename: saved.filename)
    }

    /// Drops a `![](omega-attachment://name)` line at the caret so the image renders inline in the
    /// preview and reader (the attachment itself stays encrypted on disk).
    private func insertImageReference(for saved: Attachment?) {
        guard let reference = Self.inlineImageMarkdown(for: saved) else { return }
        let text = controller.text
        let loc = controller.caretLocation ?? (text as NSString).length
        let atLineStart = loc == 0 || (text as NSString).character(at: min(loc, (text as NSString).length) - 1) == 10
        controller.insert((atLineStart ? "" : "\n") + reference + "\n")
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
                    insertImageReference(for: vm.addAttachment(to: target, data: data, filename: url.lastPathComponent, mimeType: type))
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
