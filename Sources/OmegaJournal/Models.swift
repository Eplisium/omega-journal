import Foundation
import SwiftUI

// MARK: - Theme Manager

@MainActor
final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    @Published var accentColor: Color
    @Published var backgroundColor: Color
    @Published var sidebarColor: Color
    @Published var cardColor: Color
    @Published var titleTextColor: Color
    @Published var bodyTextColor: Color
    @Published var secondaryTextColor: Color
    @Published var themeName: String

    // Light-on-dark text for all overlay UI
    private init() {
        let db = DatabaseManager.shared
        let name = db.getSetting("themeName", defaultValue: "Purple")
        let accentHex = db.getSetting("accentColor", defaultValue: "#9d6bff")
        let bgHex = db.getSetting("backgroundColor", defaultValue: "#1a0d2e")
        let sidebarHex = db.getSetting("sidebarColor", defaultValue: "#140823")
        let cardHex = db.getSetting("cardColor", defaultValue: "#241245")
        themeName = name
        accentColor = Color(hex: accentHex) ?? Color(hex: "#9d6bff")!
        backgroundColor = Color(hex: bgHex) ?? Color(hex: "#1a0d2e")!
        sidebarColor = Color(hex: sidebarHex) ?? Color(hex: "#140823")!
        cardColor = Color(hex: cardHex) ?? Color(hex: "#241245")!
        titleTextColor = .white
        bodyTextColor = Color.white.opacity(0.9)
        secondaryTextColor = Color.white.opacity(0.55)
    }

    func applyTheme(named name: String) {
        guard let preset = ThemePresets.all[name] else { return }
        themeName = name
        accentColor = preset.accent
        backgroundColor = preset.background
        sidebarColor = preset.sidebar
        cardColor = preset.card
        persist()
    }

    func applyCustom(accent: Color, background: Color, sidebar: Color, card: Color) {
        themeName = "Custom"
        accentColor = accent
        backgroundColor = background
        sidebarColor = sidebar
        cardColor = card
        persist()
    }

    private func persist() {
        let db = DatabaseManager.shared
        db.setSetting("themeName", value: themeName)
        db.setSetting("accentColor", value: accentColor.toHex())
        db.setSetting("backgroundColor", value: backgroundColor.toHex())
        db.setSetting("sidebarColor", value: sidebarColor.toHex())
        db.setSetting("cardColor", value: cardColor.toHex())
    }
}

// MARK: - Theme Presets

struct ThemePreset {
    let name: String
    let accent: Color
    let background: Color
    let sidebar: Color
    let card: Color
    let swatchColors: [Color]
}

enum ThemePresets {
    static let all: [String: ThemePreset] = [
        "Purple": ThemePreset(
            name: "Purple",
            accent: Color(hex: "#9d6bff")!,
            background: Color(hex: "#1a0d2e")!,
            sidebar: Color(hex: "#140823")!,
            card: Color(hex: "#241245")!,
            swatchColors: [Color(hex: "#9d6bff")!, Color(hex: "#1a0d2e")!]
        ),
        "Midnight": ThemePreset(
            name: "Midnight",
            accent: Color(hex: "#4a9eff")!,
            background: Color(hex: "#0a0e1a")!,
            sidebar: Color(hex: "#060912")!,
            card: Color(hex: "#121828")!,
            swatchColors: [Color(hex: "#4a9eff")!, Color(hex: "#0a0e1a")!]
        ),
        "Forest": ThemePreset(
            name: "Forest",
            accent: Color(hex: "#4ec9a0")!,
            background: Color(hex: "#0a1e16")!,
            sidebar: Color(hex: "#06140e")!,
            card: Color(hex: "#102a1f")!,
            swatchColors: [Color(hex: "#4ec9a0")!, Color(hex: "#0a1e16")!]
        ),
        "Sunset": ThemePreset(
            name: "Sunset",
            accent: Color(hex: "#ff7e5f")!,
            background: Color(hex: "#1f0d12")!,
            sidebar: Color(hex: "#17080c")!,
            card: Color(hex: "#2e1620")!,
            swatchColors: [Color(hex: "#ff7e5f")!, Color(hex: "#1f0d12")!]
        ),
        "Rose": ThemePreset(
            name: "Rose",
            accent: Color(hex: "#e056a0")!,
            background: Color(hex: "#1c0a1a")!,
            sidebar: Color(hex: "#15050f")!,
            card: Color(hex: "#281030")!,
            swatchColors: [Color(hex: "#e056a0")!, Color(hex: "#1c0a1a")!]
        ),
        "Graphite": ThemePreset(
            name: "Graphite",
            accent: Color(hex: "#8899aa")!,
            background: Color(hex: "#161618")!,
            sidebar: Color(hex: "#0e0e10")!,
            card: Color(hex: "#202024")!,
            swatchColors: [Color(hex: "#8899aa")!, Color(hex: "#161618")!]
        ),
    ]
}

