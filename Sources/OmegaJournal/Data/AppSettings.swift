import Foundation

/// Central registry of keys stored in the SQLite `settings` table. Keep new keys here
/// instead of scattering string literals. (View-only prefs backed by `@AppStorage` keep
/// their keys in `ShellPrefs` / `ReadingPreferences`.)
enum SettingKey {
    static let themeName = "themeName"
    static let accentColor = "accentColor"
    static let backgroundColor = "backgroundColor"
    static let sidebarColor = "sidebarColor"
    static let cardColor = "cardColor"
    static let reminderEnabled = "reminderEnabled"
    static let reminderHour = "reminderHour"
    static let reminderMinute = "reminderMinute"
    static let editorFontSize = "editorFontSize"
}

/// Typed accessors over the string-based `getSetting`/`setSetting` pair, so call sites
/// stop hand-rolling `"1"`/`"true"` and `Int(...) ?? default` parsing.
extension DatabaseManager {
    /// Accepts both `"true"` and `"1"` as true (older code used either spelling).
    func bool(_ key: String, default fallback: Bool = false) -> Bool {
        let raw = getSetting(key, defaultValue: "")
        if raw.isEmpty { return fallback }
        return raw == "true" || raw == "1"
    }

    @discardableResult
    func setBool(_ key: String, _ value: Bool, asDigit: Bool = false) -> Bool {
        setSetting(key, value: asDigit ? (value ? "1" : "0") : (value ? "true" : "false"))
    }

    func int(_ key: String, default fallback: Int) -> Int {
        Int(getSetting(key, defaultValue: "\(fallback)")) ?? fallback
    }

    @discardableResult
    func setInt(_ key: String, _ value: Int) -> Bool {
        setSetting(key, value: "\(value)")
    }
}
