import Testing
import Foundation
@testable import OmegaJournal

/// Guards the packaging inputs in `packaging/` that the build scripts sign into the app.
/// A wrong key here does not fail `swift build`; it fails App Review, breaks voice memos
/// (hardened runtime without the microphone entitlement, the 1.0.2 DMG bug) or burns the
/// one-time sandbox container migration. Pure file parsing: no certificates needed, so it
/// runs on the GitHub macOS runners.
@Suite("MAS pipeline packaging files")
struct MASPipelinePackagingTests {

    /// Repo root, found from this file's location (Tests/OmegaJournalTests/<file>).
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static func plist(_ relative: String) throws -> [String: Any] {
        let url = repoRoot.appendingPathComponent(relative)
        let data = try Data(contentsOf: url)
        let object = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try #require(object as? [String: Any], "\(relative) is not a dictionary plist")
    }

    static let appID = "WWC5HJN6AL.com.eplisium.omega-journal"

    // MARK: Entitlements

    @Test("App Store entitlements: sandbox, file access, microphone, profile identifiers")
    func appStoreEntitlements() throws {
        let e = try Self.plist("packaging/OmegaJournal-AppStore.entitlements")
        #expect(e["com.apple.security.app-sandbox"] as? Bool == true)
        #expect(e["com.apple.security.files.user-selected.read-write"] as? Bool == true)
        #expect(e["com.apple.security.files.bookmarks.app-scope"] as? Bool == true)
        #expect(e["com.apple.security.device.audio-input"] as? Bool == true)
        #expect(e["com.apple.security.print"] as? Bool == true)
        #expect(e["com.apple.application-identifier"] as? String == Self.appID)
        #expect(e["com.apple.developer.team-identifier"] as? String == "WWC5HJN6AL")
        #expect(e["keychain-access-groups"] as? [String] == [Self.appID])
    }

    @Test("App Store entitlements: no network, no exceptions, no debugging")
    func appStoreEntitlementsStayMinimal() throws {
        let keys = Set(try Self.plist("packaging/OmegaJournal-AppStore.entitlements").keys)
        #expect(keys.filter { $0.hasPrefix("com.apple.security.network") }.isEmpty)
        #expect(keys.filter { $0.contains("temporary-exception") }.isEmpty)
        #expect(!keys.contains("com.apple.security.get-task-allow"))
        #expect(!keys.contains("com.apple.security.files.downloads.read-write"))
        #expect(!keys.contains("com.apple.security.files.all"))
    }

    @Test("Direct entitlements: microphone under hardened runtime, not sandboxed")
    func directEntitlements() throws {
        let e = try Self.plist("packaging/OmegaJournal-Direct.entitlements")
        #expect(e["com.apple.security.device.audio-input"] as? Bool == true)
        #expect(e["com.apple.security.app-sandbox"] == nil)
        #expect(e.keys.filter { $0.hasPrefix("com.apple.security.network") }.isEmpty)
        #expect(e["keychain-access-groups"] == nil, "needs a provisioning profile; DMG has none")
    }

    // MARK: Privacy manifest

    @Test("Privacy manifest: no tracking, no collection, required-reason codes")
    func privacyManifest() throws {
        let p = try Self.plist("packaging/PrivacyInfo.xcprivacy")
        #expect(p["NSPrivacyTracking"] as? Bool == false)
        #expect((p["NSPrivacyTrackingDomains"] as? [Any])?.isEmpty == true)
        #expect((p["NSPrivacyCollectedDataTypes"] as? [Any])?.isEmpty == true)

        let types = try #require(p["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        var reasons: [String: [String]] = [:]
        for t in types {
            let category = try #require(t["NSPrivacyAccessedAPIType"] as? String)
            let codes = try #require(t["NSPrivacyAccessedAPITypeReasons"] as? [String])
            #expect(!codes.isEmpty, "\(category) needs at least one reason")
            reasons[category] = codes
        }
        #expect(reasons["NSPrivacyAccessedAPICategoryUserDefaults"] == ["CA92.1"])
        #expect(Set(reasons["NSPrivacyAccessedAPICategoryFileTimestamp"] ?? []) == ["C617.1", "3B52.1"])
        #expect(reasons.count == 2, "audit Sources/ before declaring another required-reason API")
    }

    // MARK: Container migration

    @Test("Container migration manifest: Move list in Apple's documented format")
    func containerMigration() throws {
        let m = try Self.plist("packaging/container-migration.plist")
        #expect(Set(m.keys).isSubset(of: ["Move", "Symlink", "MigrateScriptsForApplication"]))
        let move = try #require(m["Move"] as? [Any])
        var sources: [String] = []
        for item in move {
            if let path = item as? String {
                sources.append(path)
            } else if let pair = item as? [String] {
                #expect(pair.count == 2, "a [source, destination] pair has exactly two paths")
                sources.append(pair[0])
            } else {
                Issue.record("Move items must be a string or a [source, destination] array")
            }
        }
        #expect(sources.contains("${ApplicationSupport}/OmegaJournal"))
        #expect(sources.contains("${Library}/Preferences/com.eplisium.omega-journal.plist"))
        for s in sources {
            #expect(s.hasPrefix("${"), "\(s) must start with a home-relative variable")
            #expect(!s.hasPrefix("/") && !s.contains("~"), "\(s) must not be absolute")
        }
    }

    // MARK: Info.plist template + version

    @Test("Info.plist template carries the App Store keys and channel token")
    func infoPlistTemplate() throws {
        let i = try Self.plist("packaging/Info.plist.template")
        #expect(i["CFBundleExecutable"] as? String == "OmegaJournal")
        #expect(i["CFBundleIdentifier"] as? String == "@BUNDLE_ID@")
        #expect(i["CFBundleVersion"] as? String == "@BUILD_NUMBER@")
        #expect(i["CFBundleShortVersionString"] as? String == "@VERSION@")
        #expect(i["OJDistributionChannel"] as? String == "@CHANNEL@")
        #expect(i["LSApplicationCategoryType"] as? String == "public.app-category.lifestyle")
        #expect(i["ITSAppUsesNonExemptEncryption"] as? Bool == false)
        #expect(i["LSMinimumSystemVersion"] as? String == "14.0")
        #expect((i["NSMicrophoneUsageDescription"] as? String)?.isEmpty == false)
        #expect((i["NSHumanReadableCopyright"] as? String)?.contains("@YEAR@") == true)
    }

    @Test("Channel values written by the scripts match AppEnvironment.Channel")
    func channelValuesMatchApp() {
        #expect(AppEnvironment.Channel(rawValue: "direct") == .direct)
        #expect(AppEnvironment.Channel(rawValue: "appstore") == .appStore)
    }

    @Test("VERSION is a release version newer than the shipped 1.0.2")
    func versionFile() throws {
        let raw = try String(contentsOf: Self.repoRoot.appendingPathComponent("VERSION"), encoding: .utf8)
        let version = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = version.split(separator: ".").compactMap { Int($0) }
        #expect(parts.count == 3 && version.split(separator: ".").count == 3, "expected MAJOR.MINOR.PATCH")
        #expect(parts.lexicographicallyPrecedes([1, 0, 2]) == false && parts != [1, 0, 2])
    }
}