// MARK: - Color Hex Extensions

extension Color {
    init?(hex: String) {
        var hex = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6 || hex.count == 8 else { return nil }
        let r, g, b, a: Double
        guard let hexNum = UInt64(hex, radix: 16) else { return nil }
        if hex.count == 6 {
            r = Double((hexNum >> 16) & 0xFF) / 255.0
            g = Double((hexNum >> 8) & 0xFF) / 255.0
            b = Double(hexNum & 0xFF) / 255.0
            a = 1.0
        } else {
            r = Double((hexNum >> 24) & 0xFF) / 255.0
            g = Double((hexNum >> 16) & 0xFF) / 255.0
            b = Double((hexNum >> 8) & 0xFF) / 255.0
            a = Double(hexNum & 0xFF) / 255.0
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    func toHex() -> String {
        let nsColor = NSColor(self).usingColorSpace(.sRGB) ?? NSColor.gray
        let r = Int(round(nsColor.redComponent * 255))
        let g = Int(round(nsColor.greenComponent * 255))
        let b = Int(round(nsColor.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

// MARK: - Mood

enum Mood: Int, CaseIterable, Identifiable {
    case awful = 1, bad = 2, neutral = 3, good = 4, great = 5
    var id: Int { rawValue }

    var label: String {
        switch self {
        case .awful: "Awful"; case .bad: "Bad"; case .neutral: "Neutral"
        case .good: "Good"; case .great: "Great"
        }
    }
    var emoji: String {
        switch self {
        case .awful: "😞"; case .bad: "😕"; case .neutral: "😐"
        case .good: "🙂"; case .great: "😄"
        }
    }
    var color: Color {
        switch self {
        case .awful: Color(red: 0.85, green: 0.35, blue: 0.35)
        case .bad: Color(red: 0.90, green: 0.60, blue: 0.30)
        case .neutral: Color(red: 0.55, green: 0.55, blue: 0.60)
        case .good: Color(red: 0.30, green: 0.75, blue: 0.55)
        case .great: Color(red: 0.20, green: 0.60, blue: 0.90)
        }
    }
}

// MARK: - Chart Data

struct MoodPoint: Identifiable {
    let date: Date
    let avg: Double
    var id: Date { date }
}

struct MoodCount: Identifiable {
    let mood: Mood
    let count: Int
    var id: Int { mood.rawValue }
}

// MARK: - Sort Order

enum SortOrder: String, CaseIterable, Identifiable {
    case dateDesc = "Newest First"
    case dateAsc = "Oldest First"
    case titleAsc = "Title A→Z"
    case titleDesc = "Title Z→A"
    var id: String { rawValue }
}

// MARK: - Journal Entry

struct JournalEntry: Identifiable, Hashable {
    let id: String
    var title: String
    var body: String
    var mood: Mood
    var tags: [String]
    var createdAt: Date
    var updatedAt: Date
    var isPinned: Bool
    var isFavorite: Bool

    static func new() -> JournalEntry {
        JournalEntry(id: UUID().uuidString, title: "", body: "", mood: .neutral,
                     tags: [], createdAt: Date(), updatedAt: Date(),
                     isPinned: false, isFavorite: false)
    }

    var wordCount: Int { body.isEmpty ? 0 : body.split(whereSeparator: { $0.isWhitespace }).count }
    var readingTime: String {
        let minutes = max(1, Int(ceil(Double(wordCount) / 220.0)))
        return minutes == 1 ? "1 min read" : "\(minutes) min read"
    }
    var preview: String {
        let s = body.replacingOccurrences(of: "\\n+", with: " ", options: .regularExpression)
        return s.isEmpty ? "No content" : s
    }
}

// MARK: - Daily Prompt

enum PromptGenerator {
    private static let prompts: [String] = [
        "What are you grateful for today?",
        "Describe a small moment that made you smile.",
        "What's been on your mind lately?",
        "Write about something you're looking forward to.",
        "What did you learn today?",
        "Describe your perfect day.",
        "What's a challenge you're facing right now?",
        "Write a letter to your future self.",
        "What made you feel proud recently?",
        "What would you tell your past self?",
        "Describe a place that makes you feel calm.",
        "What's one thing you'd change about your routine?",
        "Who inspires you, and why?",
        "What's a memory you never want to forget?",
        "What does self-care look like for you?",
        "Describe a goal and the first step toward it.",
        "What's something you've been avoiding?",
        "What made you laugh today?",
        "What's a habit you want to build?",
        "What does a good day look like to you?",
        "What's something you're curious about?",
        "Describe a person who changed your life.",
        "What's weighing on your heart today?",
        "What's a win you're celebrating?",
        "If you had an extra hour today, what would you do?",
        "What are your top three priorities right now?",
        "What's a fear you want to overcome?",
        "Describe a recent adventure, big or small.",
        "What brings you peace?",
        "What's something new you tried recently?",
        "What's a kindness someone showed you?",
        "What do you want more of in your life?",
        "What's a boundary you need to set?",
        "Describe your ideal weekend.",
        "What's a dream you're nurturing?",
        "What does success mean to you?",
        "What's something you forgive yourself for?",
        "Describe a favorite smell and the memory it brings.",
        "What's a risk worth taking?",
        "What would make today count?"
    ]

    static func today() -> String {
        let day = Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 1
        return prompts[(day - 1) % prompts.count]
    }
}

// MARK: - View Model

@MainActor
final class JournalViewModel: ObservableObject {
    @Published var entries: [JournalEntry] = []
    @Published var selectedEntryId: String?
    @Published var searchText: String = ""
    @Published var sortOrder: SortOrder = .dateDesc
    @Published var editingEntryId: String?

    private let db = DatabaseManager.shared
    private var debounceTask: Task<Void, Never>?

    init() { reload() }
    func reload() { entries = db.fetchAllEntries(search: searchText, sort: sortOrder) }
    var selectedEntry: JournalEntry? { entries.first { $0.id == selectedEntryId } }
    var editingEntry: JournalEntry? { entries.first { $0.id == editingEntryId } }
    var isEditing: Bool { editingEntryId != nil }
    var entryCount: Int { db.entryCount() }

    func createEntry() {
        let entry = JournalEntry.new()
        db.saveEntry(entry)
        reload()
        selectedEntryId = entry.id
        editingEntryId = entry.id
    }

    func startEditing(_ entry: JournalEntry) { editingEntryId = entry.id }

    func autoSave(_ entry: JournalEntry) {
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            var u = entry; u.updatedAt = Date()
            db.saveEntry(u); reload()
        }
    }

    func stopEditing() {
        if let e = editingEntry, e.title.isEmpty && e.body.isEmpty {
            db.deleteEntry(id: e.id)
            if selectedEntryId == e.id { selectedEntryId = nil }
        }
        editingEntryId = nil
        reload()
    }

    func deleteEntry(_ entry: JournalEntry) {
        db.deleteEntry(id: entry.id)
        if selectedEntryId == entry.id { selectedEntryId = nil }
        if editingEntryId == entry.id { editingEntryId = nil }
        reload()
    }

    func togglePin(_ entry: JournalEntry) {
        var u = entry; u.isPinned.toggle(); u.updatedAt = Date()
        db.saveEntry(u); reload()
    }

    func toggleFavorite(_ entry: JournalEntry) {
        var u = entry; u.isFavorite.toggle(); u.updatedAt = Date()
        db.saveEntry(u); reload()
    }

    // Stats
    var moodThisWeek: [Mood: Int] {
        let w = Date().addingTimeInterval(-7 * 24 * 3600)
        var c: [Mood: Int] = [:]
        for e in entries where e.createdAt >= w { c[e.mood, default: 0] += 1 }
        return c
    }
    var totalWordCount: Int { entries.reduce(0) { $0 + $1.wordCount } }
    var averageMood: Double { entries.isEmpty ? 0 : Double(entries.reduce(0) { $0 + $1.mood.rawValue }) / Double(entries.count) }
    var entriesThisWeek: Int { entries.filter { $0.createdAt >= Date().addingTimeInterval(-7 * 24 * 3600) }.count }
    var writingStreak: Int {
        let cal = Calendar.current
        var streak = 0; var date = cal.startOfDay(for: Date())
        while true {
            let end = cal.date(byAdding: .day, value: 1, to: date)!
            if entries.contains(where: { $0.createdAt >= date && $0.createdAt < end }) {
                streak += 1; date = cal.date(byAdding: .day, value: -1, to: date)!
            } else { break }
        }
        return streak
    }

    // MARK: - Insights

    /// Average mood per day for the last `days` days (only days with entries).
    func moodTrend(days: Int = 30) -> [MoodPoint] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var points: [MoodPoint] = []
        for i in stride(from: days - 1, through: 0, by: -1) {
            guard let day = cal.date(byAdding: .day, value: -i, to: today),
                  let end = cal.date(byAdding: .day, value: 1, to: day) else { continue }
            let dayEntries = entries.filter { $0.createdAt >= day && $0.createdAt < end }
            guard !dayEntries.isEmpty else { continue }
            let avg = Double(dayEntries.reduce(0) { $0 + $1.mood.rawValue }) / Double(dayEntries.count)
            points.append(MoodPoint(date: day, avg: avg))
        }
        return points
    }

    /// Entry counts keyed by day for the last `daysBack` days (for the heatmap).
    func dailyCounts(daysBack: Int = 210) -> [Date: Int] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let start = cal.date(byAdding: .day, value: -(daysBack - 1), to: today) else { return [:] }
        var map: [Date: Int] = [:]
        for e in entries where e.createdAt >= start {
            map[cal.startOfDay(for: e.createdAt), default: 0] += 1
        }
        return map
    }

    var moodDistribution: [MoodCount] {
        Mood.allCases
            .map { m in MoodCount(mood: m, count: entries.filter { $0.mood == m }.count) }
            .sorted { $0.mood.rawValue < $1.mood.rawValue }
    }

    var entriesThisMonth: Int {
        let cal = Calendar.current
        guard let start = cal.dateInterval(of: .month, for: Date())?.start else { return 0 }
        return entries.filter { $0.createdAt >= start }.count
    }

    var longestStreak: Int {
        let cal = Calendar.current
        let days = Set(entries.map { cal.startOfDay(for: $0.createdAt) })
        guard !days.isEmpty else { return 0 }
        let sorted = days.sorted()
        var best = 1, cur = 1
        for i in 1..<sorted.count {
            if let next = cal.date(byAdding: .day, value: 1, to: sorted[i - 1]), next == sorted[i] {
                cur += 1; best = max(best, cur)
            } else { cur = 1 }
        }
        return best
    }

    var totalReadingTime: String {
        let total = entries.reduce(0) { $0 + max(1, Int(ceil(Double($1.wordCount) / 220.0))) }
        if total < 60 { return "\(total) min" }
        return "\(total / 60)h \(total % 60)m"
    }

    /// Entries written on this month/day in any previous year.
    var onThisDay: [JournalEntry] {
        let cal = Calendar.current
        let today = Date()
        let month = cal.component(.month, from: today)
        let day = cal.component(.day, from: today)
        let thisYear = cal.component(.year, from: today)
        return entries.filter { e in
            let eYear = cal.component(.year, from: e.createdAt)
            return eYear != thisYear &&
                cal.component(.month, from: e.createdAt) == month &&
                cal.component(.day, from: e.createdAt) == day
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    func createEntryFromPrompt() {
        let entry = JournalEntry(
            id: UUID().uuidString,
            title: "Today: " + PromptGenerator.today(),
            body: "", mood: .neutral, tags: ["prompt"],
            createdAt: Date(), updatedAt: Date(), isPinned: false, isFavorite: false
        )
        db.saveEntry(entry)
        reload()
        selectedEntryId = entry.id
        editingEntryId = entry.id
    }
}
