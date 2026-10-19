import Foundation
import Testing
@testable import OmegaJournal

/// Bookmark coder that stores the path as the "bookmark" and can simulate
/// stale / unresolvable bookmarks and creation failures.
private final class FakeBookmarkCoder: MASSandboxBookmarkCoding, @unchecked Sendable {
    var makeFails = false
    var resolveFails = false
    var stale = false
    /// When set, resolution returns this URL instead of the stored one (folder moved).
    var movedTo: URL?
    private(set) var made: [(path: String, scoped: Bool)] = []

    func makeBookmark(for url: URL, securityScoped: Bool) throws -> Data {
        if makeFails { throw CocoaError(.fileReadNoPermission) }
        made.append((url.path, securityScoped))
        return Data(url.path.utf8)
    }

    func resolveBookmark(_ data: Data, securityScoped: Bool) throws -> (url: URL, isStale: Bool) {
        if resolveFails { throw CocoaError(.fileNoSuchFile) }
        let url = movedTo ?? URL(fileURLWithPath: String(decoding: data, as: UTF8.self), isDirectory: true)
        return (url, stale)
    }
}

/// Accessor that counts start/stop calls so tests can prove they are balanced.
private final class CountingAccessor: MASSandboxScopeAccessing, @unchecked Sendable {
    var grants = true
    private(set) var starts = 0
    private(set) var stops = 0
    var open: Int { starts - stops }

    func startAccessing(_ url: URL) -> Bool {
        guard grants else { return false }
        starts += 1
        return true
    }

    func stopAccessing(_ url: URL) { stops += 1 }
}

private struct BodyError: Error {}

@Suite("MAS sandbox: remembered backup folder", .serialized)
@MainActor
struct MASSandboxBackupFolderTests {
    private func env(sandboxed: Bool, coder: FakeBookmarkCoder = FakeBookmarkCoder(),
                     accessor: CountingAccessor = CountingAccessor()) -> MASSandboxBackupFolder.Environment {
        MASSandboxBackupFolder.Environment(isSandboxed: sandboxed, coder: coder, accessor: accessor)
    }

    private func scopedBookmark(_ path: String) -> String {
        MASSandboxBackupFolder.StoredBookmark(data: Data(path.utf8), securityScoped: true).encoded
    }

    private func plainBookmark(_ path: String) -> String {
        MASSandboxBackupFolder.StoredBookmark(data: Data(path.utf8), securityScoped: false).encoded
    }

    // MARK: Pure resolution

    @Test("nothing stored means no extra folder")
    func notSet() {
        let r = MASSandboxBackupFolder.resolve(path: "", bookmark: "", environment: env(sandboxed: true))
        #expect(r.state == .notSet)
        #expect(r.updatedBookmark == nil)
    }

    @Test("legacy path only, unsandboxed: keeps using the path and upgrades to a plain bookmark")
    func legacyPathUnsandboxed() {
        let coder = FakeBookmarkCoder()
        let r = MASSandboxBackupFolder.resolve(path: "/Volumes/Backup/Omega", bookmark: "",
                                               environment: env(sandboxed: false, coder: coder))
        #expect(r.state == .ready(URL(fileURLWithPath: "/Volumes/Backup/Omega", isDirectory: true), securityScoped: false))
        #expect(r.updatedBookmark?.securityScoped == false)
        #expect(coder.made.map(\.scoped) == [false])
    }

    @Test("legacy path only, unsandboxed: bookmark creation failure falls back to the path")
    func legacyPathUnsandboxedBookmarkFails() {
        let coder = FakeBookmarkCoder()
        coder.makeFails = true
        let r = MASSandboxBackupFolder.resolve(path: "/Volumes/Backup/Omega", bookmark: "",
                                               environment: env(sandboxed: false, coder: coder))
        #expect(r.state.url?.path == "/Volumes/Backup/Omega")
        #expect(r.updatedBookmark == nil)
    }

    @Test("legacy path only, sandboxed: the user must choose the folder again")
    func legacyPathSandboxed() {
        let coder = FakeBookmarkCoder()
        let r = MASSandboxBackupFolder.resolve(path: "/Volumes/Backup/Omega", bookmark: "",
                                               environment: env(sandboxed: true, coder: coder))
        #expect(r.state == .needsRepick(lastKnownPath: "/Volumes/Backup/Omega"))
        #expect(coder.made.isEmpty)
    }

