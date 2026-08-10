import Foundation
import SwiftUI

// MARK: - Mood

enum Mood: Int, CaseIterable, Identifiable, Codable {
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
