import SwiftUI
import OmegaJournalCore

// MARK: - Version history sheet (list + diff + restore)

struct RevisionHistoryView: View {
    @ObservedObject var vm: JournalViewModel
    let entry: JournalEntry
    /// Called after a successful restore with the restored title/body (an open editor adopts them).
    var onRestored: ((String, String) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var theme = ThemeManager.shared
    @State private var revisions: [EntryRevision] = []
    @State private var selectedId: String?
    @State private var oldBody = ""
    @State private var diff: [DiffLine] = []
    @State private var confirmRestore = false

    private var selected: EntryRevision? { revisions.first { $0.id == selectedId } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Version history")
                        .font(OmegaTheme.font(.bodyLarge, .semibold))
                        .foregroundColor(theme.titleTextColor)
                    Text("Snapshots are taken when you finish editing. Restoring keeps the current text as a version too.")
                        .font(OmegaTheme.font(.meta))
                        .foregroundColor(theme.secondaryTextColor)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(OmegaTheme.font(.bodyLarge))
                        .foregroundColor(theme.secondaryTextColor)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close version history")
            }
            .padding(16)
            Divider().opacity(0.25)

            if !vm.canViewRevisions(of: entry) {
                OmegaEmptyState(systemImage: "lock.fill", title: "Version history is locked",
                                message: "Unlock hidden entries to see their versions.")
            } else if revisions.isEmpty {
                OmegaEmptyState(systemImage: "clock.arrow.circlepath", title: "No versions yet",
                                message: "A version is saved each time you finish editing this entry.")
            } else {
                HStack(spacing: 0) {
                    List(revisions, selection: $selectedId) { r in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(OmegaTheme.font(.caption, .medium))
                                .foregroundColor(theme.titleTextColor)
                            Text("\(r.wordCount) words" + (r.isAuto ? "" : " · kept"))
                                .font(OmegaTheme.font(.meta))
                                .foregroundColor(theme.secondaryTextColor)
                        }
                        .tag(r.id)
                        .accessibilityElement(children: .combine)
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                    .frame(width: 190)

                    Divider().opacity(0.25)
                    diffPane
                }
            }
        }
        .frame(width: 760, height: 520)
        .background(theme.backgroundColor)
        .onAppear(perform: load)
        .onChange(of: selectedId) { _, _ in loadSelectedDiff() }
        .confirmationDialog("Restore this version?", isPresented: $confirmRestore, titleVisibility: .visible) {
            Button("Restore") { restore() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The current text is saved as a version first, so you can undo this.")
        }
    }

    private var diffPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                let summary = TextDiff.summary(diff)
                Text(summary.isEmpty ? "Identical to the current text" : "+\(summary.added)  −\(summary.removed) lines vs. current")
                    .font(OmegaTheme.font(.meta, .medium))
                    .foregroundColor(theme.secondaryTextColor)
                Spacer()
                Button("Restore this version") { confirmRestore = true }
                    .buttonStyle(.borderedProminent)
                    .tint(theme.accentColor)
                    .disabled(selected == nil || diff.allSatisfy { $0.kind == .same })
            }
            .padding(12)
            Divider().opacity(0.25)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(diff.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .top, spacing: 6) {
                            Text(line.kind == .added ? "+" : line.kind == .removed ? "−" : " ")
                                .foregroundColor(color(line.kind))
                                .frame(width: 12)
                            Text(line.text.isEmpty ? " " : line.text)
                                .foregroundColor(line.kind == .same ? theme.secondaryTextColor : theme.bodyTextColor)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(OmegaTheme.font(.caption, design: .monospaced))
                        .padding(.horizontal, 10).padding(.vertical, 1)
                        .background(color(line.kind).opacity(line.kind == .same ? 0 : 0.12))
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel((line.kind == .added ? "Added: " : line.kind == .removed ? "Removed: " : "") + line.text)
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    private func color(_ k: DiffKind) -> Color {
        switch k { case .added: .green; case .removed: .red; case .same: theme.secondaryTextColor }
    }

    private func load() {
        revisions = vm.revisions(for: entry)
        selectedId = revisions.first?.id
        loadSelectedDiff()
    }

    /// Diff direction: selected version → current text (what restoring would change).
    private func loadSelectedDiff() {
        guard let r = selected, let body = vm.revisionBody(r, for: entry) else { diff = []; return }
        oldBody = body
        let current = vm.entry(id: entry.id) ?? entry
        diff = TextDiff.lines(old: current.body, new: body)
    }

    private func restore() {
        guard let r = selected, let result = vm.restoreRevision(r, for: entry) else { return }
        onRestored?(result.title, result.body)
        dismiss()
    }
}
