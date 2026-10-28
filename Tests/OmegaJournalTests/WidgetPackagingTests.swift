import Foundation
import Testing

/// Packaging inputs for the widget extension and App Intents metadata. A wrong
/// value here builds fine and fails only on a user's Mac (widget never loads,
/// intents never show in Shortcuts), so it is pinned down as files.
@Suite("Widget and intents packaging files")
struct WidgetPackagingTests {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func text(_ relative: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relative), encoding: .utf8)
    }

    static func plist(_ relative: String) throws -> [String: Any] {
        let data = try Data(contentsOf: repoRoot.appendingPathComponent(relative))
        return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    static let group = "WWC5HJN6AL.com.eplisium.omega-journal"

    @Test("widget entitlements: sandboxed, App Group, nothing else")
    func widgetEntitlements() throws {
        let e = try Self.plist("packaging/OmegaJournalWidgets.entitlements")
        #expect(e["com.apple.security.app-sandbox"] as? Bool == true)
        #expect(e["com.apple.security.application-groups"] as? [String] == [Self.group])
        #expect(Set(e.keys) == ["com.apple.security.app-sandbox", "com.apple.security.application-groups"])
    }

    @Test("app entitlements (both channels) share the widget's App Group")
    func appGroups() throws {
        for file in ["packaging/OmegaJournal-Direct.entitlements", "packaging/OmegaJournal-AppStore.entitlements"] {
            let e = try Self.plist(file)
            #expect(e["com.apple.security.application-groups"] as? [String] == [Self.group], "\(file)")
        }
        #expect(try Self.plist("packaging/OmegaJournal-Direct.entitlements")["com.apple.security.app-sandbox"] == nil)
    }

    @Test("widget Info.plist template: WidgetKit extension point, XPC!, macOS 14, tokens")
    func widgetInfoPlist() throws {
        let raw = try Self.text("packaging/Widgets-Info.plist.template")
        let filled = raw.replacingOccurrences(of: "@[A-Z_]+@", with: "x", options: .regularExpression)
        let p = try #require(try PropertyListSerialization.propertyList(from: Data(filled.utf8), format: nil) as? [String: Any])
        #expect((p["NSExtension"] as? [String: Any])?["NSExtensionPointIdentifier"] as? String == "com.apple.widgetkit-extension")
        #expect(p["CFBundlePackageType"] as? String == "XPC!")
        #expect(p["CFBundleExecutable"] as? String == "OmegaJournalWidgets")
        #expect(p["LSMinimumSystemVersion"] as? String == "14.0")
        for token in ["@WIDGET_BUNDLE_ID@", "@APP_GROUP@", "@URL_SCHEME@", "@VERSION@", "@BUILD_NUMBER@"] {
            #expect(raw.contains(token), "\(token)")
        }
    }

    @Test("app Info.plist template registers the per-bundle URL scheme and App Group")
    func appInfoPlist() throws {
        let raw = try Self.text("packaging/Info.plist.template")
        #expect(raw.contains("<key>OJAppGroupIdentifier</key><string>@APP_GROUP@</string>"))
        #expect(raw.contains("<key>OJURLScheme</key><string>@URL_SCHEME@</string>"))
        #expect(raw.contains("<key>CFBundleURLSchemes</key><array><string>@URL_SCHEME@</string></array>"))
    }

    @Test("const-value protocols list covers App Intents")
    func constProtocols() throws {
        let data = try Data(contentsOf: Self.repoRoot.appendingPathComponent("packaging/appintents-const-protocols.json"))
        let list = try #require(try JSONSerialization.jsonObject(with: data) as? [String])
        for proto in ["AppIntent", "AppShortcutsProvider", "AppEnum"] {
            #expect(list.contains(proto), "\(proto)")
        }
    }

    @Test("packaging lib: const values, metadata processor, appex signed before the app")
    func packagingLib() throws {
        let lib = try Self.text("scripts/lib/oj-packaging.sh")
        #expect(lib.contains("-emit-const-values"))
        #expect(lib.contains("-const-gather-protocols-list"))
        #expect(lib.contains("appintentsmetadataprocessor"))
        #expect(lib.contains("--compile-time-extraction"))
        #expect(lib.contains("Contents/PlugIns/$OJ_WIDGET_APPEX"))
        // Inside-out signing, never --deep.
        let signAppex = try #require(lib.range(of: "codesign \"${args[@]}\" --entitlements \"$widget_ent\" \"$appex\""))
        let signApp = try #require(lib.range(of: "codesign \"${args[@]}\" --entitlements \"$ent\" \"$app\""))
        #expect(signAppex.lowerBound < signApp.lowerBound)
        #expect(!lib.contains("codesign --deep") && !lib.contains("--deep --sign") && !lib.contains("--force --deep"))
    }

    @Test("every script signs with widget entitlements and verifies the widget")
    func scripts() throws {
        for script in ["build_app.sh", "scripts/make_release.sh", "scripts/make_mas.sh"] {
            let s = try Self.text(script)
            #expect(s.contains("--widget-entitlements"), "\(script)")
            #expect(s.contains("oj_verify_widget"), "\(script)")
        }
        let mas = try Self.text("scripts/make_mas.sh")
        #expect(mas.contains("OMEGA_JOURNAL_MAS_WIDGET_PROFILE"))
        #expect(mas.contains("OMEGA_JOURNAL_MAS_SKIP_WIDGET"))
    }

    @Test("OJ_APP_INTENTS lists exactly the intents in the source")
    func intentList() throws {
        let lib = try Self.text("scripts/lib/oj-packaging.sh")
        let line = try #require(lib.split(separator: "\n").first { $0.hasPrefix("OJ_APP_INTENTS=") })
        let listed = Set(line.dropFirst("OJ_APP_INTENTS=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            .split(separator: " ").map(String.init))
        let source = try Self.text("Sources/OmegaJournal/Intents/OmegaJournalIntents.swift")
        let regex = try NSRegularExpression(pattern: #"struct (\w+): AppIntent\b"#)
        let declared = Set(regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap {
            Range($0.range(at: 1), in: source).map { String(source[$0]) }
        })
        #expect(!declared.isEmpty)
        #expect(listed == declared)
    }
}
