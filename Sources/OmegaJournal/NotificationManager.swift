import Foundation
import UserNotifications

// MARK: - Notification Manager

@MainActor
final class NotificationManager: ObservableObject {
    static let shared = NotificationManager()

    @Published var isAuthorized = false
    @Published var reminderEnabled = false
    @Published var reminderHour = 20
    @Published var reminderMinute = 0

    private let db = DatabaseManager.shared

    private init() {
        reminderEnabled = db.getSetting("reminderEnabled", defaultValue: "false") == "true"
        reminderHour = Int(db.getSetting("reminderHour", defaultValue: "20")) ?? 20
        reminderMinute = Int(db.getSetting("reminderMinute", defaultValue: "0")) ?? 0
        checkAuthorization()
    }

    func checkAuthorization() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                self.isAuthorized = settings.authorizationStatus == .authorized
            }
        }
    }

    func requestPermission() {
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

    func scheduleReminder() {
        let content = UNMutableNotificationContent()
        content.title = "Time to journal ✍️"
        content.body = PromptGenerator.random()
        content.sound = .default

        var dateComponents = DateComponents()
        dateComponents.hour = reminderHour
        dateComponents.minute = reminderMinute

        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
        let request = UNNotificationRequest(identifier: "dailyJournalReminder", content: content, trigger: trigger)

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Failed to schedule reminder: \(error)")
            }
        }
    }

    func cancelReminder() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["dailyJournalReminder"])
    }

    func testNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Omega Journal"
        content.body = "Your daily writing reminder is set! ✍️"
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 3, repeats: false)
        let request = UNNotificationRequest(identifier: "testReminder", content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }
}