    @Test("security-scoped bookmark resolves in the sandbox; the access probe is balanced")
    func scopedBookmarkResolves() {
        let accessor = CountingAccessor()
        let r = MASSandboxBackupFolder.resolve(path: "/Users/x/iCloud/OJ", bookmark: scopedBookmark("/Users/x/iCloud/OJ"),
                                               environment: env(sandboxed: true, accessor: accessor))
        #expect(r.state == .ready(URL(fileURLWithPath: "/Users/x/iCloud/OJ", isDirectory: true), securityScoped: true))
        #expect(r.updatedBookmark == nil && r.updatedPath == nil)
        #expect(accessor.starts == 1 && accessor.open == 0)
    }

    @Test("stale bookmark is refreshed while access is held, then released")
    func staleBookmarkRefreshed() {
        let coder = FakeBookmarkCoder(); coder.stale = true
        let accessor = CountingAccessor()
        let r = MASSandboxBackupFolder.resolve(path: "/Users/x/OJ", bookmark: scopedBookmark("/Users/x/OJ"),
                                               environment: env(sandboxed: true, coder: coder, accessor: accessor))
        #expect(r.state.url != nil)
        #expect(r.updatedBookmark?.securityScoped == true)
        #expect(coder.made.map(\.scoped) == [true])
        #expect(accessor.starts == 2 && accessor.open == 0)
    }

    @Test("a moved folder is followed and its new path remembered")
    func movedFolderFollowed() {
        let coder = FakeBookmarkCoder(); coder.movedTo = URL(fileURLWithPath: "/Users/x/Renamed", isDirectory: true)
        let r = MASSandboxBackupFolder.resolve(path: "/Users/x/OJ", bookmark: plainBookmark("/Users/x/OJ"),
                                               environment: env(sandboxed: false, coder: coder))
        #expect(r.state.url?.path == "/Users/x/Renamed")
        #expect(r.updatedPath == "/Users/x/Renamed")
    }

    @Test("unresolvable bookmark: needs re-pick in the sandbox, path fallback outside it")
    func unresolvable() {
        let coder = FakeBookmarkCoder(); coder.resolveFails = true
        let sandboxed = MASSandboxBackupFolder.resolve(path: "/Users/x/OJ", bookmark: scopedBookmark("/Users/x/OJ"),
                                                       environment: env(sandboxed: true, coder: coder))
        #expect(sandboxed.state == .needsRepick(lastKnownPath: "/Users/x/OJ"))
        let direct = MASSandboxBackupFolder.resolve(path: "/Users/x/OJ", bookmark: scopedBookmark("/Users/x/OJ"),
                                                    environment: env(sandboxed: false, coder: coder))
        #expect(direct.state == .ready(URL(fileURLWithPath: "/Users/x/OJ", isDirectory: true), securityScoped: false))
        // Undecodable bookmark text with no path still counts as "chosen, needs re-pick".
        let junk = MASSandboxBackupFolder.resolve(path: "", bookmark: "scoped:@@@", environment: env(sandboxed: true))
        #expect(junk.state.needsRepick)
    }

    @Test("a plain (unsandboxed) bookmark grants nothing inside the sandbox")
    func plainBookmarkInSandbox() {
        let r = MASSandboxBackupFolder.resolve(path: "/Users/x/OJ", bookmark: plainBookmark("/Users/x/OJ"),
                                               environment: env(sandboxed: true))
        #expect(r.state.needsRepick)
    }

    @Test("bookmark resolves but the sandbox refuses access: needs re-pick, nothing left open")
    func accessRefused() {
        let accessor = CountingAccessor(); accessor.grants = false
        let r = MASSandboxBackupFolder.resolve(path: "/Users/x/OJ", bookmark: scopedBookmark("/Users/x/OJ"),
                                               environment: env(sandboxed: true, accessor: accessor))
        #expect(r.state.needsRepick)
        #expect(accessor.stops == 0)
    }

    @Test("new folder: scoped bookmark when sandboxed, plain when not, nil when creation fails")
    func newFolderBookmark() {
        let url = URL(fileURLWithPath: "/Users/x/OJ", isDirectory: true)
        #expect(MASSandboxBackupFolder.bookmarkForNewFolder(url, environment: env(sandboxed: true))?.securityScoped == true)
        #expect(MASSandboxBackupFolder.bookmarkForNewFolder(url, environment: env(sandboxed: false))?.securityScoped == false)
        let failing = FakeBookmarkCoder(); failing.makeFails = true
        #expect(MASSandboxBackupFolder.bookmarkForNewFolder(url, environment: env(sandboxed: true, coder: failing)) == nil)
    }

