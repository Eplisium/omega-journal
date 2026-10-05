import SwiftUI
import OmegaJournalCore

// MARK: - Slash / wiki suggestion popover

struct SuggestionItem: Identifiable, Equatable {
    enum Action: Equatable {
        case command(SlashCommandKind)
        case template(String)     // template id
        case wiki(String)         // entry title
    }
    let id: String
    let icon: String
    let title: String
    let subtitle: String
    let action: Action
}

struct SuggestionPopoverView: View {
    let items: [SuggestionItem]
    let selected: Int
    var onPick: (SuggestionItem) -> Void
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        Button { onPick(item) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: item.icon)
                                    .font(OmegaTheme.font(.caption, .medium))
                                    .foregroundColor(theme.accentColor)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(item.title)
                                        .font(OmegaTheme.font(.caption, .medium))
                                        .foregroundColor(theme.titleTextColor)
                                        .lineLimit(1)
                                    if !item.subtitle.isEmpty {
                                        Text(item.subtitle)
                                            .font(OmegaTheme.font(.meta))
                                            .foregroundColor(theme.secondaryTextColor)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: OmegaTheme.Radius.chip)
                                    .fill(index == selected ? theme.accentColor.opacity(0.2) : .clear)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(item.id)
                        .accessibilityLabel(item.title)
                        .accessibilityAddTraits(index == selected ? .isSelected : [])
                    }
                }
                .padding(6)
            }
            .onChange(of: selected) { _, new in
                if items.indices.contains(new) { proxy.scrollTo(items[new].id) }
            }
        }
        .frame(width: 270, height: min(CGFloat(items.count) * 40 + 12, 250))
        .background(
            RoundedRectangle(cornerRadius: OmegaTheme.Radius.control, style: .continuous)
                .fill(theme.cardColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: OmegaTheme.Radius.control, style: .continuous)
                .strokeBorder(theme.accentColor.opacity(0.35), lineWidth: 1)
        )
        .omegaElevation(.floating)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Suggestions")
    }
}

// MARK: - Focus & typography popover

struct WritingFocusSettingsView: View {
    @AppStorage(ReadingPreferences.editorFontKey) private var fontRaw = EditorFontChoice.system.rawValue
    @AppStorage(ReadingPreferences.editorLineHeightKey) private var lineHeight = WritingFocusLogic.defaultLineHeight
    @AppStorage(ReadingPreferences.editorColumnWidthKey) private var columnWidth = WritingFocusLogic.defaultColumnWidth
    @AppStorage(ReadingPreferences.editorTypewriterKey) private var typewriter = false
    @AppStorage(ReadingPreferences.editorDimParagraphsKey) private var dimOthers = false
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Focus & typography")
                .font(OmegaTheme.font(.caption, .semibold))
                .foregroundColor(theme.titleTextColor)

            Toggle("Typewriter scrolling", isOn: $typewriter)
            Toggle("Dim other paragraphs", isOn: $dimOthers)

            Divider().opacity(0.3)

            Picker("Font", selection: $fontRaw) {
                ForEach(EditorFontChoice.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Line height")
                    Spacer()
                    Text(String(format: "%.2f", WritingFocusLogic.clampedLineHeight(lineHeight)))
                        .foregroundColor(theme.secondaryTextColor)
                }
                Slider(value: $lineHeight, in: WritingFocusLogic.lineHeightRange, step: 0.05)
                    .accessibilityLabel("Line height")
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Column width")
                    Spacer()
                    Text(columnWidth <= 0 ? "Full" : "\(Int(WritingFocusLogic.clampedColumnWidth(columnWidth))) pt")
                        .foregroundColor(theme.secondaryTextColor)
                }
                HStack(spacing: 8) {
                    Slider(value: Binding(
                        get: { columnWidth <= 0 ? WritingFocusLogic.columnWidthRange.upperBound : columnWidth },
                        set: { columnWidth = $0 }
                    ), in: WritingFocusLogic.columnWidthRange, step: 20)
                    .accessibilityLabel("Column width")
                    Button("Full") { columnWidth = 0 }
                        .buttonStyle(.borderless)
                        .disabled(columnWidth <= 0)
                }
            }
        }
        .font(OmegaTheme.font(.caption))
        .foregroundColor(theme.bodyTextColor)
        .padding(14)
        .frame(width: 280)
    }
}

// MARK: - Place & weather stamp popover

