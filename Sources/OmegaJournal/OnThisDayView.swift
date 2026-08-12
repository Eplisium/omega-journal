import SwiftUI

// MARK: - On This Day View

struct OnThisDayView: View {
    @ObservedObject var vm: JournalViewModel
    @ObservedObject private var theme = ThemeManager.shared
    @ObservedObject private var biometricAuth = BiometricAuth.shared

    private var thisDay: [JournalEntry] { vm.onThisDay }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundColor(.teal)
                        Text("On This Day")
                            .font(OmegaTheme.titleFont)
                    }
                    Text(todayFormatted)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }

                if thisDay.isEmpty {
                    emptyState
                } else {
                    // Entries from this day in past years
                    VStack(alignment: .leading, spacing: 16) {
                        Text("You wrote on this day in \(thisDay.count == 1 ? "a previous year" : "previous years"):")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.secondary)

                        ForEach(thisDay) { entry in
                            memoryCard(entry)
                        }
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(theme.backgroundColor)
    }

    private var todayFormatted: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        return formatter.string(from: Date())
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(Color.teal.opacity(0.12))
                    .frame(width: 90, height: 90)
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 36, weight: .light))
                    .foregroundColor(.teal.opacity(0.7))
            }
            VStack(spacing: 8) {
                Text("No memories for today yet")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.secondary)
                Text("Keep journaling and your past entries will appear here on their anniversaries.")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 40)
    }

    private func memoryCard(_ entry: JournalEntry) -> some View {
        let yearsAgo = Calendar.current.dateComponents([.year], from: entry.createdAt, to: Date()).year ?? 0

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text(entry.mood.emoji)
                    .font(.system(size: 32))
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title.isEmpty ? "Untitled" : entry.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.primary)
                    HStack(spacing: 6) {
                        Text("\(yearsAgo) \(yearsAgo == 1 ? "year" : "years") ago")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.teal)
                        Text("·")
                            .foregroundColor(.secondary.opacity(0.5))
                        Text(entry.createdAt.formatted(date: .long, time: .shortened))
                            .font(OmegaTheme.metaFont)
                            .foregroundColor(.secondary)
                        Text("·")
                            .foregroundColor(.secondary.opacity(0.5))
                        Text(entry.readingTime)
                            .font(OmegaTheme.metaFont)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
            }

            if !entry.tags.isEmpty && !(entry.isHidden && !biometricAuth.isAuthenticated) {
                HStack(spacing: 4) {
                    ForEach(entry.tags, id: \.self) { tag in
                        Text("#\(tag)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(theme.accentColor.opacity(0.85))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(theme.accentColor.opacity(0.10))
                            .clipShape(Capsule())
                    }
                }
            }

            Text(entry.isHidden && !biometricAuth.isAuthenticated ? "Hidden · unlock to read" : entry.preview)
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .lineLimit(4)
                .lineSpacing(3)
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: OmegaTheme.cardRadius)
                .fill(theme.cardColor.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: OmegaTheme.cardRadius)
                .strokeBorder(Color.teal.opacity(0.2), lineWidth: 1)
        )
        .onTapGesture { vm.selectedEntryId = entry.id }
    }
}
