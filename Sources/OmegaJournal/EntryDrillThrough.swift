import SwiftUI

// MARK: - Entry drill-through (shared)
//
// In-context reader/editor for an entry opened from a reflective workspace
// (Calendar, Insights). Presenters cap the sheet to their workspace size — a
// sheet containing ReadView's ScrollView reports the scroll content's full
// height as its ideal size and would otherwise grow past the window on long
// entries (see CalendarView for the pattern).

/// Route wrapper so entry drill-through sheets can use `.sheet(item:)`.
struct EntryDrillThroughRoute: Identifiable {
    let entryID: String
    var id: String { entryID }
}

struct EntryDrillThroughSheet: View {
    @ObservedObject var vm: JournalViewModel
    let entryID: String
    var contextTitle: String = "Entry"

    @ObservedObject private var theme = ThemeManager.shared
    @ObservedObject private var biometricAuth = BiometricAuth.shared
    @Environment(\.dismiss) private var dismiss

    /// Resolve on every body update rather than retaining an entry snapshot.
    /// The scoped lookup also removes private metadata immediately on re-lock.
    private var currentEntry: JournalEntry? {
        guard let entry = vm.calendarEntries.first(where: { $0.id == entryID }) else { return nil }
        return entry.isHidden && !biometricAuth.isAuthenticated ? nil : entry
    }

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader
            Divider().opacity(0.25)
            sheetContent
        }
        .frame(minWidth: 760, minHeight: 560)
        .background(theme.backgroundColor)
    }

    private var sheetHeader: some View {
        HStack(spacing: 8) {
            Label(contextTitle, systemImage: "book.closed")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(theme.titleTextColor)
            Spacer()
            Button(action: { dismiss() }) {
                Label("Close", systemImage: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.accentColor)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(theme.accentColor.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close \(contextTitle)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(theme.cardColor.opacity(0.22))
    }

    @ViewBuilder
    private var sheetContent: some View {
        if let entry = currentEntry {
            if vm.editingEntryId == entryID {
                EditorView(vm: vm, entry: entry)
                    .id("drill-editor-\(entry.id)")
            } else {
                ReadView(vm: vm, entry: entry)
                    .id("drill-reader-\(entry.id)")
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 26, weight: .light))
                    .foregroundColor(theme.accentColor)
                Text("Entry unavailable")
                    .font(.system(size: 16, weight: .semibold, design: .serif))
                    .foregroundColor(theme.titleTextColor)
                Text("This entry is no longer available in the current scope.")
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryTextColor)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 310)
                Button("Close", action: { dismiss() })
                    .buttonStyle(.bordered)
                    .tint(theme.accentColor)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(32)
        }
    }
}
