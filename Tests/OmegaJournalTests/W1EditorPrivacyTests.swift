import AppKit
import Foundation
import Testing
@testable import OmegaJournal
@testable import OmegaJournalCore

/// Wave 1 editor-ai: voice memos never touch the shared temp folder as plaintext,
/// App Lock sweeps decrypted temp files, and memo transcription logic.
///
/// Nested in the serialized "Data safety" suite because these tests create and
/// sweep the shared private temp folder, as `DataSafetyTests.temporaryCopies` does.
extension DataSafetyTests {
@Suite("W1 editor: memo privacy, app-lock sweep, transcription", .serialized)
@MainActor
struct W1EditorPrivacyTests {
    static func makeDB() -> (root: URL, db: DatabaseManager) {
        TestSharedEnvironment.pin()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oj-w1editor-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let db = DatabaseManager(databasePath: root.appendingPathComponent("j.sqlite3").path,
                                 attachmentsPath: root.appendingPathComponent("att").path)
        return (root, db)
    }

    static func packageSource(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    final class FakeBackend: MemoRecordingBackend {
        var isRecording = true
        var currentTime: TimeInterval = 1
        func updateMeters() {}
        func averagePower() -> Float { -20 }
        func stop() { isRecording = false }
    }

    // MARK: Recording location

    @Test("new recordings are created inside the private 0700 temp folder")
    func recordingURLIsPrivate() throws {
        let url = try AudioMemoRecorder.makeRecordingURL()
        let dir = JournalCrypto.temporaryDirectory.standardizedFileURL.path
        #expect(url.deletingLastPathComponent().standardizedFileURL.path == dir)
        #expect(url.lastPathComponent.hasPrefix("omega-memo-") && url.pathExtension == "m4a")
        let perms = try FileManager.default.attributesOfItem(atPath: dir)[.posixPermissions] as? Int
        #expect(perms == 0o700)
        // Never the shared system temp folder itself.
        #expect(url.deletingLastPathComponent().standardizedFileURL != FileManager.default.temporaryDirectory.standardizedFileURL)
    }

    @Test("the recorder writes to the private folder and removes its file on stop")
    func recorderUsesPrivateFolder() throws {
        let url = try AudioMemoRecorder.makeRecordingURL()
        try Data(repeating: 7, count: 4096).write(to: url)
        let recorder = AudioMemoRecorder()
        recorder.attachForTesting(backend: FakeBackend(), fileURL: url)
        let current = try #require(recorder.recordingFileURL)
        #expect(current.path.hasPrefix(JournalCrypto.temporaryDirectory.path))
        #expect(MemoTempFiles.activePaths.contains(url.standardizedFileURL.path))
        let data = recorder.stop()
        #expect(data?.count == 4096)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(!MemoTempFiles.activePaths.contains(url.standardizedFileURL.path))
        #expect(recorder.recordingFileURL == nil)
    }

    @Test("a memo left behind by a crash is removed by the launch/quit sweep")
    func leftoverMemoIsSwept() throws {
        let leftover = try MemoTempFiles.makeURL(prefix: MemoTempFiles.memoPrefix)
        try Data("plaintext audio".utf8).write(to: leftover)
        let wave = try MemoTempFiles.makeURL(prefix: MemoTempFiles.wavePrefix)
        try Data("decoded".utf8).write(to: wave)
        JournalCrypto.cleanupTemporaryFiles()
        #expect(!FileManager.default.fileExists(atPath: leftover.path))
        #expect(!FileManager.default.fileExists(atPath: wave.path))
    }

    @Test("source guard: audio code never writes into the shared system temp folder")
    func noSharedTempWrites() throws {
        let source = try Self.packageSource("Sources/OmegaJournal/Services/WritingAudio.swift")
        #expect(!source.contains("FileManager.default.temporaryDirectory"))
    }

    // MARK: App Lock sweep

    @Test("engaging App Lock sweeps decrypted temp files; a disabled lock does nothing")
    func appLockSweeps() async throws {
        let (root, db) = Self.makeDB()
        defer { try? FileManager.default.removeItem(at: root) }
        let auth = BiometricAuth(forTesting: (), db: db)
        auth.evaluateOverride = { false }
        var sweeps = 0
        let lock = AppLockManager(db: db, auth: auth, observeApp: false, sweepTemporaryFiles: { sweeps += 1 })
        lock.lock()
        #expect(sweeps == 0 && !lock.isLocked)   // feature off: no lock, no sweep
        lock.isEnabled = true
        lock.lock()
        #expect(lock.isLocked && sweeps == 1)
        // Coming back after the timeout locks (and sweeps) too.
        lock.isEnabled = false
        lock.isEnabled = true
        lock.timeout = .immediately
        let t = Date()
        lock.appResigned(now: t)
        lock.appBecameActive(now: t.addingTimeInterval(5))
        #expect(sweeps == 2)
        lock.isEnabled = false
    }

    @Test("the default lock sweep keeps a recording in progress and removes everything else")
    func sweepKeepsActiveRecording() throws {
        let active = try MemoTempFiles.makeURL(prefix: MemoTempFiles.memoPrefix)
        try Data("recording".utf8).write(to: active)
        MemoTempFiles.markActive(active)
        defer { MemoTempFiles.markInactive(active); try? FileManager.default.removeItem(at: active) }
        let stale = try MemoTempFiles.makeURL(prefix: "omega-open-copy", ext: "txt")
        try Data("decrypted".utf8).write(to: stale)
        MemoTempFiles.sweep()
        #expect(FileManager.default.fileExists(atPath: active.path))
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        MemoTempFiles.markInactive(active)
        MemoTempFiles.sweep()
        #expect(!FileManager.default.fileExists(atPath: active.path))
    }

    // MARK: Transcription

    @Test("transcription is offered only on macOS 26+, with a usage string, on-device")
    func transcriptAvailability() {
        #expect(TranscriptAvailability.decide(osSupported: true, hasUsageDescription: true, onDeviceSupported: true) == .available)
        #expect(!TranscriptAvailability.decide(osSupported: false, hasUsageDescription: true, onDeviceSupported: true).isAvailable)
        #expect(!TranscriptAvailability.decide(osSupported: true, hasUsageDescription: false, onDeviceSupported: true).isAvailable)
        #expect(!TranscriptAvailability.decide(osSupported: true, hasUsageDescription: true, onDeviceSupported: false).isAvailable)
        // The test runner has no NSSpeechRecognitionUsageDescription: never offered (asking would crash).
        #expect(!MemoTranscription.availability.isAvailable)
    }

    @Test("transcript text is cleaned and inserted as a labelled block; the stamp stays last")
    func transcriptText() {
        #expect(TranscriptText.clean("  hello   there \n\n\n second  line ") == "hello there\n\nsecond line")
        #expect(TranscriptText.block("hi", atLineStart: true) == "*Voice memo transcript*\n\nhi\n")
        #expect(TranscriptText.block("hi", atLineStart: false).hasPrefix("\n\n*Voice memo transcript*"))
        #expect(TranscriptText.block("   ", atLineStart: true).isEmpty)
        let stamp = EntryStamp(location: "York", weather: "Rain")
        let body = EntryStampCodec.join(stamp: stamp, rest: "Walked home.\n")
        let out = TranscriptText.appending("it was cold", to: body)
        let parts = EntryStampCodec.split(out)
        #expect(parts.stamp == stamp)
        #expect(parts.rest.hasPrefix("Walked home.\n\n*Voice memo transcript*\n\nit was cold"))
        #expect(TranscriptText.appending("x", to: "") == "*Voice memo transcript*\n\nx\n")
        #expect(TranscriptText.appending("", to: "keep") == "keep")
    }

    final class FakeTranscriber: MemoTranscriber {
        var reply = ""
        var received: Data?
        func transcribe(audio: Data) async throws -> String { received = audio; return reply }
    }

    @Test("a memo is decrypted in memory and handed to the transcriber; empty results are reported")
    func transcribeAttachment() async throws {
        let (root, db) = Self.makeDB()
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = JournalEntry.new()
        db.saveEntry(entry)
        let audio = Data(repeating: 3, count: 2048)
        let memo = try #require(db.saveAttachment(entryId: entry.id, data: audio, filename: "memo.m4a", mimeType: "audio/mp4"))
        let fake = FakeTranscriber()
        fake.reply = "  went   for a walk  "
        #expect(try await MemoTranscription.transcribe(memo, db: db, using: fake) == "went for a walk")
        #expect(fake.received == audio)

        fake.reply = "   "
        await #expect(throws: MemoTranscriptionError.nothingHeard) {
            _ = try await MemoTranscription.transcribe(memo, db: db, using: fake)
        }

        let model = MemoTranscriptionModel(transcriber: fake)
        fake.reply = "hello"
        model.start(memo, db: db)
        #expect(model.state == .working)
        await model.waitForCompletion()
        #expect(model.state == .done("hello"))
        fake.reply = ""
        model.start(memo, db: db)
        await model.waitForCompletion()
        #expect(model.state == .failed(MemoTranscriptionError.nothingHeard.errorDescription ?? ""))
    }
}
}
