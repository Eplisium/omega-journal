import SwiftUI
import OmegaJournalCore

// MARK: - Ask your journal (on-device)
//
// A question box over the writer's own entries. Retrieval is local and pure
// (`AskJournalRetrieval` in Core): only the top few excerpts are handed to
// Apple's on-device model, and the answer lists its sources as entry titles
// that open the entry. Hidden entries are never included while locked; an
// answer that used a hidden entry is cleared the moment hidden entries lock.

extension Notification.Name {
    /// Opens the Ask Your Journal panel (menu bar ⇧⌘A, command palette).
    static let showAskJournal = Notification.Name("OmegaJournal.showAskJournal")
}

@MainActor
@Observable
final class AskJournalModel {
    enum Phase: Equatable {
        case idle
        case answering
        case answered(answer: String, sources: [AskJournalSource])
        case noMatches
        case failed(String)
    }

    var question = ""
    private(set) var phase: Phase = .idle
    /// Entry ids behind the current answer that are hidden (cleared on lock).
    @ObservationIgnored private(set) var hiddenSourceIds: Set<String> = []
    @ObservationIgnored private var task: Task<Void, Never>?

    // Seams (tests inject fakes; the app uses the real model and lock state).
    @ObservationIgnored var model: AssistLanguageModel?
    @ObservationIgnored var availabilityOverride: SmartAssistAvailability?
    @ObservationIgnored var isHiddenLocked: () -> Bool

    init(model: AssistLanguageModel? = nil, availability: SmartAssistAvailability? = nil,
         isHiddenLocked: (() -> Bool)? = nil) {
        self.model = model
        self.availabilityOverride = availability
        self.isHiddenLocked = isHiddenLocked ?? { !BiometricAuth.shared.isAuthenticated }
    }

    var canAsk: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && phase != .answering
    }

    /// Ranks `records` locally, then asks the on-device model about the top excerpts only.
    func ask(records: [SearchQuery.Record], enabled: Bool, now: Date = Date()) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        task?.cancel()
        let locked = isHiddenLocked()
        let sources = AskJournalRetrieval.rank(question: q, records: records, hiddenLocked: locked, now: now)
        guard !sources.isEmpty else { phase = .noMatches; hiddenSourceIds = []; return }
        let hiddenIds = Set(records.filter(\.isHidden).map(\.id))
        hiddenSourceIds = Set(sources.map(\.entryId)).intersection(hiddenIds)
        phase = .answering
        let availability = availabilityOverride ?? SmartAssist.availability
        task = Task { [model] in
            do {
                let answer = try await SmartAssist.answer(question: q, sources: sources, enabled: enabled,
                                                          availability: availability, model: model)
                guard !Task.isCancelled else { return }
                // Hidden entries locked while the model was thinking: drop the answer.
                if !hiddenSourceIds.isEmpty && isHiddenLocked() { reset(); return }
                phase = .answered(answer: answer, sources: AskJournalCitations.sourcesToShow(answer: answer, sources: sources))
            } catch SmartAssistError.cancelled {
                return
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed((error as? LocalizedError)?.errorDescription ?? "Couldn't answer that. Try again.")
            }
        }
    }

    func waitForCompletion() async { await task?.value }

    /// Hidden entries just locked: anything drawn from them disappears.
    func hiddenEntriesLocked() {
        guard !hiddenSourceIds.isEmpty else { return }
        reset()
    }

    func cancel() {
        task?.cancel(); task = nil
        if phase == .answering { phase = .idle }
    }

    func reset() {
        task?.cancel(); task = nil
        hiddenSourceIds = []
        phase = .idle
    }
}

/// Every journal entry the panel may consider (active + archived, de-duplicated).
/// Locked hidden entries are dropped again by `AskJournalRetrieval`.
@MainActor
enum AskJournalCorpus {
    static func records(from vm: JournalViewModel) -> [SearchQuery.Record] {
        var seen = Set<String>()
        var out: [SearchQuery.Record] = []
        for entry in vm.entries + vm.archivedEntries where !entry.isTrashed && seen.insert(entry.id).inserted {
            out.append(entry.searchRecord)
        }
        return out
    }
}

struct AskJournalView: View {
    var vm: JournalViewModel
    /// Opens an entry from a citation (the presenter selects it and closes the panel).
    var onOpenEntry: (String) -> Void
    var onClose: () -> Void

