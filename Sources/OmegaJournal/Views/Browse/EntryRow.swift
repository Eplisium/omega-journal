import SwiftUI
import AppKit
import OmegaJournalCore

// MARK: - List density

enum ListDensity: String, CaseIterable, Identifiable {
    case compact, comfortable, cards
    static let storageKey = "list.density"
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var icon: String {
        switch self {
        case .compact: "list.bullet"
        case .comfortable: "list.dash"
        case .cards: "rectangle.grid.1x2"
        }
    }
}

// MARK: - Entry Row

struct EntryRow: View {
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @ObservedObject var vm: JournalViewModel
    let entry: JournalEntry
    let isTrash: Bool

    // Selection state is read straight from the view model instead of being
    // passed in as values. Rows live inside a LazyVStack, where stale passed-in
    // copies can survive a parent re-render — the reported symptom was the bulk
    // toolbar active while rows still rendered (and tapped) as if it were off.
    // @ObservedObject re-renders the row on every publish, so these stay live.
    var isSelected: Bool { vm.selectedEntryId == entry.id }
    var isBulkSelected: Bool { vm.bulkSelection.contains(entry.id) }
    var isBulkSelecting: Bool { vm.isBulkSelecting }

    @ObservedObject var theme = ThemeManager.shared
    @ObservedObject var biometricAuth = BiometricAuth.shared
    @State var hover = false
    @State var showPermanentDeleteConfirmation = false

    @AppStorage(ListDensity.storageKey) var densityRaw = ListDensity.comfortable.rawValue
    var density: ListDensity { ListDensity(rawValue: densityRaw) ?? .comfortable }

    /// Body-derived UI (preview, thumbnail, snippet, tags) is only built when this is true.
    var canShowContent: Bool { ContentMasking.canShowContent(isHidden: entry.isHidden, hiddenLocked: !biometricAuth.isAuthenticated) }

