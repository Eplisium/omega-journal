import Foundation

// MARK: - Deep links

/// `omegajournal://` routes used by the widget (and anything else that opens
/// the app by URL). The scheme is per bundle so a QA build's widget can never
/// open the production app: packaging writes it to Info.plist as `OJURLScheme`
/// (app and widget) and registers it under `CFBundleURLTypes` (app).
public enum OmegaJournalLink: String, CaseIterable, Sendable {
    /// Start a new entry.
    case newEntry = "new"
    /// Open the Today page.
    case today
    /// Open On This Day.
    case onThisDay = "on-this-day"

    /// Scheme of the production app.
    public static let productionScheme = "omegajournal"
    public static let schemeInfoKey = "OJURLScheme"

    /// The URL for this route, e.g. `omegajournal://new`.
    public func url(scheme: String = OmegaJournalLink.productionScheme) -> URL {
        // Route names are fixed ASCII; this cannot fail.
        URL(string: "\(scheme)://\(rawValue)")!
    }

    /// Parses `scheme://route` (host form) or `scheme:route`. Unknown schemes
    /// and routes return nil; query strings and fragments are ignored, so a URL
    /// can never smuggle entry text into the app.
    public static func parse(_ url: URL, acceptedSchemes: Set<String>) -> OmegaJournalLink? {
        guard let scheme = url.scheme?.lowercased(),
              acceptedSchemes.map({ $0.lowercased() }).contains(scheme) else { return nil }
        let route = (url.host ?? url.path(percentEncoded: false))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
        return OmegaJournalLink(rawValue: route)
    }

    /// Scheme for a bundle id: production → `omegajournal`; QA ids
    /// (`<production>.qa-foo`) → `omegajournal-qa-foo`. Mirrors
    /// `oj_url_scheme` in scripts/lib/oj-packaging.sh.
    public static func scheme(forBundleIdentifier bundleId: String,
                              production: String = "com.eplisium.omega-journal") -> String {
        guard bundleId != production, bundleId.hasPrefix(production + ".") else { return productionScheme }
        let suffix = bundleId.dropFirst(production.count + 1)
            .lowercased()
            .map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" }
        return productionScheme + "-" + String(suffix)
    }
}

// MARK: - App Group

/// Where the app and the widget meet: the App Group container named in
/// Info.plist (`OJAppGroupIdentifier`, written by the packaging scripts as
/// `<team id>.<app bundle id>`). Team-prefixed groups need no provisioning
/// profile for Developer ID / Apple Development signed Mac apps.
public enum OmegaJournalAppGroup {
    public static let infoKey = "OJAppGroupIdentifier"
    public static let teamIdentifier = "WWC5HJN6AL"
    public static let productionIdentifier = "WWC5HJN6AL.com.eplisium.omega-journal"

    /// Set together with `OMEGA_JOURNAL_TEST_DATABASE_PATH` to let a QA/test run
    /// publish to a NON-production group (e.g. the QA bundle's own group).
    public static let testGroupEnvKey = "OMEGA_JOURNAL_TEST_APP_GROUP"
    public static let testDatabaseEnvKey = "OMEGA_JOURNAL_TEST_DATABASE_PATH"

    /// Group id from an Info.plist dictionary, if packaging wrote one.
    public static func identifier(infoDictionary: [String: Any]?) -> String? {
        guard let raw = infoDictionary?[infoKey] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.hasPrefix("@") ? nil : trimmed
    }

    public enum PublishDecision: Equatable, Sendable {
        case publish(groupIdentifier: String)
        case skip(reason: String)
    }

    /// Whether the app may write the widget snapshot, and where.
    ///
    /// - No group in Info.plist (`swift run`, tests): skip.
    /// - Test/QA mode (`OMEGA_JOURNAL_TEST_DATABASE_PATH` set): skip, unless
    ///   `OMEGA_JOURNAL_TEST_APP_GROUP` names a group that is not production —
    ///   a test journal must never overwrite the real widget's numbers.
    public static func publishDecision(bundleGroup: String?, environment: [String: String]) -> PublishDecision {
        let testMode = !(environment[testDatabaseEnvKey] ?? "").isEmpty
        if testMode {
            guard let test = environment[testGroupEnvKey]?.trimmingCharacters(in: .whitespaces), !test.isEmpty else {
                return .skip(reason: "test database in use and no \(testGroupEnvKey)")
            }
            guard test != productionIdentifier else {
                return .skip(reason: "\(testGroupEnvKey) must not be the production group")
            }
            return .publish(groupIdentifier: test)
        }
        guard let bundleGroup else { return .skip(reason: "no \(infoKey) in Info.plist") }
        return .publish(groupIdentifier: bundleGroup)
    }
}

// MARK: - Snapshot file

/// Reads and writes `widget-snapshot.json` in a directory (the App Group
/// container in the app, a temp folder in tests).
public struct WidgetSnapshotStore: Sendable {
    public static let fileName = "widget-snapshot.json"
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// The store inside an App Group container, or nil when the process has no
    /// access to that group (missing entitlement, unsigned build).
    public static func appGroup(_ identifier: String) -> WidgetSnapshotStore? {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) else {
            return nil
        }
        return WidgetSnapshotStore(directory: url.appendingPathComponent("Library/Application Support", isDirectory: true))
    }

    public var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    public static func encode(_ snapshot: WidgetSnapshot) throws -> Data { try encoder.encode(snapshot) }
    public static func decode(_ data: Data) throws -> WidgetSnapshot { try decoder.decode(WidgetSnapshot.self, from: data) }

    /// Atomic write; the widget never sees a half-written file.
    public func write(_ snapshot: WidgetSnapshot) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encode(snapshot).write(to: fileURL, options: [.atomic])
    }

    /// The stored snapshot, or nil when missing, unreadable or a newer version.
    public func read() -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? Self.decode(data),
              snapshot.version == WidgetSnapshot.currentVersion else { return nil }
        return snapshot
    }
}
