import SwiftUI
import OmegaJournalCore

// MARK: - On-device writing help in the editor
//
// "Suggest title & tags" (popover from the sparkles button, the More menu, the
// Entry menu or the `/suggest` slash command) and "Go deeper" (follow-up
// questions from the footer, the More menu or `/go deeper`). Both appear only
// when On-Device Writing Help is on AND Apple Intelligence is available, and
// never for hidden entries. The editor applies results through its own fields
// (title / tags / body bindings), so autosave works exactly as for typing.

extension Notification.Name {
    /// Entry ▸ Suggest Title & Tags… (menu bar). The open editor handles it.
    static let suggestTitleAndTags = Notification.Name("OmegaJournal.suggestTitleAndTags")
    /// Entry ▸ Go Deeper… (menu bar). The open editor handles it.
    static let goDeeperInEntry = Notification.Name("OmegaJournal.goDeeperInEntry")
}

/// One request to the model for title, tags and summary.
@MainActor
@Observable
final class WritingHelpModel {
    enum Phase: Equatable { case idle, loading, ready(AssistTitleTagSuggestion), failed(String) }

    private(set) var phase: Phase = .idle
    var choice = AssistSuggestionChoice()
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Test seams.
    @ObservationIgnored var model: AssistLanguageModel?
    @ObservationIgnored var availabilityOverride: SmartAssistAvailability?

    init(model: AssistLanguageModel? = nil, availability: SmartAssistAvailability? = nil) {
        self.model = model
        self.availabilityOverride = availability
    }

    func start(body: String, isHidden: Bool, enabled: Bool, currentTitle: String, currentTags: [String]) {
        task?.cancel()
        phase = .loading
        let availability = availabilityOverride ?? SmartAssist.availability
        task = Task { [model] in
            do {
                let s = try await SmartAssist.suggestTitleTags(body: body, isHidden: isHidden, enabled: enabled,
                                                               availability: availability, model: model)
                guard !Task.isCancelled else { return }
                choice = .defaults(for: s, currentTitle: currentTitle, currentTags: currentTags)
                phase = .ready(s)
            } catch SmartAssistError.cancelled {
                return
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed((error as? LocalizedError)?.errorDescription ?? "Writing help couldn't finish. Try again.")
            }
        }
    }

    func waitForCompletion() async { await task?.value }

    func cancel() {
        task?.cancel(); task = nil
        if phase == .loading { phase = .idle }
    }

    func toggleTag(_ tag: String) {
        if choice.acceptedTags.contains(tag) { choice.acceptedTags.remove(tag) } else { choice.acceptedTags.insert(tag) }
    }

    /// The draft with the accepted parts applied, or nil when there's nothing to apply.
    func applied(to draft: AssistDraft) -> AssistDraft? {
        guard case .ready(let s) = phase, !choice.changesNothing else { return nil }
        return AssistApply.apply(s, choice: choice, to: draft)
    }
}

/// One request for "Go deeper" follow-up questions.
@MainActor
@Observable
final class GoDeeperModel {
    enum Phase: Equatable { case idle, loading, ready([String]), failed(String) }

    private(set) var phase: Phase = .idle
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored var model: AssistLanguageModel?
    @ObservationIgnored var availabilityOverride: SmartAssistAvailability?

    init(model: AssistLanguageModel? = nil, availability: SmartAssistAvailability? = nil) {
        self.model = model
        self.availabilityOverride = availability
    }

    func start(body: String, isHidden: Bool, enabled: Bool) {
        task?.cancel()
        phase = .loading
        let availability = availabilityOverride ?? SmartAssist.availability
        task = Task { [model] in
            do {
                let q = try await SmartAssist.followUpQuestions(body: body, isHidden: isHidden, enabled: enabled,
                                                                availability: availability, model: model)
                guard !Task.isCancelled else { return }
                phase = .ready(q)
            } catch SmartAssistError.cancelled {
                return
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed((error as? LocalizedError)?.errorDescription ?? "Writing help couldn't finish. Try again.")
            }
        }
    }

    func waitForCompletion() async { await task?.value }

    func cancel() {
        task?.cancel(); task = nil
        phase = .idle
    }
}

// MARK: - Shared bits

/// "Runs on this Mac" caption + header used by both panels.
private struct AssistHeader: View {
    let title: String
    var onClose: (() -> Void)?
    private let theme = ThemeManager.shared

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles").foregroundColor(theme.accentColor).accessibilityHidden(true)
            Text(title).font(OmegaTheme.font(.caption, .semibold)).foregroundColor(theme.titleTextColor)
            Spacer(minLength: 8)
            Label("On this Mac", systemImage: "lock.fill")
                .labelStyle(.titleAndIcon)
                .font(OmegaTheme.font(.meta))
                .foregroundColor(theme.secondaryTextColor)
                .help("Runs on this Mac with Apple Intelligence. Nothing is sent anywhere.")
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark").font(OmegaTheme.font(.meta, .bold))
                        .foregroundColor(theme.secondaryTextColor)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
        }
    }
}

private struct AssistLoadingRow: View {
    let text: String
    private let theme = ThemeManager.shared
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(OmegaTheme.font(.caption)).foregroundColor(theme.secondaryTextColor)
        }
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Suggest title & tags popover

struct WritingHelpPopover: View {
    @Bindable var model: WritingHelpModel
    let currentTitle: String
    let currentTags: [String]
    var onRetry: () -> Void
    var onApply: () -> Void
    var onClose: () -> Void
    private let theme = ThemeManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AssistHeader(title: "Suggest title & tags")