    var body: some View {
        HStack(spacing: 0) {
            // Mood color rail.
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(entry.mood.color.opacity(isContentLocked ? 0.35 : 0.9))
                .frame(width: 3)
                .padding(.vertical, density == .compact ? 3 : 2)
                .accessibilityHidden(true)

            HStack(spacing: 9) {
                if isBulkSelecting {
                    Image(systemName: isBulkSelected ? "checkmark.circle.fill" : "circle")
                        .font(OmegaTheme.font(.bodyLarge))
                        .foregroundColor(isBulkSelected ? theme.accentColor : theme.secondaryTextColor.opacity(0.5))
                }

                VStack(alignment: .leading, spacing: density == .compact ? 1 : 3) {
                    titleLine
                    if density != .compact { previewLines }
                    if density != .compact || hover { metaLine }
                }

                if density != .compact, !isContentLocked, let thumb = thumbnail {
                    Image(nsImage: thumb)
                        .resizable().aspectRatio(contentMode: .fill)
                        .frame(width: density == .cards ? 64 : 44, height: density == .cards ? 64 : 44)
                        .clipShape(RoundedRectangle(cornerRadius: OmegaTheme.Radius.chip, style: .continuous))
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, density == .compact ? 4 : (density == .cards ? 12 : 8))
        }
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(rowBackground)
        )
        .overlay(alignment: .topTrailing) {
            if hover && !isBulkSelecting && !isTrash { quickActions.padding(6).transition(.opacity) }
        }
        .hoverGlow(radius: 11, glow: density == .cards ? 0.2 : 0.12, border: 0.3, lift: false)
        .opacity(isContentLocked ? 0.82 : 1)
        .contentShape(Rectangle())
        .draggable(EntryDragPayload.encode(vm.dragIDs(for: entry))) {
            Text(isContentLocked ? "Hidden entry" : entry.displayTitle)
                .font(OmegaTheme.font(.caption)).padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.cardColor))
        }
        .overlay(
            // Visible selection edge (not just a faint fill) so keyboard
            // navigation with ↑/↓ shows where the cursor is.
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(rowBorder, lineWidth: isSelected ? 1.5 : 1)
                .accessibilityHidden(true)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected || isBulkSelected ? .isSelected : [])
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(A11yDescriptions.entryRowValue(isSelected: isSelected, isBulkSelecting: isBulkSelecting, isBulkSelected: isBulkSelected))
        .accessibilityHint(A11yDescriptions.entryRowHint(isBulkSelecting: isBulkSelecting, isTrash: isTrash))
        .accessibilityAction {
            if isBulkSelecting { vm.toggleBulkSelection(entry.id) } else { vm.select(entry) }
        }
        .modifier(EntryRowAccessibilityActions(actions: isBulkSelecting ? [] : A11yEntryRowAction.available(isTrash: isTrash),
                                               entry: entry, perform: perform))
        .onHover { hover = $0 }
        .onTapGesture(count: 2) {
            if !isTrash && !isBulkSelecting { vm.startEditing(entry) }
        }
        .onTapGesture {
            if isBulkSelecting {
                vm.toggleBulkSelection(entry.id)
            } else {
                // Clicking never deselects: the selection stays put so the
                // reader pane doesn't vanish on an accidental re-click.
                vm.select(entry)
            }
        }
        .contextMenu { contextMenu }
        .confirmationDialog(
            "Delete this entry forever?",
            isPresented: $showPermanentDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Forever", role: .destructive) {
                vm.deleteForever(entry)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone. The entry and its attachments will be permanently removed.")
        }
        .animation(OmegaTheme.Motion.quick.animation(reduceMotion: reduceMotion), value: hover)
        .animation(OmegaTheme.Motion.quick.animation(reduceMotion: reduceMotion), value: isSelected)
    }

    // MARK: Pieces

    var titleLine: some View {
        HStack(spacing: 5) {
            if entry.isPinned {
                Image(systemName: "pin.fill").font(OmegaTheme.font(.meta)).foregroundColor(theme.accentColor)
            }
            if entry.isHidden {
                Image(systemName: isContentLocked ? "lock.fill" : "lock.open")
                    .font(OmegaTheme.font(.meta))
                    .foregroundColor(theme.accentColor.opacity(isContentLocked ? 0.9 : 0.7))
            }
            Text(entry.displayTitle)
                .font(OmegaTheme.font(.body, .semibold, design: .serif))
                .foregroundColor(theme.titleTextColor.opacity(isContentLocked ? 0.72 : 1))
                .lineLimit(1)
            Spacer(minLength: 2)
            if density == .compact {
                Text(entry.createdAt.formatted(.dateTime.month(.abbreviated).day()))
                    .font(OmegaTheme.font(.meta)).foregroundColor(theme.secondaryTextColor.opacity(0.8))
                    // The title truncates instead; the date never wraps.
                    .lineLimit(1).fixedSize()
            }
            if entry.isFavorite {
                Image(systemName: "star.fill").font(OmegaTheme.font(.meta)).foregroundColor(.yellow)
            }
            // Attachment presence is body-derived: hidden while locked.
            if !entry.attachments.isEmpty && canShowContent {
                Image(systemName: "paperclip").font(OmegaTheme.font(.meta)).foregroundColor(theme.secondaryTextColor)
            }
        }
    }

    @ViewBuilder
    var previewLines: some View {
        if isContentLocked {
            Text("Hidden · unlock to read")
                .font(OmegaTheme.font(.meta))
                .foregroundColor(theme.secondaryTextColor.opacity(0.55))
                .lineLimit(1)
        } else if let snippet = vm.searchSnippet(for: entry) {
            Text(Self.highlighted(snippet, accent: theme.accentColor, base: theme.secondaryTextColor))
                .font(OmegaTheme.font(.meta))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        } else {
            Text(entry.preview)
                .font(OmegaTheme.font(.meta))
                .foregroundColor(theme.secondaryTextColor)
                .lineLimit(density == .cards ? 4 : 2)
                .multilineTextAlignment(.leading)
        }
    }

    /// Mood · date · words · tag chips on ONE line at any column width.
    /// `ViewThatFits` tries `RowsMetaLayout` candidates richest-first, each at
    /// its unwrapped width, so a narrow (280pt) column drops extra chips, then
    /// the time, then the word count — chips never break inside a word and the
    /// date never wraps. Locked hidden entries get no tags/words in any
    /// candidate (the Core helper enforces it).
    var metaLine: some View {
        let candidates = RowsMetaLayout.candidates(tags: entry.tags, canShowContent: canShowContent,
                                                   hasWordCount: entry.wordCount > 0)
        return ViewThatFits(in: .horizontal) {
            ForEach(Array(candidates.enumerated()), id: \.offset) { _, candidate in
                metaLine(candidate)
            }
        }
    }

    func metaLine(_ candidate: RowsMetaLayout.Candidate) -> some View {
        HStack(spacing: 6) {
            Text(entry.mood.emoji).font(OmegaTheme.font(.meta)).fixedSize()
            Text(metaDateText(candidate.dateStyle))
                .font(OmegaTheme.font(.meta))
                .foregroundColor(theme.secondaryTextColor.opacity(0.8))
                .lineLimit(1)
                .fixedSize()
            if candidate.showsWordCount {
                Text("· \(entry.wordCount)w")
                    .font(OmegaTheme.font(.meta))
                    .foregroundColor(theme.secondaryTextColor.opacity(0.6))
                    .lineLimit(1)
                    .fixedSize()
            }
            Spacer(minLength: 2)
            ForEach(Array(candidate.visibleTags.enumerated()), id: \.offset) { _, tag in
                tagChip(tag)
            }
            if !candidate.hiddenTags.isEmpty { overflowChip(candidate.hiddenTags) }
        }
    }

    func metaDateText(_ style: RowsMetaLayout.DateStyle) -> String {
        if isTrash { return trashLabel }
        switch style {
        case .dateAndTime: return entry.createdAt.formatted(date: .abbreviated, time: .shortened)
        case .dateOnly: return entry.createdAt.formatted(date: .abbreviated, time: .omitted)
        }
    }

    /// One tag chip; never wraps or truncates mid-word (the layout drops the
    /// whole chip into "+N" instead).
    func tagChip(_ tag: String) -> some View {
        let c = vm.color(forTag: tag) ?? theme.accentColor
        return HStack(spacing: 3) {
            Circle().fill(c).frame(width: 5, height: 5)
            Text(TagPath.leaf(of: tag))
                .font(OmegaTheme.font(.meta, .medium))
                .foregroundColor(theme.bodyTextColor.opacity(0.9))
                .lineLimit(1)
        }
        .padding(.horizontal, 5).padding(.vertical, 1)
        .background(Capsule().fill(c.opacity(0.14)))
        .fixedSize()
    }

    /// "+N" for the tags that did not fit. Its label/tooltip names those
    /// tags — only reachable while content may be shown (the candidates
    /// carry no tags for a locked hidden entry).
    func overflowChip(_ hidden: [String]) -> some View {
        let label = RowsMetaLayout.overflowAccessibilityLabel(hiddenTags: hidden.map { TagPath.leaf(of: $0) },
                                                              canShowContent: canShowContent)
        return Text(RowsMetaLayout.overflowText(hidden.count))
            .font(OmegaTheme.font(.meta, .medium))
            .foregroundColor(theme.secondaryTextColor.opacity(0.85))
            .lineLimit(1)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(theme.secondaryTextColor.opacity(0.12)))
            .fixedSize()
            .accessibilityLabel(label ?? "")
            .help(label ?? "")
    }

    /// Hover quick actions: pin, favorite, archive. Each is a real labelled button.
    var quickActions: some View {
        HStack(spacing: 2) {
            quick(entry.isPinned ? "pin.slash" : "pin", entry.isPinned ? "Unpin" : "Pin") { vm.togglePin(entry) }
            quick(entry.isFavorite ? "star.slash" : "star", entry.isFavorite ? "Unfavorite" : "Favorite") { vm.toggleFavorite(entry) }
            quick(entry.isArchived ? "tray.and.arrow.up" : "archivebox", entry.isArchived ? "Unarchive" : "Archive") { vm.toggleArchive(entry) }
        }
        .padding(2)
        .background(Capsule().fill(theme.cardColor.opacity(0.95)))
        .overlay(Capsule().strokeBorder(theme.borderColor, lineWidth: 1))
    }

    func quick(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(OmegaTheme.font(.meta, .medium))
                .foregroundColor(theme.bodyTextColor)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .omegaTooltip(label)
    }

    /// First image attachment, decoded small and cached. Never built for locked hidden entries.
    var thumbnail: NSImage? {
        guard canShowContent, let att = entry.attachments.first(where: \.isImage) else { return nil }
        if let hit = AttachmentPreview.cached(att.id) { return hit }
        guard let data = vm.db.readAttachmentData(att),
              let image = AttachmentPreview.thumbnail(from: data, maxPixel: 132) else { return nil }
        AttachmentPreview.store(image, for: att.id)
        return image
    }

    static func highlighted(_ snippet: SearchSnippet, accent: Color, base: Color) -> AttributedString {
        var out = AttributedString(snippet.text)
        out.foregroundColor = base
        for r in snippet.highlights {
            guard let sr = Range(r, in: snippet.text),
                  let lo = AttributedString.Index(sr.lowerBound, within: out),
                  let hi = AttributedString.Index(sr.upperBound, within: out) else { continue }
            out[lo..<hi].foregroundColor = accent
            out[lo..<hi].inlinePresentationIntent = .stronglyEmphasized
        }
        return out
    }

    var trashLabel: String {
        let remaining = DatabaseManager.trashRetentionDays - entry.daysInTrash
        return remaining <= 0 ? "Deleting soon" : "\(remaining)d left"
    }

    var isContentLocked: Bool {
        entry.isHidden && !biometricAuth.isAuthenticated
    }

    /// VoiceOver label built by the Core helper, which drops tags, word count
    /// and attachments for a locked hidden entry (title/mood/date only).
    var accessibilityLabel: String {
        A11yDescriptions.entryRowLabel(accessibilitySummary)
    }

    var accessibilitySummary: A11yEntrySummary {
        let show = canShowContent
        return A11yEntrySummary(
            title: entry.displayTitle,
            moodLabel: entry.mood.label,
            dateText: isTrash ? trashLabel : entry.createdAt.formatted(date: .abbreviated, time: .omitted),
            isPinned: entry.isPinned,
            isFavorite: entry.isFavorite,
            isHidden: entry.isHidden,
            canShowContent: show,
            wordCount: show ? entry.wordCount : 0,
            tags: show ? entry.tags.map { TagPath.leaf(of: $0) } : [],
            attachmentCount: show ? entry.attachments.count : 0
        )
    }

    func perform(_ action: A11yEntryRowAction) {
        switch action {
        case .edit: vm.startEditing(entry)
        case .togglePin: vm.togglePin(entry)
        case .toggleFavorite: vm.toggleFavorite(entry)
        case .toggleArchive: vm.toggleArchive(entry)
        case .moveToTrash: vm.deleteEntry(entry)
        case .restore: vm.restoreFromTrash(entry)
        case .deleteForever: showPermanentDeleteConfirmation = true
        }
    }

    var rowBackground: Color {
        if isBulkSelected { return theme.accentColor.opacity(0.14) }
        if isSelected { return theme.accentColor.opacity(0.12) }
        if isContentLocked { return theme.cardColor.opacity(hover ? 0.28 : 0.18) }
        if hover { return theme.cardColor.opacity(0.75) }
        return theme.cardColor.opacity(0.4)
    }

    var rowBorder: Color {
        if isSelected { return theme.accentColor.opacity(0.6) }
        if isContentLocked { return theme.accentColor.opacity(0.22) }
        return theme.titleTextColor.opacity(0.06)
    }

    @ViewBuilder
    var contextMenu: some View {
        if isTrash {
            Button { vm.restoreFromTrash(entry) } label: { Label("Restore", systemImage: "arrow.uturn.backward") }
            Divider()
            Button(role: .destructive) { showPermanentDeleteConfirmation = true } label: {
                Label("Delete Forever", systemImage: "trash.slash")
            }
        } else {
            Button { vm.startEditing(entry) } label: { Label("Edit", systemImage: "pencil") }
            Button { vm.togglePin(entry) } label: {
                Label(entry.isPinned ? "Unpin" : "Pin", systemImage: entry.isPinned ? "pin.slash" : "pin")
            }
            Button { vm.toggleFavorite(entry) } label: {
                Label(entry.isFavorite ? "Unfavorite" : "Favorite", systemImage: entry.isFavorite ? "star.slash" : "star")
            }
            Button { vm.duplicate(entry) } label: { Label("Duplicate", systemImage: "doc.on.doc") }
            Divider()
            Menu("Set Mood") {
                ForEach(Mood.allCases) { mood in
                    Button { vm.setMood(mood, for: entry) } label: {
                        // Checkmark follows THIS row's entry, not the selection.
                        if let icon = Self.moodMenuIcon(for: mood, current: entry.mood) {
                            Label("\(mood.emoji)  \(mood.label)", systemImage: icon)
                        } else {
                            Text("\(mood.emoji)  \(mood.label)")
                        }
                    }
                }
            }
            Button { vm.copyAsMarkdown(entry) } label: { Label("Copy as Markdown", systemImage: "doc.on.clipboard") }
            Divider()
            Button { vm.toggleHidden(entry) } label: {
                Label(entry.isHidden ? "Unhide" : "Hide", systemImage: entry.isHidden ? "lock.open" : "lock")
            }
            Button { vm.toggleArchive(entry) } label: {
                Label(entry.isArchived ? "Unarchive" : "Archive", systemImage: entry.isArchived ? "tray.and.arrow.up" : "archivebox")
            }
            Button(role: .destructive) { vm.deleteEntry(entry) } label: {
                Label("Move to Trash", systemImage: "trash")
            }
        }
    }

    /// Context-menu mood icon: a checkmark for the row entry's current mood, else none.
    nonisolated static func moodMenuIcon(for mood: Mood, current: Mood) -> String? {
        mood == current ? "checkmark" : nil
    }
}

/// Adds one VoiceOver custom action per row command (Pin, Favorite, Archive…),
/// so the hover-only quick actions are reachable from the VO actions menu.
struct EntryRowAccessibilityActions: ViewModifier {
    let actions: [A11yEntryRowAction]
    let entry: JournalEntry
    let perform: (A11yEntryRowAction) -> Void

    func body(content: Content) -> some View {
        content.accessibilityActions {
            ForEach(actions, id: \.self) { action in
                Button(action.title(isPinned: entry.isPinned, isFavorite: entry.isFavorite, isArchived: entry.isArchived)) {
                    perform(action)
                }
            }
        }
    }
}