    @State private var model = AskJournalModel()
    @State private var enabled = SmartAssist.isEnabled()
    @FocusState private var questionFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let theme = ThemeManager.shared
    private let availability = SmartAssist.availability

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if !availability.isAvailable {
                unavailableNotice
            } else if !enabled {
                disabledNotice
            } else {
                questionField
                ScrollView { result.frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(minHeight: 180)
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Done") { onClose() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 520)
        .background(theme.backgroundColor)
        .onAppear { questionFocused = true }
        .onDisappear { model.reset() }
        .onChange(of: BiometricAuth.shared.isAuthenticated) { _, unlocked in
            if !unlocked { model.hiddenEntriesLocked() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .smartAssistSettingChanged)) { _ in
            enabled = SmartAssist.isEnabled()
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: model.phase)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundColor(theme.accentColor).accessibilityHidden(true)
                Text("Ask your journal")
                    .font(OmegaTheme.serifTitleFont)
                    .foregroundColor(theme.titleTextColor)
                    .accessibilityAddTraits(.isHeader)
            }
            Label("Runs on this Mac. Hidden entries are never included while locked.", systemImage: "lock.fill")
                .font(OmegaTheme.font(.meta))
                .foregroundColor(theme.secondaryTextColor)
        }
    }

    private var questionField: some View {
        HStack(spacing: 8) {
            TextField("Ask about your entries, like “When did I last feel rested?”", text: $model.question)
                .textFieldStyle(.roundedBorder)
                .font(OmegaTheme.font(.body))
                .focused($questionFocused)
                .onSubmit(ask)
                .accessibilityLabel("Question")
            Button("Ask", action: ask)
                .buttonStyle(.borderedProminent).tint(theme.accentColor)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canAsk)
        }
    }

    private func ask() {
        guard model.canAsk else { return }
        model.ask(records: AskJournalCorpus.records(from: vm), enabled: SmartAssist.isEnabled())
    }

    @ViewBuilder
    private var result: some View {
        switch model.phase {
        case .idle:
            Text("Answers come only from your own entries, with links to the entries they used.")
                .font(OmegaTheme.font(.caption))
                .foregroundColor(theme.secondaryTextColor)
        case .answering:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Looking through your entries…").font(OmegaTheme.font(.caption)).foregroundColor(theme.secondaryTextColor)
                Spacer()
                Button("Stop") { model.cancel() }
            }
            .accessibilityElement(children: .contain)
        case .noMatches:
            Text("Nothing in your journal seems to match. Try different words.")
                .font(OmegaTheme.font(.caption))
                .foregroundColor(theme.secondaryTextColor)
        case .failed(let message):
            Text(message)
                .font(OmegaTheme.font(.caption))
                .foregroundColor(theme.dangerColor)
                .fixedSize(horizontal: false, vertical: true)
        case .answered(let answer, let sources):
            VStack(alignment: .leading, spacing: 14) {
                Text(answer)
                    .font(OmegaTheme.font(.body))
                    .foregroundColor(theme.bodyTextColor)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Answer: \(answer)")
                VStack(alignment: .leading, spacing: 6) {
                    Text("SOURCES")
                        .font(OmegaTheme.font(.meta, .semibold)).tracking(0.6)
                        .foregroundColor(theme.secondaryTextColor)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(sources) { source in sourceRow(source) }
                }
            }
        }
    }

    private func sourceRow(_ source: AskJournalSource) -> some View {
        Button { onOpenEntry(source.entryId) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(source.number)")
                    .font(OmegaTheme.font(.meta, .bold)).monospacedDigit()
                    .foregroundColor(theme.accentColor)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(theme.accentColor.opacity(0.14)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.title)
                        .font(OmegaTheme.font(.caption, .semibold))
                        .foregroundColor(theme.accentColor)
                        .underline()
                    Text(source.createdAt.formatted(date: .abbreviated, time: .omitted))
                        .font(OmegaTheme.font(.meta))
                        .foregroundColor(theme.secondaryTextColor)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right").font(OmegaTheme.font(.meta)).foregroundColor(theme.secondaryTextColor)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 6).padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: OmegaTheme.Radius.control).fill(theme.cardColor.opacity(0.5)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open this entry")
        .accessibilityLabel("Source \(source.number): \(source.title), \(source.createdAt.formatted(date: .long, time: .omitted)). Open entry")
    }

    private var unavailableNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ask your journal needs Apple Intelligence")
                .font(OmegaTheme.font(.body, .semibold)).foregroundColor(theme.titleTextColor)
            if case .unavailable(let why) = availability {
                Text(why).font(OmegaTheme.font(.caption)).foregroundColor(theme.secondaryTextColor)
            }
            Text("It works entirely on your Mac with Apple's on-device model, so it's only offered where that model can run. Everything else in Omega Journal works as usual.")
                .font(OmegaTheme.font(.caption)).foregroundColor(theme.secondaryTextColor)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: OmegaTheme.Radius.card).fill(theme.cardColor.opacity(0.5)))
    }

    private var disabledNotice: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("On-device writing help is off")
                .font(OmegaTheme.font(.body, .semibold)).foregroundColor(theme.titleTextColor)
            Text("Ask your journal uses Apple's on-device model to read a few of your entries and answer. Nothing leaves this Mac, and hidden entries are never included while locked.")
                .font(OmegaTheme.font(.caption)).foregroundColor(theme.secondaryTextColor)
                .fixedSize(horizontal: false, vertical: true)
            Button("Turn On On-Device Writing Help") {
                SmartAssist.setEnabled(true)
                enabled = true
            }
            .buttonStyle(.borderedProminent).tint(theme.accentColor)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: OmegaTheme.Radius.card).fill(theme.cardColor.opacity(0.5)))
    }
}

/// Presents Ask Your Journal as a sheet when `.showAskJournal` is posted and
/// opens cited entries in the Journal (or Archive). Attach once at the window
/// root: `.modifier(AskJournalPresenter(vm: vm, selection: $sidebarSelection))`.
struct AskJournalPresenter: ViewModifier {
    var vm: JournalViewModel
    @Binding var selection: SidebarItem?
    @State private var isPresented = false

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .showAskJournal)) { _ in isPresented = true }
            // The whole-app lock covers the window, not sheets: close the panel when it engages.
            .onChange(of: AppLockManager.shared.isLocked) { _, locked in if locked { isPresented = false } }
            .sheet(isPresented: $isPresented) {
                AskJournalView(vm: vm, onOpenEntry: { open($0) }, onClose: { isPresented = false })
            }
    }

    private func open(_ id: String) {
        guard let entry = vm.entry(id: id) else { return }
        if vm.isEditing { vm.stopEditing() }
        selection = Self.destination(for: entry)
        vm.select(entry)
        isPresented = false
    }

    /// Where a cited entry lives in the sidebar.
    static func destination(for entry: JournalEntry) -> SidebarItem {
        entry.isArchived ? .archive : .all
    }
}
