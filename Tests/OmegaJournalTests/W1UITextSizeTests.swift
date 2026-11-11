import Foundation
import Testing
@testable import OmegaJournal
import OmegaJournalCore

@Suite("W1UI: app-wide text size")
struct W1UITextSizeTests {
    @Test("Default leaves every base size unchanged; meta stays at 11 pt")
    func defaultIsIdentity() {
        for base in [11.0, 12, 13, 15, 17, 22, 32] {
            #expect(UITextSize.standard.scaled(base) == base)
        }
        #expect(UITextSize.standard.scaled(11) >= 11)
    }

    @Test("sizes grow monotonically from Small to Extra large")
    func monotonic() {
        let order: [UITextSize] = [.small, .standard, .large, .extraLarge]
        #expect(UITextSize.allCases == order)
        for base in [12.0, 13, 15, 17, 22, 32] {
            let sizes = order.map { $0.scaled(base) }
            #expect(sizes == sizes.sorted(), "\(base): \(sizes)")
            #expect(sizes.first! < sizes.last!)
        }
    }

    @Test("exact mapping, rounded to half points")
    func mapping() {
        #expect(UITextSize.large.scaled(13) == 14.5)      // 14.56
        #expect(UITextSize.extraLarge.scaled(13) == 16.5) // 16.25 → 16.5
        #expect(UITextSize.small.scaled(15) == 14)        // 13.8
        #expect(UITextSize.extraLarge.scaled(32) == 40)
        for size in UITextSize.allCases {
            for base in [11.0, 12, 13, 15, 17, 22, 32] {
                let v = size.scaled(base)
                #expect((v * 2).rounded() == v * 2)
            }
        }
    }

    @Test("no size ever drops text below 11 pt")
    func floor() {
        for size in UITextSize.allCases {
            #expect(size.scaled(11) >= 11)
            #expect(size.scaled(12) >= 11)
        }
        #expect(UITextSize.small.scaled(11) == 11)
    }

    @Test("editor size follows the editor control, scaled by the app size")
    func editor() {
        #expect(UITextSize.standard.editorPointSize(base: 15) == 15)
        #expect(UITextSize.large.editorPointSize(base: 15) == 17)       // 16.8
        #expect(UITextSize.extraLarge.editorPointSize(base: 22) == 27.5)
        #expect(UITextSize.small.editorPointSize(base: 13) == 12)       // 11.96
    }

    @Test("stored values round-trip; unknown or missing falls back to Default")
    func storage() {
        for size in UITextSize.allCases {
            #expect(UITextSize.from(stored: size.rawValue) == size)
        }
        #expect(UITextSize.from(stored: nil) == .standard)
        #expect(UITextSize.from(stored: "huge") == .standard)
        #expect(Set(UITextSize.allCases.map(\.label)).count == UITextSize.allCases.count)
        #expect(UITextSize.standard.label == "Default")
    }

    @Test("TextSizeSettings persists to its own defaults and scales points")
    @MainActor
    func liveSettings() throws {
        let suite = "W1UITextSize-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = TextSizeSettings(defaults: defaults)
        #expect(settings.size == .standard)
        #expect(settings.points(13) == 13)
        settings.set(.large)
        #expect(defaults.string(forKey: UITextSize.storageKey) == "large")
        #expect(settings.points(13) == 14.5)
        #expect(TextSizeSettings(defaults: defaults).size == .large)
    }
}