            switch model.phase {
            case .idle, .loading:
                AssistLoadingRow(text: "Reading your entry…")
            case .failed(let message):
                Text(message)
                    .font(OmegaTheme.font(.caption))
                    .foregroundColor(theme.dangerColor)
                    .fixedSize(horizontal: false, vertical: true)
            case .ready(let s):
                suggestionBody(s)
            }

            HStack(spacing: 8) {
                Spacer()
                switch model.phase {
                case .ready:
                    Button("Cancel") { onClose() }
                        .keyboardShortcut(.cancelAction)
                    Button("Apply") { onApply() }
                        .buttonStyle(.borderedProminent).tint(theme.accentColor)
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.choice.changesNothing)
                        .accessibilityHint("Updates the entry with the items you kept")
                case .failed:
                    Button("Close") { onClose() }
                        .keyboardShortcut(.cancelAction)
                    Button("Try again") { onRetry() }
                        .buttonStyle(.borderedProminent).tint(theme.accentColor)
                        .keyboardShortcut(.defaultAction)
                default:
                    Button("Cancel") { model.cancel(); onClose() }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    @ViewBuilder
    private func suggestionBody(_ s: AssistTitleTagSuggestion) -> some View {
        if let title = s.title {
            VStack(alignment: .leading, spacing: 4) {
                sectionLabel("Title")
                Toggle(isOn: $model.choice.useTitle) {
                    Text(title)
                        .font(OmegaTheme.font(.body, .semibold, design: .serif))
                        .foregroundColor(theme.titleTextColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(.checkbox)
                .accessibilityLabel("Use title: \(title)")
                if !currentTitle.trimmingCharacters(in: .whitespaces).isEmpty && model.choice.useTitle {
                    Text("Replaces “\(currentTitle)”")
                        .font(OmegaTheme.font(.meta))
                        .foregroundColor(theme.secondaryTextColor)
                }
            }
        }

        if !s.tags.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                sectionLabel("Tags")
                FlowLayout(spacing: 6) {
                    ForEach(s.tags, id: \.self) { tag in tagChip(tag) }
                }
                Text("Click a tag to keep or skip it.")
                    .font(OmegaTheme.font(.meta))
                    .foregroundColor(theme.secondaryTextColor)
            }
        }

        if let summary = s.summary {
            VStack(alignment: .leading, spacing: 4) {
                sectionLabel("Summary")
                Text(summary)
                    .font(OmegaTheme.font(.caption).italic())
                    .foregroundColor(theme.bodyTextColor)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Add as a quote at the top of the entry", isOn: $model.choice.insertSummary)
                    .toggleStyle(.checkbox)
                    .font(OmegaTheme.font(.meta))
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(OmegaTheme.font(.meta, .semibold))
            .tracking(0.6)
            .foregroundColor(theme.secondaryTextColor)
            .accessibilityAddTraits(.isHeader)
    }

    private func tagChip(_ tag: String) -> some View {
        let existing = currentTags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
        let accepted = model.choice.acceptedTags.contains(tag)
        return Button { model.toggleTag(tag) } label: {
            HStack(spacing: 3) {
                Image(systemName: existing ? "checkmark.circle" : (accepted ? "checkmark" : "plus"))
                    .font(OmegaTheme.font(.meta, .bold))
                    .accessibilityHidden(true)
                Text("#\(tag)").font(OmegaTheme.font(.meta, .medium))
            }
            .foregroundColor(accepted ? theme.onAccentColor : theme.accentColor)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(accepted ? theme.accentColor : theme.accentColor.opacity(0.08)))
            .overlay(Capsule().strokeBorder(theme.accentColor.opacity(accepted ? 0 : 0.45), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(existing)
        .help(existing ? "Already on this entry" : (accepted ? "Will be added. Click to skip." : "Skipped. Click to add."))
        .accessibilityLabel(existing ? "Tag \(tag), already on this entry" : "Tag \(tag)")
        .accessibilityValue(existing ? "" : (accepted ? "Will be added" : "Skipped"))
        .accessibilityAddTraits(accepted ? .isSelected : [])
    }
}

// MARK: - Go deeper panel

struct GoDeeperPanel: View {
    var model: GoDeeperModel
    var onInsert: (String, AssistFollowUps.InsertStyle) -> Void
    var onRetry: () -> Void
    var onClose: () -> Void
    private let theme = ThemeManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AssistHeader(title: "Go deeper", onClose: { model.cancel(); onClose() })

            switch model.phase {
            case .idle, .loading:
                AssistLoadingRow(text: "Thinking of questions…")
            case .failed(let message):
                Text(message)
                    .font(OmegaTheme.font(.caption))
                    .foregroundColor(theme.dangerColor)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Try again") { onRetry() }
                }
            case .ready(let questions):
                ForEach(Array(questions.enumerated()), id: \.offset) { _, question in
                    questionRow(question)
                }
            }
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: OmegaTheme.Radius.card, style: .continuous).fill(theme.cardColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: OmegaTheme.Radius.card, style: .continuous)
                .strokeBorder(theme.borderColor, lineWidth: 1)
        )
        .omegaElevation(.floating)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Go deeper")
    }

    private func questionRow(_ question: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(question)
                .font(OmegaTheme.font(.body, design: .serif))
                .foregroundColor(theme.titleTextColor)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack(spacing: 6) {
                ForEach(AssistFollowUps.InsertStyle.allCases, id: \.self) { style in
                    Button {
                        onInsert(question, style)
                    } label: {
                        Label(style == .quote ? "Quote" : "Heading",
                              systemImage: style == .quote ? "text.quote" : "number")
                            .font(OmegaTheme.font(.meta, .medium))
                            .foregroundColor(theme.accentColor)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(theme.accentColor.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .help(style.label)
                    .accessibilityLabel("\(style.label): \(question)")
                }
            }
        }
        .padding(.vertical, 4)
    }
}
