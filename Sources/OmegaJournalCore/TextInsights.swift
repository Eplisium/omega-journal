import Foundation
import NaturalLanguage

// MARK: - On-device text analysis (NaturalLanguage only — nothing leaves the Mac)

public struct KeywordCount: Equatable, Sendable {
    public let word: String
    public let count: Int
}

public enum TextInsights {
    /// Common words that survive lemmatisation but carry no theme.
    static let stopwords: Set<String> = [
        "the", "and", "but", "for", "with", "that", "this", "have", "has", "had", "was", "were", "are", "been",
        "just", "like", "got", "get", "going", "went", "today", "really", "very", "much", "some", "will", "would",
        "could", "should", "about", "into", "from", "they", "them", "their", "then", "than", "when", "what",
        "which", "while", "also", "feel", "felt", "still", "even", "over", "back", "make", "made", "thing",
        "things", "didn", "don", "isn", "wasn", "can", "not", "you", "your", "our", "out", "all", "one", "day",
        "time", "lot", "bit", "little", "know", "think", "want", "need", "way"
    ]

    /// Top nouns/names/verbs-as-lemmas across the given bodies, by frequency.
    /// Uses NLTagger lexical classes + lemmas; falls back to simple tokenising.
    public static func topKeywords(in texts: [String], limit: Int = 20, minLength: Int = 4) -> [KeywordCount] {
        var counts: [String: Int] = [:]
        for text in texts where !text.isEmpty {
            let sample = String(text.prefix(20_000))
            let tagger = NLTagger(tagSchemes: [.lexicalClass, .lemma])
            tagger.string = sample
            tagger.enumerateTags(in: sample.startIndex..<sample.endIndex, unit: .word, scheme: .lexicalClass,
                                 options: [.omitWhitespace, .omitPunctuation, .omitOther, .joinNames]) { tag, range in
                guard let tag, tag == .noun || tag == .personalName || tag == .placeName || tag == .organizationName else { return true }
                let surface = String(sample[range])
                var word = surface.lowercased()
                if let lemma = tagger.tag(at: range.lowerBound, unit: .word, scheme: .lemma).0?.rawValue, !lemma.isEmpty {
                    word = lemma.lowercased()
                }
                guard word.count >= minLength, !stopwords.contains(word),
                      word.rangeOfCharacter(from: .letters) != nil else { return true }
                counts[word, default: 0] += 1
                return true
            }
        }
        return counts.map { KeywordCount(word: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.word < $1.word }
            .prefix(limit).map { $0 }
    }

    /// NLTagger sentiment of a text in -1…1 (nil when empty or unscored).
    public static func sentiment(of text: String) -> Double? {
        let sample = String(text.prefix(6_000)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sample.isEmpty else { return nil }
        let tagger = NLTagger(tagSchemes: [.sentimentScore])
        tagger.string = sample
        let (tag, _) = tagger.tag(at: sample.startIndex, unit: .paragraph, scheme: .sentimentScore)
        guard let raw = tag?.rawValue, let v = Double(raw) else { return nil }
        return max(-1, min(1, v))
    }

    public enum SentimentBand: String, Sendable { case negative, neutral, positive }

    public static func band(_ score: Double) -> SentimentBand {
        score <= -0.25 ? .negative : (score >= 0.25 ? .positive : .neutral)
    }
}
