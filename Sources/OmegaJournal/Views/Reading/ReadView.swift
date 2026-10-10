import SwiftUI
import AppKit
import OmegaJournalCore

// MARK: - Read View

struct ReadView: View {
    @ObservedObject var vm: JournalViewModel
    let entry: JournalEntry
    var isTrash: Bool = false

    @ObservedObject private var theme = ThemeManager.shared
    @ObservedObject private var biometricAuth = BiometricAuth.shared
    @State private var showPermanentDeleteConfirmation = false
    @State private var showHistory = false
    @State private var showGraph = false
    @AppStorage(ReadingPreferences.showCoverKey) private var showCover = true
    @State private var showOutline = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(ReadingPreferences.fontDesignKey) private var readingFontDesign = "default"

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.25)

            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    coverImage
                    header
                    if showOutline, !isContentLocked { outlineList(proxy) }

                    if entry.isHidden && !biometricAuth.isAuthenticated {
                        hiddenContentOverlay
                    } else if entry.body.isEmpty {
                        Text("This entry has no content yet.")
                            .font(OmegaTheme.font(.body))
                            .foregroundColor(theme.secondaryTextColor)
                            .italic()
                    } else {
                        MarkdownBodyView(markdown: bodyParts.rest, style: renderStyle, textColor: theme.bodyTextColor, lineSpacing: 6,
                                         attachments: entry.attachments, db: vm.db,
                                         onResizeImage: isTrash ? nil : { line, width in resizeImage(atLine: line, width: width) })
                            .id("reader-body")
                            .environment(\.openURL, OpenURLAction { url in
                                if let title = MarkdownLogic.wikiLinkTitle(from: url) {
                                    vm.openLinkedEntry(titled: title)
                                    return .handled
                                }
                                guard let line = MarkdownLogic.taskLine(from: url) else { return .systemAction }
                                toggleTask(atLine: line)
                                return .handled
                            })
                    }

                    if !entry.attachments.isEmpty && !(entry.isHidden && !biometricAuth.isAuthenticated) {
                        attachmentsSection
                    }

                    if !isTrash && !isContentLocked {
                        BacklinksPanel(vm: vm, entry: entry) { showGraph = true }
                    }
                }
                .padding(.horizontal, 30)
                .padding(.vertical, 26)
                // Readable measure: ~70 characters per line at the reading size.
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollContentBackground(.hidden)
            }
        }
        .sheet(isPresented: $showGraph) {
            GraphView(vm: vm) { vm.select($0) }
        }
        .background(theme.backgroundColor)
        .sheet(isPresented: $showHistory) {
            RevisionHistoryView(vm: vm, entry: entry)
        }
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
    }

    // MARK: Cover

    /// First image attachment, wide and cropped. Never shown for a locked hidden entry.
    @ViewBuilder
    private var coverImage: some View {
        if showCover, !isContentLocked, let att = entry.attachments.first(where: \.isImage),
           let image = coverNSImage(att) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity)
                .frame(height: 200)
                .clipShape(RoundedRectangle(cornerRadius: OmegaTheme.Radius.card, style: .continuous))
                .accessibilityLabel("Cover image: \(att.filename)")
        }
    }

    private func coverNSImage(_ att: Attachment) -> NSImage? {
        let key = att.id + "#cover"
        if let hit = AttachmentPreview.cached(key) { return hit }
        guard let data = vm.db.readAttachmentData(att),
              let img = AttachmentPreview.thumbnail(from: data, maxPixel: 1400) else { return nil }
        AttachmentPreview.store(img, for: key)
        return img
    }

    // MARK: Outline (table of contents)

    private var isContentLocked: Bool { entry.isHidden && !biometricAuth.isAuthenticated }

    private var outline: [OutlineHeading] { MarkdownOutline.headings(in: entry.body) }

    private var showsOutlineToggle: Bool {
        !isContentLocked && MarkdownOutline.shouldShow(headings: outline, wordCount: entry.wordCount)
    }

    /// Jumps proportionally to where the heading sits in the text. The renderer emits one text run per
    /// block, so an exact per-heading anchor isn't available; this lands within a screen of the heading.
    private func outlineList(_ proxy: ScrollViewProxy) -> some View {
        let lines = max(1, entry.body.split(separator: "\n", omittingEmptySubsequences: false).count)
        return VStack(alignment: .leading, spacing: 2) {
            Text("CONTENTS").font(OmegaTheme.font(.meta, .semibold)).tracking(0.7).foregroundColor(theme.secondaryTextColor)
                .accessibilityAddTraits(.isHeader)
            ForEach(outline) { h in
                Button {
                    let ratio = min(1, max(0, Double(h.line) / Double(lines)))
                    withAnimation(OmegaTheme.Motion.standard.animation(reduceMotion: reduceMotion)) {
                        proxy.scrollTo("reader-body", anchor: UnitPoint(x: 0, y: ratio))
                    }
                } label: {
                    Text(h.title)
                        .font(OmegaTheme.font(.caption, h.level == 1 ? .semibold : .regular))
                        .foregroundColor(theme.accentColor)
                        .padding(.leading, CGFloat(max(0, h.level - 1)) * 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Jump to \(h.title)")
            }
        }
        .padding(OmegaTheme.Spacing.m)
        .background(RoundedRectangle(cornerRadius: OmegaTheme.Radius.control, style: .continuous).fill(theme.cardColor.opacity(0.4)))
    }

    // MARK: Body rendering & tasks

    /// Body without the optional trailing place/weather stamp comment.
    private var bodyParts: (stamp: EntryStamp?, rest: String) { EntryStampCodec.split(entry.body) }

    private func resizeImage(atLine line: Int, width: Int?) {
        guard !isTrash, let newBody = ImageRefs.resizing(body: bodyParts.rest, lineIndex: line, width: width) else { return }
        vm.updateBody(EntryStampCodec.join(stamp: bodyParts.stamp, rest: newBody), for: entry)
    }

    private var renderStyle: MarkdownRenderStyle {
        MarkdownRenderStyle(
            linkColor: theme.accentColor, codeColor: theme.accentColor,
            mutedColor: theme.secondaryTextColor, interactiveTasks: !isTrash,
            resolvedLinkTitles: vm.linkableTitles(),
            fontDesign: ReadingPreferences.fontDesign(from: readingFontDesign))
    }

    /// Toggles a task checkbox via the VM's immediate-mutation path (flushes pending autosave first).
    private func toggleTask(atLine line: Int) {
        guard !isTrash, let newBody = MarkdownLogic.togglingTask(inBody: bodyParts.rest, lineIndex: line) else { return }
        vm.updateBody(EntryStampCodec.join(stamp: bodyParts.stamp, rest: newBody), for: entry)
    }

    /// Black or white, whichever contrasts better with the accent color.
    private var onAccentColor: Color {
        let ns = NSColor(theme.accentColor).usingColorSpace(.sRGB) ?? .systemPurple
        return MarkdownLogic.prefersDarkText(onRed: Double(ns.redComponent), green: Double(ns.greenComponent), blue: Double(ns.blueComponent))
            ? .black : .white
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 4) {
            if isTrash {
                Button {
                    vm.restoreFromTrash(entry)
                } label: {
                    Label("Restore", systemImage: "arrow.uturn.backward")
                        .font(OmegaTheme.font(.meta, .medium))
                        .foregroundColor(theme.accentColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(theme.accentColor.opacity(0.15)))
                }
                .buttonStyle(.plain)

                Spacer()

                Text("\(max(0, DatabaseManager.trashRetentionDays - entry.daysInTrash)) days until permanent deletion")
                    .font(OmegaTheme.font(.meta))
                    .foregroundColor(theme.secondaryTextColor)

                ActionButton(icon: "trash.slash", color: .red, active: true, tooltip: "Delete Forever", isDestructive: true) {
                    showPermanentDeleteConfirmation = true
                }
                    .accessibilityLabel("Delete Forever")
            } else {
                // Primary actions are labeled and few; everything else lives in
                // one labeled "More" menu, with destructive actions separated.
                Button {
                    vm.startEditing(entry)
                } label: {
                    Label("Edit", systemImage: "pencil")
                        .font(OmegaTheme.font(.meta, .semibold))
                        .foregroundColor(theme.onAccentColor)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(theme.accentColor))
                }
                .buttonStyle(.plain)
                .omegaTooltip("Edit (⌘E)")
                .accessibilityLabel("Edit (⌘E)")

                ActionButton(icon: entry.isFavorite ? "star.fill" : "star", color: .yellow, active: entry.isFavorite, tooltip: entry.isFavorite ? "Unfavorite" : "Favorite") {
                    vm.toggleFavorite(entry)
                }
                    .accessibilityLabel(entry.isFavorite ? "Unfavorite" : "Favorite")
                ActionButton(icon: entry.isPinned ? "pin.fill" : "pin", color: theme.accentColor, active: entry.isPinned, tooltip: entry.isPinned ? "Unpin" : "Pin") {
                    vm.togglePin(entry)
                }
                    .accessibilityLabel(entry.isPinned ? "Unpin" : "Pin")

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
                        Text(entry.mood.emoji).font(OmegaTheme.font(.body))
                        Text(entry.mood.label).font(OmegaTheme.font(.meta))
                    }
                    .foregroundColor(theme.bodyTextColor)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Mood: \(entry.mood.label). Change mood")

                if showsOutlineToggle {
                    ActionButton(icon: "list.bullet.indent", color: theme.accentColor, active: showOutline, tooltip: "Table of contents") {
                        showOutline.toggle()
                    }
                    .accessibilityLabel("Table of contents")
                }
                if entry.isHidden && biometricAuth.isAuthenticated {
                    ActionButton(icon: "lock.fill", color: theme.accentColor, active: true, tooltip: "Lock hidden entries (⌘L)") {
                        vm.lockHiddenEntries()
                    }
                        .accessibilityLabel("Lock hidden entries (⌘L)")
                }

                moreMenu
            }
        }
        // ⌘P keeps working even though Print moved into the More menu.
        .background(
            Button("") { printEntry() }
                .keyboardShortcut("p", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
                .disabled(isTrash)
        )
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func printEntry() {
        Task {
            guard await vm.revealIfNeeded(entry) else { return }
            ExportManager.printEntry(entry, accent: NSColor(theme.accentColor))
        }
    }

    private var moreMenu: some View {
        Menu {
            Button {
                Task {
                    guard await vm.revealIfNeeded(entry) else { return }
                    showHistory = true
                }
            } label: { Label("Version History…", systemImage: "clock.arrow.circlepath") }
            Button { vm.duplicate(entry) } label: { Label("Duplicate", systemImage: "doc.on.doc") }
            Button { vm.copyAsMarkdown(entry) } label: { Label("Copy as Markdown", systemImage: "doc.on.clipboard") }
            Divider()
            Button { printEntry() } label: { Label("Print…  ⌘P", systemImage: "printer") }
            Button {
                Task {
                    guard await vm.revealIfNeeded(entry) else { return }
                    ImportExportPanels.exportCurrentEntry(vm: vm)
                }
            } label: { Label("Export…", systemImage: "square.and.arrow.up") }
            Divider()
            Button { vm.toggleArchive(entry) } label: {
                Label(entry.isArchived ? "Unarchive" : "Archive", systemImage: entry.isArchived ? "tray.and.arrow.up" : "archivebox")
            }
            Button { vm.toggleHidden(entry) } label: {
                Label(entry.isHidden ? "Unhide" : "Hide", systemImage: entry.isHidden ? "lock.open" : "lock")
            }
            Divider()
            Button(role: .destructive) { vm.deleteEntry(entry) } label: {
                Label("Move to Trash", systemImage: "trash")
            }
        } label: {
            Label("More", systemImage: "ellipsis.circle")
                .font(OmegaTheme.font(.meta, .medium))
                .foregroundColor(theme.secondaryTextColor)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .omegaTooltip("More actions")
        .accessibilityLabel("More actions")
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(entry.displayTitle)
                .font(OmegaTheme.font(.title, .bold, design: .serif))
                .foregroundColor(theme.titleTextColor)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                metaChip(entry.mood.emoji + " " + entry.mood.label, color: entry.mood.color)
                metaChip(entry.createdAt.formatted(date: .long, time: .shortened))
                metaChip("\(entry.wordCount) words")
                metaChip(entry.readingTime)
                if let stamp = bodyParts.stamp, !stamp.isEmpty, !(entry.isHidden && !biometricAuth.isAuthenticated) {
                    metaChip("📍 " + stamp.summary)
                }
            }

            if !entry.tags.isEmpty && !(entry.isHidden && !biometricAuth.isAuthenticated) {
                FlowLayout(spacing: 5) {
                    ForEach(entry.tags, id: \.self) { tag in
                        Text("#\(tag)")
                            .font(OmegaTheme.font(.meta, .medium))
                            .foregroundColor(theme.accentColor)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2.5)
                            .background(Capsule().fill(theme.accentColor.opacity(0.14)))
                            .accessibilityLabel("Tag \(tag)")
                    }
                }
            }

            if entry.updatedAt.timeIntervalSince(entry.createdAt) > 60 {
                Text("Edited \(entry.updatedAt.formatted(.relative(presentation: .named)))")
                    .font(OmegaTheme.font(.meta))
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
                    .font(OmegaTheme.font(.title, .light))
                    .foregroundColor(theme.accentColor)
            }

            VStack(spacing: 5) {
                Text("Content Hidden")
                    .font(OmegaTheme.font(.bodyLarge, .semibold, design: .serif))
                    .foregroundColor(theme.titleTextColor)

                Text("Authenticate with \(biometricAuth.biometricType) to view this entry.")
                    .font(OmegaTheme.font(.meta))
                    .foregroundColor(theme.secondaryTextColor)
            }

            Button {
                Task { _ = await biometricAuth.authenticate() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: biometricAuth.biometricType == "Touch ID" ? "touchid" : "lock.open.fill")
                        .font(OmegaTheme.font(.caption))
                    Text("Unlock")
                        .font(OmegaTheme.font(.caption, .semibold))
                }
                .foregroundColor(onAccentColor)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(Capsule().fill(theme.accentColor))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Unlock entry with \(biometricAuth.biometricType)")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private func metaChip(_ text: String, color: Color? = nil) -> some View {
        Text(text)
            .font(OmegaTheme.font(.meta))
            .foregroundColor(color ?? theme.secondaryTextColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(
                Capsule().fill((color ?? theme.secondaryTextColor).opacity(0.12))
            )
    }

    // MARK: Attachments

    /// Capped, cached thumbnail so re-rendering doesn't re-decrypt and decode
    /// full-size photos every time.
    private func attachmentThumbnail(_ attachment: Attachment) -> NSImage? {
        if let hit = AttachmentPreview.cached(attachment.id) { return hit }
        guard let data = vm.db.readAttachmentData(attachment),
              let image = AttachmentPreview.thumbnail(from: data, maxPixel: 132) else { return nil }
        AttachmentPreview.store(image, for: attachment.id)
        return image
    }

    private var attachmentsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().opacity(0.2)
            Text("ATTACHMENTS (\(entry.attachments.count))")
                .font(OmegaTheme.font(.meta, .semibold))
                .tracking(0.7)
                .foregroundColor(theme.secondaryTextColor)

            ForEach(entry.attachments) { attachment in
                if attachment.isAudio {
                    HStack(spacing: 9) {
                        AudioMemoRow(attachment: attachment, db: vm.db)
                        Button { vm.deleteAttachment(attachment) } label: {
                            Image(systemName: "xmark.circle")
                                .font(OmegaTheme.font(.caption))
                                .foregroundColor(theme.secondaryTextColor)
                        }
                        .buttonStyle(.plain)
                        .omegaTooltip("Remove")
                        .accessibilityLabel("Remove attachment \(attachment.filename)")
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(theme.cardColor.opacity(0.4)))
                } else {
                HStack(spacing: 9) {
                    if attachment.isImage, let image = attachmentThumbnail(attachment) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    } else {
                        Image(systemName: "doc.fill")
                            .font(OmegaTheme.font(.heading))
                            .foregroundColor(theme.accentColor)
                            .frame(width: 44, height: 44)
                            .background(RoundedRectangle(cornerRadius: 6).fill(theme.cardColor.opacity(0.6)))
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(attachment.filename)
                            .font(OmegaTheme.font(.caption, .medium))
                            .foregroundColor(theme.titleTextColor)
                            .lineLimit(1)
                        Text(attachment.mimeType)
                            .font(OmegaTheme.font(.meta))
                            .foregroundColor(theme.secondaryTextColor)
                    }
                    Spacer()
                    Button {
                        // Attachments are encrypted at rest; decrypt to a
                        // transient temp file for the external app.
                        if let tempURL = vm.db.openAttachmentExternally(attachment) {
                            NSWorkspace.shared.open(tempURL)
                            AttachmentPreview.scheduleTempCleanup(of: tempURL)
                        } else {
                            vm.showToast("Couldn't open attachment", isError: true)
                        }
                    } label: {
                        Image(systemName: "arrow.up.forward.square")
                            .font(OmegaTheme.font(.caption))
                            .foregroundColor(theme.accentColor)
                    }
                    .buttonStyle(.plain)
                    .omegaTooltip("Open")
                    .accessibilityLabel("Open attachment \(attachment.filename)")

                    Button {
                        vm.deleteAttachment(attachment)
                    } label: {
                        Image(systemName: "xmark.circle")
                            .font(OmegaTheme.font(.caption))
                            .foregroundColor(theme.secondaryTextColor)
                    }
                    .buttonStyle(.plain)
                    .omegaTooltip("Remove")
                    .accessibilityLabel("Remove attachment \(attachment.filename)")
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.cardColor.opacity(0.4)))
                }
            }
        }
    }
}
