import SwiftUI
import OmegaJournalCore

// MARK: - Header navigation controls

/// Chevron inside the grouped month navigator. The glyph keeps its small look;
/// a 40x40pt hit target and a soft hover wash make it easy to find and click
/// without turning it into a chunky button.
struct MonthChevronButton: View {
    let systemName: String
    let label: String
    let hint: String
    let action: () -> Void

    @ObservedObject private var theme = ThemeManager.shared
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(OmegaTheme.font(.caption, .semibold))
                .foregroundColor(theme.accentColor)
                .frame(width: 40, height: 40)
                .background(
                    Circle()
                        .fill(theme.accentColor.opacity(isHovered ? 0.16 : 0))
                        .frame(width: 28, height: 28)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(nil, value: isHovered)
        .omegaTooltip(label)
        .accessibilityLabel(label)
        .accessibilityHint(hint)
    }
}

/// Rounded pill action for the header (Today jump). The label is locked to its
/// ideal size so it can never wrap one-letter-per-line when space runs low.
struct PillActionButton: View {
    let title: String
    let tooltip: String
    let action: () -> Void

    @ObservedObject private var theme = ThemeManager.shared
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(OmegaTheme.font(.caption, .semibold))
                .foregroundColor(theme.accentColor)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(Capsule().fill(theme.accentColor.opacity(isHovered ? 0.22 : 0.14)))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(nil, value: isHovered)
        .omegaTooltip(tooltip)
        .accessibilityLabel(title)
    }
}

// MARK: - Month day cell

struct CalendarDayCell: View {
    let day: Date
    let entries: [JournalEntry]
    let isSelected: Bool
    let calendar: Calendar
    let onSelect: () -> Void

    @ObservedObject private var theme = ThemeManager.shared
    @ObservedObject private var biometricAuth = BiometricAuth.shared

    private var safeEntries: [JournalEntry] {
        entries.filter { !$0.isHidden || biometricAuth.isAuthenticated }
    }

    private var averageMood: Mood? {
        guard !safeEntries.isEmpty else { return nil }
        let sum = safeEntries.reduce(0) { $0 + $1.mood.rawValue }
        return Mood(rawValue: Int((Double(sum) / Double(safeEntries.count)).rounded())) ?? .neutral
    }

    private var entryLabel: String {
        safeEntries.count == 1 ? "1 entry" : "\(safeEntries.count) entries"
    }

    private var accessibilityDescription: String {
        let date = day.formatted(date: .complete, time: .omitted)
        guard !safeEntries.isEmpty else { return "\(date), no entries" }
        let mood = averageMood.map { ", average mood \($0.label)" } ?? ""
        return "\(date), \(entryLabel)\(mood)"
    }

    var body: some View {
        let isToday = calendar.isDateInToday(day)
        let isFuture = calendar.startOfDay(for: day) > calendar.startOfDay(for: Date())
        let fillColor = isSelected
            ? theme.accentColor.opacity(0.22)
            : (averageMood?.color.opacity(0.17) ?? theme.cardColor.opacity(isFuture ? 0.16 : 0.38))

        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(calendar.component(.day, from: day))")
                        .font(OmegaTheme.font(.bodyLarge, isToday ? .bold : .semibold, design: .rounded))
                        .foregroundColor(isFuture ? theme.secondaryTextColor.opacity(0.55) : theme.titleTextColor)
                    Spacer(minLength: 4)
                    if !safeEntries.isEmpty {
                        Text("\(safeEntries.count)")
                            .font(OmegaTheme.font(.meta, .bold, design: .rounded))
                            .foregroundColor(theme.accentColor)
                    }
                }

                Spacer(minLength: 2)

                // Empty days stay quiet: the date number (dimmed for the future)
                // says enough, so the grid isn't a wall of "No entry" labels.
                // VoiceOver still announces "no entries" via the label below.
                if !safeEntries.isEmpty {
                    HStack(spacing: 5) {
                        if let mood = averageMood {
                            Circle()
                                .fill(mood.color)
                                .frame(width: 7, height: 7)
                        }
                        Text(entryLabel)
                            .font(OmegaTheme.font(.meta, .medium))
                            .foregroundColor(theme.secondaryTextColor)
                            .lineLimit(1)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 82, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(fillColor))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        isSelected ? theme.accentColor : (isToday ? theme.accentColor.opacity(0.58) : Color.clear),
                        lineWidth: isSelected ? 2 : 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .omegaTooltip(accessibilityDescription)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityHint("Select this day to inspect its entries")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Accessible entry row

/// Shared with Insights' day drill-down sheet.
struct CalendarEntryRow: View {
    let entry: JournalEntry
    let onOpen: () -> Void

    @ObservedObject private var theme = ThemeManager.shared
    @ObservedObject private var biometricAuth = BiometricAuth.shared

    private var isLockedPrivate: Bool {
        entry.isHidden && !biometricAuth.isAuthenticated
    }

    private var accessibilityDescription: String {
        if isLockedPrivate {
            return "Private calendar entry. Unlock to view."
        }
        return "\(entry.displayTitle), \(entry.mood.label) mood, \(entry.createdAt.formatted(date: .omitted, time: .shortened)), \(entry.wordCount) words"
    }

    var body: some View {
        Button(action: open) {
            Group {
                if isLockedPrivate {
                    lockedContent
                } else {
                    entryContent
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(theme.cardColor.opacity(0.42)))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(isLockedPrivate ? theme.accentColor.opacity(0.34) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityHint(isLockedPrivate ? "Authenticate to view this entry" : "Open this entry in Calendar")
    }

    private var entryContent: some View {
        HStack(spacing: 10) {
            Text(entry.mood.emoji)
                .font(OmegaTheme.font(.heading))
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    if entry.isHidden {
                        Image(systemName: "lock.open")
                            .font(OmegaTheme.font(.meta, .semibold))
                            .foregroundColor(theme.accentColor)
                            .accessibilityHidden(true)
                    }
                    Text(entry.displayTitle)
                        .font(OmegaTheme.font(.caption, .semibold))
                        .foregroundColor(theme.titleTextColor)
                        .lineLimit(1)
                }
                Text("\(entry.createdAt.formatted(date: .omitted, time: .shortened)) · \(entry.wordCount) words")
                    .font(OmegaTheme.font(.meta))
                    .foregroundColor(theme.secondaryTextColor)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(OmegaTheme.font(.meta, .semibold))
                .foregroundColor(theme.secondaryTextColor)
                .accessibilityHidden(true)
        }
    }

    private var lockedContent: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill")
                .font(OmegaTheme.font(.body, .semibold))
                .foregroundColor(theme.accentColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text("Private entry")
                    .font(OmegaTheme.font(.caption, .semibold))
                    .foregroundColor(theme.titleTextColor)
                Text("Unlock to view")
                    .font(OmegaTheme.font(.meta))
                    .foregroundColor(theme.secondaryTextColor)
            }
            Spacer()
            Image(systemName: "lock.open")
                .font(OmegaTheme.font(.meta, .semibold))
                .foregroundColor(theme.accentColor)
                .accessibilityHidden(true)
        }
    }

    private func open() {
        if isLockedPrivate {
            Task { @MainActor in
                guard await biometricAuth.authenticate() else { return }
                onOpen()
            }
        } else {
            onOpen()
        }
    }
}

// Entry drill-through now lives in the shared EntryDrillThrough.swift, so
// Calendar and Insights present identical reader/editor sheets.

