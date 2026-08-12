import SwiftUI
import AppKit

// MARK: - Read View

struct ReadView: View {
    @ObservedObject var vm: JournalViewModel
    let entry: JournalEntry
    var isTrash: Bool = false

    @ObservedObject private var theme = ThemeManager.shared
    @ObservedObject private var biometricAuth = BiometricAuth.shared

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.25)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header

                    if entry.isHidden && !biometricAuth.isAuthenticated {
                        hiddenContentOverlay
                    } else if entry.body.isEmpty {
                        Text("This entry has no content yet.")
                            .font(.system(size: 13))
                            .foregroundColor(theme.secondaryTextColor)
                            .italic()
                    } else {
                        Text(MarkdownRenderer.render(entry.body))
                            .foregroundColor(theme.bodyTextColor)
                            .textSelection(.enabled)
                            .lineSpacing(5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if !entry.attachments.isEmpty && !(entry.isHidden && !biometricAuth.isAuthenticated) {
                        attachmentsSection
                    }
                }
                .padding(.horizontal, 30)
                .padding(.vertical, 26)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollContentBackground(.hidden)
        }
        .background(theme.backgroundColor)
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 4) {
            if isTrash {
                Button {
                    vm.restoreFromTrash(entry)
                } label: {
                    Label("Restore", systemImage: "arrow.uturn.backward")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.accentColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(theme.accentColor.opacity(0.15)))
                }
                .buttonStyle(.plain)

                Spacer()

                Text("\(max(0, DatabaseManager.trashRetentionDays - entry.daysInTrash)) days until permanent deletion")
                    .font(.system(size: 10))
                    .foregroundColor(theme.secondaryTextColor)

                ActionButton(icon: "trash.slash", color: .red, active: true, tooltip: "Delete Forever", isDestructive: true) {
                    vm.deleteForever(entry)
                }
            } else {
                ActionButton(icon: "pencil", color: theme.accentColor, active: true, tooltip: "Edit (⌘E)") {
                    vm.startEditing(entry)
                }
                ActionButton(icon: entry.isPinned ? "pin.fill" : "pin", color: theme.accentColor, active: entry.isPinned, tooltip: entry.isPinned ? "Unpin" : "Pin") {
                    vm.togglePin(entry)
                }
                ActionButton(icon: entry.isFavorite ? "star.fill" : "star", color: .yellow, active: entry.isFavorite, tooltip: entry.isFavorite ? "Unfavorite" : "Favorite") {
                    vm.toggleFavorite(entry)
                }
                ActionButton(icon: "doc.on.doc", color: theme.accentColor, active: false, tooltip: "Duplicate") {
                    vm.duplicate(entry)
                }
                ActionButton(icon: "doc.on.clipboard", color: theme.accentColor, active: false, tooltip: "Copy as Markdown") {
                    vm.copyAsMarkdown(entry)
                }

                Spacer()

                Menu {
                    ForEach(Mood.allCases) { mood in
                        Button {
                            vm.setMood(mood, for: entry)
                        } label: {
                            Text("\(mood.emoji)  \(mood.label)")
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(entry.mood.emoji).font(.system(size: 13))
                        Text(entry.mood.label).font(.system(size: 11))
                    }
                    .foregroundColor(theme.bodyTextColor)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                ActionButton(icon: "square.and.arrow.up", color: theme.accentColor, active: false, tooltip: "Export this entry") {
                    Task {
                        guard await vm.revealIfNeeded(entry) else { return }
                        ImportExportPanels.exportCurrentEntry(vm: vm)
                    }
                }
                ActionButton(icon: entry.isArchived ? "tray.and.arrow.up" : "archivebox", color: theme.accentColor, active: entry.isArchived, tooltip: entry.isArchived ? "Unarchive" : "Archive") {
                    vm.toggleArchive(entry)
                }
                ActionButton(icon: entry.isHidden ? "lock.open" : "lock", color: theme.accentColor, active: entry.isHidden, tooltip: entry.isHidden ? "Unhide" : "Hide") {
                    vm.toggleHidden(entry)
                }
                if entry.isHidden && biometricAuth.isAuthenticated {
                    ActionButton(icon: "lock.fill", color: theme.accentColor, active: true, tooltip: "Lock hidden entries (⌘L)") {
                        vm.lockHiddenEntries()
                    }
                }
                ActionButton(icon: "trash", color: .red, active: false, tooltip: "Move to Trash", isDestructive: true) {
                    vm.deleteEntry(entry)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(entry.displayTitle)
                .font(.system(size: 27, weight: .bold, design: .serif))
                .foregroundColor(theme.titleTextColor)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                metaChip(entry.mood.emoji + " " + entry.mood.label, color: entry.mood.color)
                metaChip(entry.createdAt.formatted(date: .long, time: .shortened))
                metaChip("\(entry.wordCount) words")
                metaChip(entry.readingTime)
            }

            if !entry.tags.isEmpty && !(entry.isHidden && !biometricAuth.isAuthenticated) {
                HStack(spacing: 5) {
                    ForEach(entry.tags, id: \.self) { tag in
                        Text("#\(tag)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(theme.accentColor)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2.5)
                            .background(Capsule().fill(theme.accentColor.opacity(0.14)))
                    }
                }
            }

            if entry.updatedAt.timeIntervalSince(entry.createdAt) > 60 {
                Text("Edited \(entry.updatedAt.formatted(.relative(presentation: .named)))")
                    .font(.system(size: 10))
                    .foregroundColor(theme.secondaryTextColor.opacity(0.8))
            }

            Divider().opacity(0.2).padding(.top, 2)
        }
    }

    // MARK: Hidden Content Overlay

    private var hiddenContentOverlay: some View {
        VStack(spacing: 14) {
            Divider().opacity(0.2)

            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [theme.accentColor.opacity(0.25), theme.accentColor.opacity(0.06)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .frame(width: 64, height: 64)
                Image(systemName: "lock.fill")
                    .font(.system(size: 24, weight: .light))
                    .foregroundColor(theme.accentColor)
            }

            VStack(spacing: 5) {
                Text("Content Hidden")
                    .font(.system(size: 15, weight: .semibold, design: .serif))
                    .foregroundColor(theme.titleTextColor)

                Text("Authenticate with \(biometricAuth.biometricType) to view this entry.")
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryTextColor)
            }

            Button {
                Task { _ = await biometricAuth.authenticate() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: biometricAuth.biometricType == "Touch ID" ? "touchid" : "lock.open.fill")
                        .font(.system(size: 12))
                    Text("Unlock")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(Capsule().fill(theme.accentColor))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private func metaChip(_ text: String, color: Color? = nil) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundColor(color ?? theme.secondaryTextColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(
                Capsule().fill((color ?? theme.secondaryTextColor).opacity(0.12))
            )
    }

    // MARK: Attachments

    private var attachmentsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().opacity(0.2)
            Text("ATTACHMENTS (\(entry.attachments.count))")
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.7)
                .foregroundColor(theme.secondaryTextColor)

            ForEach(entry.attachments) { attachment in
                HStack(spacing: 9) {
                    if attachment.isImage, let image = NSImage(contentsOf: attachment.fileURL) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    } else {
                        Image(systemName: "doc.fill")
                            .font(.system(size: 16))
                            .foregroundColor(theme.accentColor)
                            .frame(width: 44, height: 44)
                            .background(RoundedRectangle(cornerRadius: 6).fill(theme.cardColor.opacity(0.6)))
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(attachment.filename)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundColor(theme.titleTextColor)
                            .lineLimit(1)
                        Text(attachment.mimeType)
                            .font(.system(size: 9.5))
                            .foregroundColor(theme.secondaryTextColor)
                    }
                    Spacer()
                    Button {
                        NSWorkspace.shared.open(attachment.fileURL)
                    } label: {
                        Image(systemName: "arrow.up.forward.square")
                            .font(.system(size: 12))
                            .foregroundColor(theme.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help("Open")

                    Button {
                        vm.deleteAttachment(attachment)
                    } label: {
                        Image(systemName: "xmark.circle")
                            .font(.system(size: 12))
                            .foregroundColor(theme.secondaryTextColor)
                    }
                    .buttonStyle(.plain)
                    .help("Remove")
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.cardColor.opacity(0.4)))
            }
        }
    }
}
