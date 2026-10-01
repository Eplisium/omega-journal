import SwiftUI
import OmegaJournalCore

// MARK: - Weekly / monthly review card

/// One-click review generation + schedule controls. Used in Reflection surfaces and Settings.
struct ReviewCard: View {
    @ObservedObject var vm: JournalViewModel
    @ObservedObject private var notifications = NotificationManager.shared
    @ObservedObject private var theme = ThemeManager.shared
    @State private var period: ReviewPeriod = .week

    var body: some View {
        OmegaCard {
            VStack(alignment: .leading, spacing: OmegaTheme.Spacing.m) {
                OmegaSectionHeader(title: "Review", subtitle: "Look back and save it as an entry", systemImage: "arrow.counterclockwise.circle")
                Picker("Period", selection: $period) {
                    ForEach(ReviewPeriod.allCases) { Text($0 == .week ? "This week" : "This month").tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                let draft = vm.reviewDraft(period)
                Text(draft.entryCount == 0 ? "Nothing written yet this \(period == .week ? "week" : "month")." : "\(draft.entryCount) \(draft.entryCount == 1 ? "entry" : "entries") ready to summarise.")
                    .font(OmegaTheme.captionFont).foregroundColor(theme.secondaryTextColor)
                HStack {
                    Button { vm.saveReviewAsEntry(period) } label: { Label("Save as entry", systemImage: "square.and.arrow.down") }
                        .disabled(draft.entryCount == 0)
                    Spacer()
                }
            }
        }
    }
}

/// Settings controls for scheduled review reminders.
struct ReviewScheduleControls: View {
    @ObservedObject private var notifications = NotificationManager.shared
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        let s = notifications.reviewSchedule
        VStack(alignment: .leading, spacing: OmegaTheme.Spacing.m) {
            Toggle("Weekly review reminder", isOn: bind(\.weeklyEnabled))
            if s.weeklyEnabled {
                Picker("Day", selection: bind(\.weeklyWeekday)) {
                    ForEach(1...7, id: \.self) { Text(Calendar.current.weekdaySymbols[$0 - 1]).tag($0) }
                }
            }
            Toggle("Monthly review reminder", isOn: bind(\.monthlyEnabled))
            if s.monthlyEnabled {
                Picker("Day of month", selection: bind(\.monthlyDay)) {
                    ForEach(1...28, id: \.self) { Text("\($0)").tag($0) }
                }
            }
            if s.weeklyEnabled || s.monthlyEnabled {
                Picker("Hour", selection: bind(\.hour)) {
                    ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
                }
                if !notifications.isAuthorized {
                    Button("Allow notifications") { notifications.requestPermission() }
                }
            }
        }
        .font(OmegaTheme.bodyFont)
    }

    private func bind<V>(_ key: WritableKeyPath<ReviewSchedule, V>) -> Binding<V> {
        Binding(get: { notifications.reviewSchedule[keyPath: key] },
                set: { v in var s = notifications.reviewSchedule; s[keyPath: key] = v; notifications.setReviewSchedule(s) })
    }
}
