import Foundation
import Testing
import OmegaJournalCore
@testable import OmegaJournal

@Suite("MAS sandbox: Day One photos", .serialized)
@MainActor
struct MASSandboxDayOneImportTests {
    private typealias D = MASSandboxDayOneImport

    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("oj-massandbox-d1-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    // MARK: Sanitizer

    @Test("photo names: only photos/<one safe name> passes", arguments: [
        ("photos/abc.jpeg", true),
        ("photos/DEADbeef.png", true),
        ("photos/0f9a_b-c.heic", true),
        ("photos/../secret.jpeg", false),
        ("photos/..", false),
        ("photos/.", false),
        ("photos/", false),
        ("photos/a/b.jpeg", false),
        ("photos/a\\b.jpeg", false),
        ("photos/.hidden", false),
        ("photos/a..b.jpeg", false),
        ("/etc/passwd", false),
        ("/photos/abc.jpeg", false),
        ("other/abc.jpeg", false),
        ("abc.jpeg", false),
        ("photos/~root.jpeg", false),
        ("photos/abc.jpeg\0.png", false),
    ])
    func sanitizer(path: String, ok: Bool) {
        #expect((D.sanitizedPhotoPath(path) != nil) == ok)
    }

    @Test("resolved photo must be a regular file inside <root>/photos (symlinks out are refused)")
    func containment() throws {
        let parent = try tempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("export", isDirectory: true)
        let photos = root.appendingPathComponent("photos", isDirectory: true)
        try FileManager.default.createDirectory(at: photos.appendingPathComponent("dir.jpeg"), withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: parent.appendingPathComponent("secret.txt"))
        try Data("journal".utf8).write(to: root.appendingPathComponent("Journal.json"))
        try Data([1, 2, 3]).write(to: photos.appendingPathComponent("good.jpeg"))
        try FileManager.default.createSymbolicLink(at: photos.appendingPathComponent("evil.jpeg"),
                                                   withDestinationURL: parent.appendingPathComponent("secret.txt"))
        try FileManager.default.createSymbolicLink(at: photos.appendingPathComponent("sibling.jpeg"),
                                                   withDestinationURL: root.appendingPathComponent("Journal.json"))
        #expect(D.containedPhotoFile("photos/good.jpeg", root: root) != nil)
        #expect(D.containedPhotoFile("photos/evil.jpeg", root: root) == nil)
        #expect(D.containedPhotoFile("photos/sibling.jpeg", root: root) == nil)
        #expect(D.containedPhotoFile("photos/dir.jpeg", root: root) == nil)
        #expect(D.containedPhotoFile("photos/missing.jpeg", root: root) == nil)
        #expect(D.containedPhotoFile("photos/../Journal.json", root: root) == nil)
    }

    // MARK: Where photos come from

    @Test("photo access decision for folder vs .json picks, sandboxed or not")
    func photoAccessDecision() {
        let folder = URL(fileURLWithPath: "/Users/x/Downloads/DayOne", isDirectory: true)
        let json = folder.appendingPathComponent("Journal.json")
        let never: (URL) -> Bool = { _ in Issue.record("should not probe"); return false }
        #expect(D.photoAccess(selection: folder, selectionIsDirectory: true, referencesPhotos: true,
                              isSandboxed: true, canReadPhotosFolder: never) == .useRoot(folder))
        #expect(D.photoAccess(selection: json, selectionIsDirectory: false, referencesPhotos: false,
                              isSandboxed: true, canReadPhotosFolder: never) == .noPhotosNeeded)
        #expect(D.photoAccess(selection: json, selectionIsDirectory: false, referencesPhotos: true,
                              isSandboxed: false, canReadPhotosFolder: never) == .useRoot(folder))
        var probed: URL?
        #expect(D.photoAccess(selection: json, selectionIsDirectory: false, referencesPhotos: true,
                              isSandboxed: true, canReadPhotosFolder: { probed = $0; return true }) == .useRoot(folder))
        #expect(probed?.lastPathComponent == "photos")
        #expect(D.photoAccess(selection: json, selectionIsDirectory: false, referencesPhotos: true,
                              isSandboxed: true, canReadPhotosFolder: { _ in false }) == .askForFolder(suggested: folder))
    }

    @Test("second-panel pick: export folder or its photos folder; anything else is refused")
    func exportRootForPick() {
        let folder = URL(fileURLWithPath: "/Users/x/DayOne", isDirectory: true)
        #expect(D.exportRoot(forPickedFolder: folder, hasPhotosSubfolder: true) == folder)
        #expect(D.exportRoot(forPickedFolder: folder.appendingPathComponent("photos", isDirectory: true),
                             hasPhotosSubfolder: false)?.path == folder.path)
        #expect(D.exportRoot(forPickedFolder: URL(fileURLWithPath: "/Users/x/Desktop"), hasPhotosSubfolder: false) == nil)
    }

    // MARK: Import flow (private database)

    private func makeVM() throws -> (JournalViewModel, URL) {
        let root = try tempDir()
        if (ProcessInfo.processInfo.environment["OMEGA_JOURNAL_TEST_DATABASE_PATH"] ?? "").isEmpty {
            setenv("OMEGA_JOURNAL_TEST_DATABASE_PATH", root.appendingPathComponent("shared.sqlite3").path, 1)
            setenv("OMEGA_JOURNAL_TEST_ATTACHMENTS_PATH", root.appendingPathComponent("shared-att").path, 1)
        }
        let db = DatabaseManager(databasePath: root.appendingPathComponent("j.sqlite3").path,
                                 attachmentsPath: root.appendingPathComponent("att").path)
        return (JournalViewModel(database: db), root)
    }

    private func writeExport(in dir: URL, title: String) throws -> URL {
        let photos = dir.appendingPathComponent("photos", isDirectory: true)
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        try Data([1, 2, 3, 4]).write(to: photos.appendingPathComponent("abc.jpeg"))
        let json = """
        {"entries":[{"uuid":"\(UUID().uuidString)","creationDate":"2021-03-04T05:06:07Z",
        "text":"# \(title)\\n\\nBody","photos":[{"identifier":"I","md5":"abc","type":"jpeg"}]}]}
        """
        let file = dir.appendingPathComponent("Journal.json")
        try Data(json.utf8).write(to: file)
        return file
    }

    @Test("sandboxed .json pick asks for the export folder and then imports the photos")
    func sandboxedJSONPickAsksForFolder() throws {
        let (vm, root) = try makeVM()
        defer { try? FileManager.default.removeItem(at: root) }
        let export = root.appendingPathComponent("DayOne", isDirectory: true)
        let json = try writeExport(in: export, title: "MASSandbox D1 photo")
        var asked: URL?
        let report = vm.importDayOneJSON(from: json, isSandboxed: true, canReadPhotosFolder: { _ in false },
                                         askForPhotoFolder: { asked = $0; return $0 })
        #expect(asked?.path == export.path)
        #expect(report.added == 1 && report.attachments == 1)
    }

    @Test("picking the photos folder itself also works")
    func sandboxedPhotosFolderPick() throws {
        let (vm, root) = try makeVM()
        defer { try? FileManager.default.removeItem(at: root) }
        let export = root.appendingPathComponent("DayOne", isDirectory: true)
        let json = try writeExport(in: export, title: "MASSandbox D1 photos pick")
        let report = vm.importDayOneJSON(from: json, isSandboxed: true, canReadPhotosFolder: { _ in false },
                                         askForPhotoFolder: { $0.appendingPathComponent("photos", isDirectory: true) })
        #expect(report.added == 1 && report.attachments == 1)
    }

    @Test("declining the folder imports text only and says photos were skipped")
    func sandboxedDecline() throws {
        let (vm, root) = try makeVM()
        defer { try? FileManager.default.removeItem(at: root) }
        let json = try writeExport(in: root.appendingPathComponent("DayOne", isDirectory: true), title: "MASSandbox D1 text")
        let report = vm.importDayOneJSON(from: json, isSandboxed: true, canReadPhotosFolder: { _ in false },
                                         askForPhotoFolder: { _ in nil })
        #expect(report.added == 1 && report.attachments == 0)
        #expect(vm.toast?.message.contains("photos not imported") == true)
    }

    @Test("unsandboxed .json pick and folder pick never ask")
    func unsandboxedNeverAsks() throws {
        let (vm, root) = try makeVM()
        defer { try? FileManager.default.removeItem(at: root) }
        let export = root.appendingPathComponent("DayOne", isDirectory: true)
        let json = try writeExport(in: export, title: "MASSandbox D1 direct")
        let fail: (URL) -> URL? = { _ in Issue.record("must not ask"); return nil }
        let r1 = vm.importDayOneJSON(from: json, isSandboxed: false, askForPhotoFolder: fail)
        #expect(r1.added == 1 && r1.attachments == 1)
        let export2 = root.appendingPathComponent("DayOne2", isDirectory: true)
        _ = try writeExport(in: export2, title: "MASSandbox D1 folder")
        let r2 = vm.importDayOneJSON(from: export2, isSandboxed: true, askForPhotoFolder: fail)
        #expect(r2.added == 1 && r2.attachments == 1)
    }

    @Test("a symlinked photo pointing outside the export is never imported")
    func symlinkedPhotoRefused() throws {
        let (vm, root) = try makeVM()
        defer { try? FileManager.default.removeItem(at: root) }
        let export = root.appendingPathComponent("DayOne", isDirectory: true)
        let json = try writeExport(in: export, title: "MASSandbox D1 evil")
        let photo = export.appendingPathComponent("photos/abc.jpeg")
        try FileManager.default.removeItem(at: photo)
        try Data("private".utf8).write(to: root.appendingPathComponent("private.txt"))
        try FileManager.default.createSymbolicLink(at: photo, withDestinationURL: root.appendingPathComponent("private.txt"))
        let report = vm.importDayOneJSON(from: json, isSandboxed: false)
        #expect(report.added == 1 && report.attachments == 0)
    }
}
