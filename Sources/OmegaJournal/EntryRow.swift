import SwiftUI
import OmegaJournalCore

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

    var body: some View {
        HStack(spacing: 9) {
            if isBulkSelecting {
                Image(systemName: isBulkSelected ? "checkmark.circle.fill" : "circle")
                    .font(OmegaTheme.font(.bodyLarge))
                    .foregroundColor(isBulkSelected ? theme.accentColor : theme.secondaryTextColor.opacity(0.5))
            }

            Circle()
                .fill(entry.mood.color)
                .frame(width: 8, height: 8)
                .opacity(isContentLocked ? 0.35 : 0.95)

            VStack(alignment: .leading, spacing: 3) {
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
                    if entry.isFavorite {
                        Image(systemName: "star.fill").font(OmegaTheme.font(.meta)).foregroundColor(.yellow)
                    }
                    if !entry.attachments.isEmpty {
                        Image(systemName: "paperclip").font(OmegaTheme.font(.meta)).foregroundColor(theme.secondaryTextColor)
                    }
                }

                if isContentLocked {
                    Text("Hidden · unlock to read")
                        .font(OmegaTheme.font(.meta))
                        .foregroundColor(theme.secondaryTextColor.opacity(0.55))
                        .lineLimit(1)
                } else {
                    Text(entry.preview)
                        .font(OmegaTheme.font(.meta))
                        .foregroundColor(theme.secondaryTextColor)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                HStack(spacing: 6) {
                    Text(entry.mood.emoji).font(OmegaTheme.font(.meta))
                    Text(isTrash ? trashLabel : entry.createdAt.formatted(date: .abbreviated, time: .shortened).replacingOccurrences(of: " AM", with: " AM"))
                        .font(OmegaTheme.font(.meta))
                        .foregroundColor(theme.secondaryTextColor.opacity(0.8))
                    if entry.wordCount > 0 {
                        Text("· \(entry.wordCount)w")
                            .font(OmegaTheme.font(.meta))
                            .foregroundColor(theme.secondaryTextColor.opacity(0.6))
                    }
                    Spacer(minLength: 2)
                    if !isContentLocked {
                        ForEach(entry.tags.prefix(2), id: \.self) { tag in
                            Text("#\(tag)")
                                .font(OmegaTheme.font(.meta, .medium))
                                .foregroundColor(theme.accentColor.opacity(0.9))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(theme.accentColor.opacity(0.12)))
                        }
                        if entry.tags.count > 2 {
                            Text("+\(entry.tags.count - 2)")
                                .font(OmegaTheme.font(.meta))
                                .foregroundColor(theme.secondaryTextColor.opacity(0.7))
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(rowBackground)
        )
        .hoverGlow(radius: 11, glow: 0.26, border: 0.4, lift: false)
        .opacity(isContentLocked ? 0.82 : 1)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(isBulkSelecting ? "Double tap to change its bulk selection" : "Double tap to open this entry")
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
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hover)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isSelected)
    }

    var trashLabel: String {
        let remaining = DatabaseManager.trashRetentionDays - entry.daysInTrash
        return remaining <= 0 ? "Deleting soon" : "\(remaining)d left"
    }

    var isContentLocked: Bool {
        entry.isHidden && !biometricAuth.isAuthenticated
    }

    var accessibilityLabel: String {
        let privacy = isContentLocked ? "Hidden entry" : entry.displayTitle
        let metadata = "\(entry.mood.label), \(entry.createdAt.formatted(date: .abbreviated, time: .omitted))"
        return "\(privacy), \(metadata)"
    }

    var rowBackground: Color {
        if isBulkSelected { return theme.accentColor.opacity(0.14) }
        if isSelected { return theme.accentColor.opacity(0.12) }
        if isContentLocked { return theme.cardColor.opacity(hover ? 0.28 : 0.18) }
        if hover { return theme.cardColor.opacity(0.75) }
        return theme.cardColor.opacity(0.4)
    }

    var rowBorder: Color {
        if isSelected { return theme.accentColor.opacity(0.45) }
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
                        Label("\(mood.emoji)  \(mood.label)", systemImage: vm.selectedEntry?.mood == mood ? "checkmark" : "")
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
}
