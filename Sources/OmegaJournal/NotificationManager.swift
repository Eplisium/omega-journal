import Foundation
import AppKit
import UserNotifications

// MARK: - Foreground presentation

/// Without a delegate macOS suppresses notifications while the app is frontmost.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

// MARK: - Notification Manager

@MainActor
final class NotificationManager: ObservableObject {
    static let shared = NotificationManager()

    @Published var isAuthorized = false
    @Published var reminderEnabled = false
    @Published var reminderHour = 20
    @Published var reminderMinute = 0

    private let db = DatabaseManager.shared
    private let presenter = NotificationPresenter()

    /// How many upcoming one-shot reminders are kept scheduled. Each carries a
    /// different prompt; the set is topped up every launch/activation.
    nonisolated static let upcomingReminderCount = 14
    nonisolated static let requestIdentifierPrefix = "dailyJournalReminder-"
    private static let legacyIdentifier = "dailyJournalReminder"

    /// UNUserNotificationCenter traps outside a real app bundle (e.g. `swift test`).
    private static var centerAvailable: Bool { Bundle.main.bundlePath.hasSuffix(".app") }

    private init() {
        reminderEnabled = db.getSetting("reminderEnabled", defaultValue: "false") == "true"
        reminderHour = Int(db.getSetting("reminderHour", defaultValue: "20")) ?? 20
        reminderMinute = Int(db.getSetting("reminderMinute", defaultValue: "0")) ?? 0
        guard Self.centerAvailable else { return }
        UNUserNotificationCenter.current().delegate = presenter
        checkAuthorization()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshScheduleIfNeeded() }
        }
    }

    func checkAuthorization() {
        guard Self.centerAvailable else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                self.isAuthorized = settings.authorizationStatus == .authorized
                self.refreshScheduleIfNeeded()
            }
        }
    }

    func requestPermission() {
        guard Self.centerAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
            DispatchQueue.main.async {
                self.isAuthorized = granted
                if granted && self.reminderEnabled {
                    self.scheduleReminder()
                }
            }
        }
    }

    func setReminder(enabled: Bool, hour: Int? = nil, minute: Int? = nil) {
        reminderEnabled = enabled
        if let h = hour { reminderHour = h }
        if let m = minute { reminderMinute = m }

        db.setSetting("reminderEnabled", value: enabled ? "true" : "false")
        db.setSetting("reminderHour", value: "\(reminderHour)")
        db.setSetting("reminderMinute", value: "\(reminderMinute)")

        if enabled && isAuthorized {
            scheduleReminder()
        } else {
            cancelReminder()
        }
    }

    /// Re-tops-up the rolling window (the one-shot requests expire day by day).
    func refreshScheduleIfNeeded() {
        if reminderEnabled && isAuthorized { scheduleReminder() }
    }

    /// Pure: the next `count` occurrences of hour:minute strictly after `now`,
    /// as year/month/day/hour/minute components for one-shot triggers.
    nonisolated static func upcomingReminderComponents(
        after now: Date, hour: Int, minute: Int,
        count: Int = NotificationManager.upcomingReminderCount,
        calendar: Calendar = .current
    ) -> [DateComponents] {
        var result: [DateComponents] = []
        var day = calendar.startOfDay(for: now)
        while result.count < count {
            if let fire = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day), fire > now {
                result.append(calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fire))
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return result
    }

    /// Pure: builds the request set with a distinct prompt per request.
    nonisolated static func buildReminderRequests(
        after now: Date, hour: Int, minute: Int,
        prompt: () -> String = { PromptGenerator.random() },
        calendar: Calendar = .current
    ) -> [UNNotificationRequest] {
        var used = Set<String>()
        return upcomingReminderComponents(after: now, hour: hour, minute: minute, calendar: calendar)
            .enumerated().map { index, components in
                var body = prompt()
                var attempts = 0
                while used.contains(body) && attempts < 10 { body = prompt(); attempts += 1 }
                used.insert(body)
                let content = UNMutableNotificationContent()
                content.title = "Time to journal ✍️"
                content.body = body
                content.sound = .default
                let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                return UNNotificationRequest(
                    identifier: "\(requestIdentifierPrefix)\(index)", content: content, trigger: trigger)
            }
    }

    func scheduleReminder() {
        guard Self.centerAvailable else { return }
        let center = UNUserNotificationCenter.current()
        cancelReminder()
        for request in Self.buildReminderRequests(after: Date(), hour: reminderHour, minute: reminderMinute) {
            center.add(request) { error in
                if let error = error { print("Failed to schedule reminder: \(error)") }
            }
        }
    }

    func cancelReminder() {
        guard Self.centerAvailable else { return }
        let ids = [Self.legacyIdentifier]
            + (0..<Self.upcomingReminderCount).map { "\(Self.requestIdentifierPrefix)\($0)" }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }

    func testNotification() {
        guard Self.centerAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = "Omega Journal"
        content.body = "Your daily writing reminder is set! ✍️"
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 3, repeats: false)
        let request = UNNotificationRequest(identifier: "testReminder", content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }
}
