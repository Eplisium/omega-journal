import Combine
import Foundation
import SwiftUI
import AppKit
import OmegaJournalCore

extension JournalViewModel {
    // MARK: - Insights

    var analyticsEntryCount: Int { scopedAnalyticsEntries.count }
    var analyticsWordCount: Int { scopedAnalyticsEntries.reduce(0) { $0 + $1.wordCount } }
    var analyticsWritingDays: Int {
        Set(scopedAnalyticsEntries.map { Calendar.current.startOfDay(for: $0.createdAt) }).count
    }
    var analyticsAverageMood: Double? {
        guard !scopedAnalyticsEntries.isEmpty else { return nil }
        return Double(scopedAnalyticsEntries.reduce(0) { $0 + $1.mood.rawValue }) / Double(scopedAnalyticsEntries.count)
    }

    func wordsPerDay(for source: [JournalEntry], period: AnalyticsPeriod) -> [WordPoint] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let start = period.startDate(relativeTo: today, calendar: cal)
            ?? source.map(\.createdAt).min().map(cal.startOfDay(for:))
            ?? today
        var map: [Date: Int] = [:]
        for entry in source {
            map[cal.startOfDay(for: entry.createdAt), default: 0] += entry.wordCount
        }
        var points: [WordPoint] = []
        var cursor = start
        while cursor <= today {
            points.append(WordPoint(date: cursor, words: map[cursor] ?? 0))
            guard let next = cal.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return points
    }

    func moodTrend(for source: [JournalEntry]) -> [MoodPoint] {
        let cal = Calendar.current
        var grouped: [Date: [JournalEntry]] = [:]
        for entry in source {
            grouped[cal.startOfDay(for: entry.createdAt), default: []].append(entry)
        }
        return grouped
            .map { day, entries in
                MoodPoint(
                    date: day,
                    avg: Double(entries.reduce(0) { $0 + $1.mood.rawValue }) / Double(entries.count)
                )
            }
            .sorted { $0.date < $1.date }
    }

    func moodDistribution(for source: [JournalEntry]) -> [MoodCount] {
        Mood.allCases
            .map { mood in MoodCount(mood: mood, count: source.filter { $0.mood == mood }.count) }
            .sorted { $0.mood.rawValue < $1.mood.rawValue }
    }

    func entriesByDay(for source: [JournalEntry]) -> [Date: [JournalEntry]] {
        let cal = Calendar.current
        var map: [Date: [JournalEntry]] = [:]
        for entry in source {
            map[cal.startOfDay(for: entry.createdAt), default: []].append(entry)
        }
        return map
    }

    func dailyInfo(for source: [JournalEntry]) -> [Date: DayInfo] {
        let grouped = entriesByDay(for: source)
        var result: [Date: DayInfo] = [:]
        for (date, entries) in grouped {
            let sortedEntries = entries.sorted { $0.createdAt > $1.createdAt }
            result[date] = DayInfo(
                date: date,
                count: sortedEntries.count,
                moods: sortedEntries.map(\.mood),
                titles: sortedEntries.prefix(3).map(\.displayTitle)
            )
        }
        return result
    }

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

    struct DayInfo {
        let date: Date
        let count: Int
        let moods: [Mood]
        let titles: [String]
    }

    func dailyInfo(daysBack: Int = 210) -> [Date: DayInfo] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let start = cal.date(byAdding: .day, value: -(daysBack - 1), to: today) else { return [:] }
        var map: [Date: [JournalEntry]] = [:]
        for e in entries where e.createdAt >= start {
            map[cal.startOfDay(for: e.createdAt), default: []].append(e)
        }
        var result: [Date: DayInfo] = [:]
        for (date, dayEntries) in map {
            result[date] = DayInfo(
                date: date,
                count: dayEntries.count,
                moods: dayEntries.map(\.mood),
                titles: dayEntries.prefix(3).map(\.displayTitle)
            )
        }
        return result
    }

    var moodDistribution: [MoodCount] {
        Mood.allCases
            .map { m in MoodCount(mood: m, count: entries.filter { $0.mood == m }.count) }
            .sorted { $0.mood.rawValue < $1.mood.rawValue }
    }

    /// Entries bucketed by calendar day — powers the calendar month browser.
    func entriesByDay() -> [Date: [JournalEntry]] {
        let cal = Calendar.current
        var map: [Date: [JournalEntry]] = [:]
        for e in entries { map[cal.startOfDay(for: e.createdAt), default: []].append(e) }
        return map
    }

    // MARK: - On This Day

    /// Entries written on this month/day in any previous year.
    var onThisDay: [JournalEntry] {
        onThisDay(in: entries)
    }

    /// The privacy-aware memory surface used by Today and reflection pages.
    var reflectiveOnThisDay: [JournalEntry] {
        onThisDay(in: calendarEntries)
    }

    func onThisDay(in source: [JournalEntry]) -> [JournalEntry] {
        let cal = Calendar.current
        let today = Date()
        let month = cal.component(.month, from: today)
        let day = cal.component(.day, from: today)
        let thisYear = cal.component(.year, from: today)
        return source.filter { e in
            let eYear = cal.component(.year, from: e.createdAt)
            return eYear != thisYear &&
                cal.component(.month, from: e.createdAt) == month &&
                cal.component(.day, from: e.createdAt) == day
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - Attachments

    func addAttachment(to entry: JournalEntry, data: Data, filename: String, mimeType: String) {
        guard let attachment = db.saveAttachment(entryId: entry.id, data: data, filename: filename, mimeType: mimeType) else {
            showToast("Couldn't attach \(filename)", isError: true)
            return
        }
        if let idx = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[idx].attachments.append(attachment)
        }
        showToast("Attached \(filename)")
    }

    func deleteAttachment(_ attachment: Attachment) {
        db.deleteAttachment(id: attachment.id)
        for (i, entry) in entries.enumerated() {
            entries[i].attachments = entry.attachments.filter { $0.id != attachment.id }
        }
    }
}