    @Test("stored bookmark text round-trips; junk is rejected")
    func storedBookmarkEncoding() {
        let b = MASSandboxBackupFolder.StoredBookmark(data: Data([1, 2, 3]), securityScoped: true)
        #expect(MASSandboxBackupFolder.StoredBookmark(encoded: b.encoded) == b)
        #expect(b.encoded.hasPrefix("scoped:"))
        #expect(MASSandboxBackupFolder.StoredBookmark(encoded: "") == nil)
        #expect(MASSandboxBackupFolder.StoredBookmark(encoded: "other:AQID") == nil)
        #expect(MASSandboxBackupFolder.StoredBookmark(encoded: "plain:not base64!") == nil)
    }

    // MARK: Access wrapper

    @Test("withAccess balances start/stop on success and on a thrown error")
    func withAccessBalanced() throws {
        let accessor = CountingAccessor()
        let e = env(sandboxed: true, accessor: accessor)
        let state = MASSandboxBackupFolder.State.ready(URL(fileURLWithPath: "/x", isDirectory: true), securityScoped: true)
        let value = MASSandboxBackupFolder.withAccess(to: state, environment: e) { _ in 42 }
        #expect(value == 42 && accessor.starts == 1 && accessor.open == 0)
        #expect(throws: BodyError.self) {
            try MASSandboxBackupFolder.withAccess(to: state, environment: e) { _ -> Int in throw BodyError() }
        }
        #expect(accessor.starts == 2 && accessor.open == 0)
        // Unscoped (unsandboxed) folders never touch the accessor.
        let plain = MASSandboxBackupFolder.State.ready(URL(fileURLWithPath: "/x", isDirectory: true), securityScoped: false)
        #expect(MASSandboxBackupFolder.withAccess(to: plain, environment: e) { _ in 1 } == 1)
        #expect(accessor.starts == 2)
    }

    @Test("withAccess skips the body when the folder isn't usable or access is refused")
    func withAccessRefused() {
        let accessor = CountingAccessor()
        var calls = 0
        _ = MASSandboxBackupFolder.withAccess(to: .needsRepick(lastKnownPath: "/x"), environment: env(sandboxed: true, accessor: accessor)) { _ in calls += 1 }
        _ = MASSandboxBackupFolder.withAccess(to: .notSet, environment: env(sandboxed: true, accessor: accessor)) { _ in calls += 1 }
        accessor.grants = false
        let r: Int? = MASSandboxBackupFolder.withAccess(
            to: .ready(URL(fileURLWithPath: "/x"), securityScoped: true), environment: env(sandboxed: true, accessor: accessor)) { _ in calls += 1; return 1 }
        #expect(r == nil && calls == 0 && accessor.stops == 0)
    }

    // MARK: Settings copy

    @Test("panel copy: re-pick state asks clearly and reassures that local backups continue")
    func panelCopy() {
        let repick = MASSandboxBackupFolderCopy(state: .needsRepick(lastKnownPath: "/Volumes/Disk/OJ Backups"))
        #expect(repick.title == "Choose your backup folder again")
        #expect(repick.detail.contains("“OJ Backups”") && repick.detail.contains("still saved on this Mac"))
        #expect(repick.isWarning && repick.chooseLabel == "Choose Again…")
        let ready = MASSandboxBackupFolderCopy(state: .ready(URL(fileURLWithPath: "/Volumes/Disk/OJ"), securityScoped: true))
        #expect(!ready.isWarning && ready.detail == "/Volumes/Disk/OJ")
        #expect(MASSandboxBackupFolderCopy(state: .notSet).detail.contains("Not set"))
    }

    // MARK: Database integration (private temp database)

    private static func makeDB() -> (DatabaseManager, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oj-massandbox-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if (ProcessInfo.processInfo.environment["OMEGA_JOURNAL_TEST_DATABASE_PATH"] ?? "").isEmpty {
            // Ephemeral key mode: never touch the real Keychain.
            setenv("OMEGA_JOURNAL_TEST_DATABASE_PATH", root.appendingPathComponent("shared.sqlite3").path, 1)
            setenv("OMEGA_JOURNAL_TEST_ATTACHMENTS_PATH", root.appendingPathComponent("shared-att").path, 1)
        }
        let db = DatabaseManager(databasePath: root.appendingPathComponent("j.sqlite3").path,
                                 attachmentsPath: root.appendingPathComponent("att").path)
        return (db, root)
    }

    @Test("sandboxed with only a legacy path: local daily backup still works, mirror skipped with a clear message")
    func sandboxedLegacyPathKeepsLocalBackups() throws {
        let (db, root) = Self.makeDB()
        defer { try? FileManager.default.removeItem(at: root) }
        let extra = root.appendingPathComponent("extra", isDirectory: true)
        try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
        _ = db.setSetting(DatabaseManager.backupFolderKey, value: extra.path)
        let e = env(sandboxed: true)
        #expect(db.backupFolderState(environment: e) == .needsRepick(lastKnownPath: extra.path))
        let local = MASSandboxBackupFolder.$environmentOverride.withValue(e) { db.backupNow() }
        let file = try #require(local)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(!FileManager.default.fileExists(atPath: extra.appendingPathComponent(file.lastPathComponent).path))
        #expect(db.lastErrorMessage?.contains("choose your backup folder again") == true)
        let infos = MASSandboxBackupFolder.$environmentOverride.withValue(e) { db.backupInfos() }
        #expect(infos.allSatisfy { !$0.isExternal } && !infos.isEmpty)
    }

    @Test("sandboxed bookmark: choose, mirror, list, verify and restore all run inside balanced access")
    func sandboxedBookmarkFlow() throws {
        let (db, root) = Self.makeDB()
        defer { try? FileManager.default.removeItem(at: root) }
        let extra = root.appendingPathComponent("extra", isDirectory: true)
        try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
        let accessor = CountingAccessor()
        let e = env(sandboxed: true, accessor: accessor)
        #expect(db.setChosenBackupFolder(extra, environment: e))
        #expect(db.getSetting(DatabaseManager.backupFolderBookmarkKey).hasPrefix("scoped:"))
        #expect(db.getSetting(DatabaseManager.backupFolderKey) == extra.path)

        try MASSandboxBackupFolder.$environmentOverride.withValue(e) {
            let local = try #require(db.backupNow())
            let mirrored = extra.appendingPathComponent(local.lastPathComponent)
            #expect(FileManager.default.fileExists(atPath: mirrored.path))
            let external = try #require(db.backupInfos().first { $0.isExternal })
            #expect(try db.verifyBackup(at: external.url).schemaVersion == DatabaseManager.currentSchemaVersion)
            try db.restoreBackup(from: external.url)
        }
        #expect(accessor.starts > 0 && accessor.open == 0)

        // Sandboxed builds refuse a folder they can't remember.
        let failing = FakeBookmarkCoder(); failing.makeFails = true
        #expect(!db.setChosenBackupFolder(root, environment: env(sandboxed: true, coder: failing)))
        // Clearing removes both settings.
        #expect(db.setChosenBackupFolder(nil, environment: e))
        #expect(db.backupFolderState(environment: e) == .notSet)
        #expect(db.getSetting(DatabaseManager.backupFolderBookmarkKey).isEmpty)
    }

    @Test("unsandboxed with real bookmarks: legacy path upgrades, renamed folder is followed")
    func realBookmarksUnsandboxed() throws {
        let (db, root) = Self.makeDB()
        defer { try? FileManager.default.removeItem(at: root) }
        let real = MASSandboxBackupFolder.Environment(isSandboxed: false, coder: MASSandboxSystemBookmarkCoder(),
                                                     accessor: MASSandboxSystemScopeAccessor())
        let extra = root.appendingPathComponent("extra", isDirectory: true)
        try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
        _ = db.setSetting(DatabaseManager.backupFolderKey, value: extra.path)
        #expect(db.backupFolderState(environment: real).url?.path == extra.path)
        #expect(db.getSetting(DatabaseManager.backupFolderBookmarkKey).hasPrefix("plain:"))

        let renamed = root.appendingPathComponent("renamed", isDirectory: true)
        try FileManager.default.moveItem(at: extra, to: renamed)
        let followed = try #require(db.backupFolderState(environment: real).url)
        #expect(DatabaseManager.samePath(followed, renamed))
        #expect(DatabaseManager.samePath(URL(fileURLWithPath: db.getSetting(DatabaseManager.backupFolderKey)), renamed))
    }
}
