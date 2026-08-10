import SwiftUI

// MARK: - Read View (with Markdown Rendering)

struct ReadView: View {
    let entry: JournalEntry
    @ObservedObject var vm: JournalViewModel
    @ObservedObject private var theme = ThemeManager.shared
    @State private var showDeleteConfirm = false

    private var isDark: Bool { theme.colorScheme == .dark }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Hero section
                HStack(alignment: .top, spacing: 16) {
                    Text(entry.mood.emoji)
                        .font(.system(size: 44))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(entry.title.isEmpty ? "Untitled" : entry.title)
                            .font(OmegaTheme.titleFont)
                            .foregroundColor(.primary)
                        HStack(spacing: 8) {
                            Text(entry.createdAt.formatted(date: .complete, time: .shortened))
                                .font(OmegaTheme.metaFont)
                                .foregroundColor(.secondary)
                            if entry.updatedAt > entry.createdAt.addingTimeInterval(1) {
                                Text("·")
                                    .font(OmegaTheme.metaFont)
                                    .foregroundColor(.secondary.opacity(0.5))
                                Text("Edited \(entry.updatedAt.formatted(.relative(presentation: .named)))")
                                    .font(OmegaTheme.metaFont)
                                    .foregroundColor(.secondary)
                            }
                            Text("·")
                                .font(OmegaTheme.metaFont)
                                .foregroundColor(.secondary.opacity(0.5))
                            Text(entry.readingTime)
                                .font(OmegaTheme.metaFont)
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                    actionButtons
                }

                // Mood & tags
                HStack(spacing: 12) {
                    HStack(spacing: 6) {
                        Text("Mood:")
                            .font(OmegaTheme.metaFont)
                            .foregroundColor(.secondary)
                        Text(entry.mood.label)
                            .font(OmegaTheme.metaFont.weight(.medium))
                            .foregroundColor(entry.mood.color)
                    }
                    if !entry.tags.isEmpty {
                        FlowLayout(spacing: 6) {
                            ForEach(entry.tags, id: \.self) { tag in
                                Text("#\(tag)")
                                    .font(OmegaTheme.captionFont.weight(.medium))
                                    .foregroundColor(theme.accentColor)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(theme.accentColor.opacity(0.12))
                                    .clipShape(Capsule())
                            }
                        }
                    }
                    Spacer()
                }

                Divider()
                    .background(isDark ? Color.white.opacity(0.10) : Color.black.opacity(0.10))

                // Body — rendered as markdown
                if entry.body.isEmpty {
                    Text("No content")
                        .font(OmegaTheme.bodyFont)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(entry.bodyAsAttributed)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .lineSpacing(5)
                }

                // Attachments
                if !entry.attachments.isEmpty {
                    Divider()
                        .background(isDark ? Color.white.opacity(0.10) : Color.black.opacity(0.10))

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Attachments")
                            .font(OmegaTheme.sectionTitleFont)
                            .foregroundColor(.secondary)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 10)], spacing: 10) {
                            ForEach(entry.attachments) { attachment in
                                attachmentThumbnail(attachment)
                            }
                        }
                    }
                }
            }
            .padding(OmegaTheme.contentPadding)
            .frame(maxWidth: OmegaTheme.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.backgroundColor)
        .alert("Delete Entry", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) { vm.deleteEntry(entry) }
        } message: {
            Text("Are you sure you want to delete \"\(entry.title.isEmpty ? "Untitled" : entry.title)\"? This cannot be undone.")
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 6) {
            ActionButton(icon: entry.isPinned ? "pin.fill" : "pin", color: .orange, active: entry.isPinned, tooltip: entry.isPinned ? "Unpin entry" : "Pin entry") { vm.togglePin(entry) }
            ActionButton(icon: entry.isFavorite ? "star.fill" : "star", color: .yellow, active: entry.isFavorite, tooltip: entry.isFavorite ? "Remove from favorites" : "Add to favorites") { vm.toggleFavorite(entry) }
            ActionButton(icon: "pencil", color: theme.accentColor, active: false, tooltip: "Edit entry (⌘E)") { vm.startEditing(entry) }
            ActionButton(icon: "trash", color: .red, active: false, tooltip: "Delete entry", isDestructive: true) { showDeleteConfirm = true }
        }
    }

    @ViewBuilder
    private func attachmentThumbnail(_ attachment: Attachment) -> some View {
        VStack(spacing: 4) {
            if attachment.isImage, let nsImage = NSImage(contentsOf: attachment.fileURL) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 100, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Image(systemName: "doc.fill")
                    .font(.system(size: 28))
                    .foregroundColor(theme.accentColor.opacity(0.7))
                    .frame(width: 100, height: 80)
                    .background(theme.cardColor.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            Text(attachment.filename)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
    }
}