struct EntryStampEditor: View {
    @Binding var stamp: EntryStamp
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Place & weather")
                .font(OmegaTheme.font(.caption, .semibold))
                .foregroundColor(theme.titleTextColor)
            Text("Typed by you and stored with this entry only. Nothing is looked up.")
                .font(OmegaTheme.font(.meta))
                .foregroundColor(theme.secondaryTextColor)
            TextField("Place (e.g. Lisbon)", text: $stamp.location)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Place")
            TextField("Weather (e.g. 18°C, sunny)", text: $stamp.weather)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Weather")
            if !stamp.isEmpty {
                Button("Clear") { stamp = EntryStamp() }
                    .buttonStyle(.borderless)
            }
        }
        .padding(14)
        .frame(width: 280)
    }
}

// MARK: - Footer: counts, goal ring, session timer, sprint

struct WritingFooterView: View {
    let wordCount: Int
    let charCount: Int
    let selectionWords: Int
    let readingTime: String
    let attachmentCount: Int
    let sessionStart: Date
    let sessionStartWords: Int
    let ring: GoalRingState
    let sprint: WritingSprint?
    let sprintFinished: Bool
    let isZen: Bool
    let saveState: JournalViewModel.SaveState
    var onStartSprint: (Int) -> Void
    var onStopSprint: () -> Void

    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        HStack(spacing: 12) {
            Label("\(wordCount) words", systemImage: "text.word.spacing")
            if selectionWords > 0 { Text("(\(selectionWords) selected)") }
            if !isZen {
                Text("·")
                Text("\(charCount) chars")
                Text("·")
                Text(readingTime)
                if attachmentCount > 0 {
                    Text("·")
                    Label("\(attachmentCount)", systemImage: "paperclip")
                }
            }
            Spacer()

            if ring.target > 0 { goalRing }

            TimelineView(.periodic(from: .now, by: 1)) { context in
                sessionLabel(now: context.date)
            }

            sprintMenu

            if isZen {
                Text("⎋ exit zen").foregroundColor(theme.secondaryTextColor.opacity(0.7))
            } else {
                Text(saveState == .pending ? "Saving…" : "Saved")
                    .foregroundColor(theme.secondaryTextColor.opacity(0.7))
                    .accessibilityLabel(saveState == .pending ? "Saving" : "All changes saved")
            }
        }
        .font(OmegaTheme.font(.meta))
        .foregroundColor(theme.secondaryTextColor)
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(theme.cardColor.opacity(0.3))
    }

    private var goalRing: some View {
        HStack(spacing: 5) {
            ZStack {
                Circle().stroke(theme.accentColor.opacity(0.2), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: ring.fraction)
                    .stroke(theme.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                if ring.isComplete {
                    Image(systemName: "checkmark").font(OmegaTheme.font(.meta, .bold)).foregroundColor(theme.accentColor)
                        .scaleEffect(0.55)
                }
            }
            .frame(width: 16, height: 16)
            Text("\(ring.current)/\(ring.target)")
        }
        .omegaTooltip("Daily word goal")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Daily goal: \(ring.current) of \(ring.target) words")
    }

    private func sessionLabel(now: Date) -> some View {
        let elapsed = now.timeIntervalSince(sessionStart)
        let words = WritingSessionMath.wordsWritten(start: sessionStartWords, current: wordCount)
        let wpm = WritingSessionMath.wordsPerMinute(words: words, elapsed: elapsed)
        return HStack(spacing: 5) {
            Image(systemName: "timer")
            Text(WritingSessionMath.clock(elapsed)).monospacedDigit()
            if words > 0 { Text("· +\(words)") }
            if wpm > 0 { Text("· \(wpm) wpm") }
        }
        .omegaTooltip("Session time and words written")
        .accessibilityLabel("Session \(WritingSessionMath.clock(elapsed)), \(words) words written")
    }

    @ViewBuilder
    private var sprintMenu: some View {
        if let sprint {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let done = sprint.isFinished(at: context.date)
                Button { onStopSprint() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: done ? "flag.checkered" : "bolt.fill")
                        Text(done
                             ? "Sprint done · +\(sprint.wordsWritten(currentWords: wordCount)) words"
                             : "\(WritingSessionMath.clock(sprint.remaining(at: context.date))) · +\(sprint.wordsWritten(currentWords: wordCount))")
                            .monospacedDigit()
                    }
                    .foregroundColor(theme.accentColor)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(theme.accentColor.opacity(0.14)))
                }
                .buttonStyle(.plain)
                .omegaTooltip(done ? "Dismiss sprint" : "Stop sprint")
                .accessibilityLabel(done ? "Sprint finished. Dismiss" : "Writing sprint running. Stop")
            }
        } else {
            Menu {
                ForEach(WritingSprint.allowedMinutes, id: \.self) { m in
                    Button("Start \(m)-minute sprint") { onStartSprint(m) }
                }
            } label: {
                Image(systemName: "bolt")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Writing sprint")
            .accessibilityLabel("Start writing sprint")
        }
    }
}
