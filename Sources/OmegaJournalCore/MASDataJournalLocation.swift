import Foundation

// MARK: - Journal location (pure, Mac App Store wave)
//
// Two builds share one bundle id: the direct (DMG) build keeps the journal in
// `~/Library/Application Support/OmegaJournal`, the sandboxed App Store build
// in its container. These rules decide which folder this process uses so a
// user who tries both never ends up with their journal split in two.

public enum MASDataJournalLocation {
    public static let databaseFileName = "omega_journal.sqlite3"
    public static let attachmentsFolderName = "attachments"
    public static let testDatabaseEnvKey = "OMEGA_JOURNAL_TEST_DATABASE_PATH"
    public static let testAttachmentsEnvKey = "OMEGA_JOURNAL_TEST_ATTACHMENTS_PATH"

    public struct Paths: Equatable, Sendable {
        public let databasePath: String
        public let attachmentsPath: String
        public let isTest: Bool
        public init(databasePath: String, attachmentsPath: String, isTest: Bool) {
            self.databasePath = databasePath
            self.attachmentsPath = attachmentsPath
            self.isTest = isTest
        }
        /// Folder holding the database (and normally attachments/backups).
        public var directory: String { (databasePath as NSString).deletingLastPathComponent }
    }

    /// Which journal folder to use.
    /// - Sandboxed: the container's Application Support folder (`containerDir`
    ///   as seen by this process). Container migration moves the legacy
    ///   journal there on first launch.
    /// - Not sandboxed: the legacy folder, unless it has no database while the
    ///   App Store container does — then the container, so data never splits
    ///   after someone tried the App Store version. The legacy folder is
    ///   checked first, so the container is only probed when needed.
    public static func resolveDirectory(isSandboxed: Bool,
                                        legacyDir: URL,
                                        containerDir: URL,
                                        fileExists: (String) -> Bool) -> URL {
        if isSandboxed { return containerDir }
        let legacyDB = legacyDir.appendingPathComponent(databaseFileName).path
        if fileExists(legacyDB) { return legacyDir }
        let containerDB = containerDir.appendingPathComponent(databaseFileName).path
        if fileExists(containerDB) { return containerDir }
        return legacyDir
    }

    /// Full path resolution. The test-mode environment variables always win.
    public static func resolvePaths(environment: [String: String],
                                    isSandboxed: Bool,
                                    legacyDir: URL,
                                    containerDir: URL,
                                    fileExists: (String) -> Bool) -> Paths {
        if let testPath = environment[testDatabaseEnvKey], !testPath.isEmpty {
            let databaseURL = URL(fileURLWithPath: testPath)
            let attachments = environment[testAttachmentsEnvKey]
                ?? databaseURL.deletingLastPathComponent()
                    .appendingPathComponent(attachmentsFolderName, isDirectory: true).path
            return Paths(databasePath: databaseURL.path, attachmentsPath: attachments, isTest: true)
        }
        let dir = resolveDirectory(isSandboxed: isSandboxed, legacyDir: legacyDir,
                                   containerDir: containerDir, fileExists: fileExists)
        return Paths(databasePath: dir.appendingPathComponent(databaseFileName).path,
                     attachmentsPath: dir.appendingPathComponent(attachmentsFolderName, isDirectory: true).path,
                     isTest: false)
    }

    /// The journal folder inside a folder the user picked for "Import existing
    /// journal…": the folder itself when it holds the database, or an
    /// `OmegaJournal` subfolder that does (people often pick Application
    /// Support). `nil` when neither has a journal database.
    public static func journalFolder(inPicked folder: URL, fileExists: (String) -> Bool) -> URL? {
        if fileExists(folder.appendingPathComponent(databaseFileName).path) { return folder }
        let nested = folder.appendingPathComponent("OmegaJournal", isDirectory: true)
        if fileExists(nested.appendingPathComponent(databaseFileName).path) { return nested }
        return nil
    }
}

// MARK: - One-time import offer (pure)

public enum MASDataLegacyImportOffer {
    /// UserDefaults key set by "Not now" (or after any import attempt).
    public static let dismissedDefaultsKey = "masData.legacyImportOfferDismissed"

    /// Offer "Import journal from an earlier version" once, after the launch
    /// gate, only to a sandboxed build whose journal is completely empty —
    /// i.e. container migration didn't bring an old journal over. Never in
    /// test/QA mode, never again after "Not now".
    public static func shouldOffer(isSandboxed: Bool, isTestMode: Bool,
                                   journalIsEmpty: Bool, dismissed: Bool) -> Bool {
        isSandboxed && !isTestMode && journalIsEmpty && !dismissed
    }
}
