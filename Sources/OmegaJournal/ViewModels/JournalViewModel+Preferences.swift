import Foundation

/// Persisted editor preferences exposed to views, so views never touch the database directly.
extension JournalViewModel {
    var editorFontSize: Double {
        get { Double(db.getSetting(SettingKey.editorFontSize, defaultValue: "15")) ?? 15 }
        set { db.setInt(SettingKey.editorFontSize, Int(newValue)) }
    }
}
