import Foundation
import Testing

@Suite("W1Int context packaging")
struct W1IntContextPackagingTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func plist(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: root.appendingPathComponent(path))
        return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    static let resources = [
        "com.apple.security.personal-information.location",
        "com.apple.security.personal-information.calendars",
        "com.apple.security.personal-information.photos-library",
    ]

    @Test func bothChannelsCarryTheResourceEntitlements() throws {
        for file in ["packaging/OmegaJournal-AppStore.entitlements", "packaging/OmegaJournal-Direct.entitlements"] {
            let e = try Self.plist(file)
            for key in Self.resources { #expect(e[key] as? Bool == true, "\(file) lacks \(key)") }
            #expect(e["com.apple.developer.healthkit"] == nil)
            #expect(e["com.apple.developer.weatherkit"] == nil)
        }
        // The widget never needs them.
        let w = try Self.plist("packaging/OmegaJournalWidgets.entitlements")
        for key in Self.resources { #expect(w[key] == nil) }
    }

    @Test func usageStringsExplainEachPrompt() throws {
        let text = try String(contentsOf: Self.root.appendingPathComponent("packaging/Info.plist.template"), encoding: .utf8)
        let i = try #require(PropertyListSerialization.propertyList(from: Data(text.utf8), format: nil) as? [String: Any])
        for key in ["NSLocationUsageDescription", "NSLocationWhenInUseUsageDescription",
                    "NSCalendarsFullAccessUsageDescription", "NSPhotoLibraryUsageDescription"] {
            let s = try #require(i[key] as? String, "missing \(key)")
            #expect(s.hasPrefix("Omega Journal "))
            #expect(s.lowercased().contains("only"))
        }
        // No write-only/legacy calendar key: reading events needs full access on macOS 14+.
        #expect(i["NSCalendarsWriteOnlyAccessUsageDescription"] == nil)
    }
}
