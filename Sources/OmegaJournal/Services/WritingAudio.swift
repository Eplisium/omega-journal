import SwiftUI
import AVFoundation
import Speech
import AppKit
import OmegaJournalCore

extension Attachment {
    var isAudio: Bool { mimeType.hasPrefix("audio/") }
}

// MARK: - Private temp files for audio

/// Plaintext audio (a memo being recorded, a decoded copy for the waveform or for
/// transcription) only ever exists inside `JournalCrypto.temporaryDirectory`: a 0700
/// folder swept at launch, at quit and when App Lock engages. Files still in use
/// (a recording in progress) are registered so the App Lock sweep keeps them.
nonisolated enum MemoTempFiles {
    static let memoPrefix = "omega-memo"
    static let wavePrefix = "omega-wave"
    static let transcribePrefix = "omega-transcribe"

    /// A fresh file URL inside the private temp folder (created 0700 if needed).
    static func makeURL(prefix: String, ext: String = "m4a") throws -> URL {
        let dir = JournalCrypto.temporaryDirectory
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Tighten even if the folder pre-existed with looser permissions.
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        return dir.appendingPathComponent("\(prefix)-\(UUID().uuidString).\(ext)")
    }

    private static let lock = NSLock()
    /// Guarded by `lock`.
    nonisolated(unsafe) private static var active: Set<String> = []

    static func markActive(_ url: URL) { lock.withLock { _ = active.insert(url.standardizedFileURL.path) } }
    static func markInactive(_ url: URL) { lock.withLock { _ = active.remove(url.standardizedFileURL.path) } }
    static var activePaths: Set<String> { lock.withLock { active } }

    /// Removes decrypted temp files: everything when nothing is in use (the
    /// existing launch/quit sweep), otherwise everything except in-use files.
    static func sweep() {
        let keep = activePaths
        guard !keep.isEmpty else { JournalCrypto.cleanupTemporaryFiles(); return }
        let fm = FileManager.default
        let dir = JournalCrypto.temporaryDirectory
        for url in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        where !keep.contains(url.standardizedFileURL.path) {
            try? fm.removeItem(at: url)
        }
        JournalCrypto.removeLegacyDecryptedFiles(in: fm.temporaryDirectory)
    }
}

// MARK: - Recorder

/// What the recorder needs from the audio engine. `AVAudioRecorder` in the app; a fake in tests.
@MainActor
protocol MemoRecordingBackend: AnyObject {
    var isRecording: Bool { get }
    var currentTime: TimeInterval { get }
    func updateMeters()
    func averagePower() -> Float
    func stop()
}

@MainActor
private final class AVMemoBackend: MemoRecordingBackend {
    let recorder: AVAudioRecorder
    init(_ r: AVAudioRecorder) { recorder = r }
    var isRecording: Bool { recorder.isRecording }
    var currentTime: TimeInterval { recorder.currentTime }
    func updateMeters() { recorder.updateMeters() }
    func averagePower() -> Float { recorder.averagePower(forChannel: 0) }
    func stop() { recorder.stop() }
}

/// Records a voice memo to a temp file, exposes live levels, and hands back the bytes
/// (the caller stores them as an encrypted attachment and the temp file is deleted).
@MainActor
@Observable
final class AudioMemoRecorder: NSObject, AVAudioRecorderDelegate {
    enum State: Equatable { case idle, recording, denied, failed(String) }

    private(set) var state: State = .idle
    private(set) var elapsed: TimeInterval = 0
    private(set) var levels: [Float] = []

    /// Called with the recorded bytes when the time cap stops a recording on its own.
    @ObservationIgnored var onAutoStop: ((Data) -> Void)?
    /// Bytes from an auto-stop that nobody has collected yet (no `onAutoStop` listener).
    @ObservationIgnored private var pendingMemo: Data?

    @ObservationIgnored private var backend: MemoRecordingBackend?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var fileURL: URL?
    static let maxSeconds: TimeInterval = 600     // keeps memos well under the 25 MB attachment cap

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: begin()
        case .notDetermined:
            Task {
                let granted = await AVCaptureDevice.requestAccess(for: .audio)
                granted ? begin() : (state = .denied)
            }
        default: state = .denied
        }
    }

    private func begin() {
        // Plaintext audio lives only in the app's private 0700 temp folder, which is
        // wiped at launch, at quit and when App Lock engages — never the shared temp dir.
        let url: URL
        do { url = try Self.makeRecordingURL() } catch {
            state = .failed("Couldn't start recording"); return
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 22_050,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 48_000,
        ]
        do {
            let r = try AVAudioRecorder(url: url, settings: settings)
            r.delegate = self
            r.isMeteringEnabled = true
            guard r.record() else { state = .failed("Couldn't start recording"); return }
            adopt(backend: AVMemoBackend(r), fileURL: url)
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func adopt(backend b: MemoRecordingBackend, fileURL url: URL) {
        backend = b; fileURL = url
        MemoTempFiles.markActive(url)
        levels = []; elapsed = 0; state = .recording
    }

    /// A fresh file for a new recording, inside the private temp folder.
    nonisolated static func makeRecordingURL() throws -> URL {
        try MemoTempFiles.makeURL(prefix: MemoTempFiles.memoPrefix)
    }

    /// Where the current recording is being written (nil when idle).
    var recordingFileURL: URL? { fileURL }

    /// Test seam: start "recording" with a fake engine writing to `fileURL` (no microphone, no timer).
    func attachForTesting(backend b: MemoRecordingBackend, fileURL url: URL) { adopt(backend: b, fileURL: url) }

    func tick() {
        guard let b = backend, b.isRecording else { return }
        b.updateMeters()
        elapsed = b.currentTime
        levels.append(WaveformMath.level(fromDecibels: b.averagePower()))
        if levels.count > 400 { levels.removeFirst(levels.count - 400) }
        if elapsed >= Self.maxSeconds {
            // Never drop a capped recording: hand it to the popover (or park it until collected).
            guard let data = stop() else { return }
            if let onAutoStop { onAutoStop(data) } else { pendingMemo = data }
        }
    }

    /// Stops and returns the recorded bytes (nil if nothing usable). Always removes the temp file.
    func stop() -> Data? {
        timer?.invalidate(); timer = nil
        backend?.stop()
        backend = nil
        defer {
            if let u = fileURL { try? FileManager.default.removeItem(at: u); MemoTempFiles.markInactive(u) }
            fileURL = nil
        }
        if state == .recording { state = .idle }
        guard let u = fileURL, let data = try? Data(contentsOf: u), data.count > 1024 else { return nil }
        return data
    }

    /// The popover is going away: a live recording is stopped and returned so it can be attached.
    func finishForDismissal() -> Data? {
        guard state == .recording else { return takePendingMemo() }
        return stop()
    }

    /// Collects (once) a memo the time cap stopped while nobody was listening.
    func takePendingMemo() -> Data? {
        defer { pendingMemo = nil }
        return pendingMemo
    }

    func cancel() { _ = stop(); levels = []; elapsed = 0 }
}

struct AudioRecorderPopover: View {
    var vm: JournalViewModel
    let entry: JournalEntry
    @State private var recorder = AudioMemoRecorder()
    private let theme = ThemeManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Voice memo")
                .font(OmegaTheme.font(.caption, .semibold))
                .foregroundColor(theme.titleTextColor)

            WaveformBars(bars: WaveformMath.bars(samples: Array(recorder.levels.suffix(48)), count: 48),
                         tint: theme.accentColor)
                .frame(height: 36)
                .opacity(recorder.state == .recording ? 1 : 0.35)
                .accessibilityHidden(true)

            switch recorder.state {
            case .denied:
                Text("Microphone access is off. Enable it for Omega Journal in System Settings → Privacy & Security → Microphone.")
                    .font(OmegaTheme.font(.meta)).foregroundColor(theme.secondaryTextColor)
            case .failed(let msg):
                Text(msg).font(OmegaTheme.font(.meta)).foregroundColor(.red)
            default: EmptyView()
            }

            HStack {
                Text(WritingSessionMath.clock(recorder.elapsed)).monospacedDigit()
                    .font(OmegaTheme.font(.caption)).foregroundColor(theme.secondaryTextColor)
                Spacer()
                if recorder.state == .recording {
                    Button("Cancel") { recorder.cancel() }.buttonStyle(.borderless)
                    Button { save() } label: { Label("Stop & attach", systemImage: "stop.fill") }
                        .buttonStyle(.borderedProminent).tint(theme.accentColor)
                } else {
                    Button { recorder.start() } label: { Label("Record", systemImage: "mic.fill") }
                        .buttonStyle(.borderedProminent).tint(theme.accentColor)
                }
            }
        }
        .padding(14)
        .frame(width: 280)
        .onAppear {
            recorder.onAutoStop = { [vm, entry] data in
                Self.attach(data, to: entry, vm: vm)
                vm.showToast("Voice memo reached 10 minutes and was attached")
            }
        }
        // A transient popover closes on any outside click: keep what was recorded rather than discard it.
        .onDisappear {
            recorder.onAutoStop = nil
            if let data = recorder.finishForDismissal() { Self.attach(data, to: entry, vm: vm) }
        }
    }

    private func save() {
        guard let data = recorder.stop() else { vm.showToast("Nothing was recorded", isError: true); return }
        Self.attach(data, to: entry, vm: vm)
        dismiss()
    }

    private static func attach(_ data: Data, to entry: JournalEntry, vm: JournalViewModel) {
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "-")
        vm.addAttachment(to: entry, data: data, filename: "Voice memo \(stamp).m4a", mimeType: "audio/mp4")
    }
}

// MARK: - Waveform + player

struct WaveformBars: View {
    let bars: [Float]
    var progress: Double = 0
    var tint: Color

    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .center, spacing: 2) {
                ForEach(bars.indices, id: \.self) { i in
                    let played = Double(i) / Double(max(bars.count, 1)) < progress
                    Capsule()
                        .fill(tint.opacity(played ? 1 : 0.4))
                        .frame(height: max(3, CGFloat(bars[i]) * geo.size.height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Inline player for an audio attachment. Audio is decrypted in memory only (the waveform pass
/// uses a temp file that is deleted immediately).
@MainActor
@Observable
final class AudioMemoPlayer: NSObject, AVAudioPlayerDelegate {
    private(set) var isPlaying = false
    private(set) var progress: Double = 0
    private(set) var bars: [Float] = []
    private(set) var duration: TimeInterval = 0
    private(set) var failed = false

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var timer: Timer?
    private static var barCache: [String: [Float]] = [:]

    func load(_ attachment: Attachment, db: DatabaseManager) {
        guard player == nil, let data = db.readAttachmentData(attachment) else { failed = player == nil; return }
        do {
            let p = try AVAudioPlayer(data: data)
            p.delegate = self
            p.prepareToPlay()
            player = p
            duration = p.duration
        } catch { failed = true; return }
        if let cached = Self.barCache[attachment.id] { bars = cached; return }
        Task.detached(priority: .utility) { [data] in
            let samples = Self.samples(from: data)
            let computed = WaveformMath.bars(samples: samples, count: 48)
            await MainActor.run {
                Self.barCache[attachment.id] = computed
                self.bars = computed
            }
        }
    }

    func toggle() {
        guard let p = player else { return }
        if p.isPlaying { p.pause(); isPlaying = false; timer?.invalidate() }
        else {
            if p.currentTime >= p.duration - 0.05 { p.currentTime = 0 }
            p.play(); isPlaying = true
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let p = self.player else { return }
                    self.progress = p.duration > 0 ? p.currentTime / p.duration : 0
                }
            }
        }
    }

    func stop() { player?.stop(); timer?.invalidate(); isPlaying = false }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false; self.progress = 0; self.timer?.invalidate()
        }
    }

    /// Absolute sample magnitudes (≤ ~4000) for the waveform; temp file removed before returning.
    nonisolated private static func samples(from data: Data) -> [Float] {
        guard let url = try? MemoTempFiles.makeURL(prefix: MemoTempFiles.wavePrefix) else { return [] }
        defer { try? FileManager.default.removeItem(at: url) }
        guard (try? data.write(to: url, options: .atomic)) != nil, let file = try? AVAudioFile(forReading: url) else { return [] }
        let frames = AVAudioFrameCount(min(file.length, 20_000_000))
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames),
              (try? file.read(into: buf, frameCount: frames)) != nil, let ch = buf.floatChannelData?[0] else { return [] }
        let n = Int(buf.frameLength)
        let stride = max(1, n / 4000)
        return (0..<(n / stride)).map { abs(ch[$0 * stride]) }
    }
}

// MARK: - On-device transcription

/// Turns a voice memo into text. The app uses `SpeechMemoTranscriber`; tests inject a fake.
protocol MemoTranscriber: AnyObject {
    func transcribe(audio: Data) async throws -> String
}

enum MemoTranscriptionError: Error, Equatable, LocalizedError {
    case unavailable(String), denied, unreadable, nothingHeard, failed

    var errorDescription: String? {
        switch self {
        case .unavailable(let why): return why
        case .denied:
            return "Speech recognition is off for Omega Journal. Turn it on in System Settings → Privacy & Security → Speech Recognition."
        case .unreadable: return "This voice memo couldn't be read."
        case .nothingHeard: return "No speech was found in this memo."
        case .failed: return "Transcription couldn't finish. Try again."
        }
    }
}

enum MemoTranscription {
    static let usageDescriptionKey = "NSSpeechRecognitionUsageDescription"

    /// Cached per launch: building a recognizer to ask this isn't free.
    private static var cachedOnDeviceSupport: Bool?

    /// Offered on macOS 26+, only when the bundle can ask for permission, and only
    /// when the recognizer for the user's language runs on this Mac (never a server).
    static var availability: TranscriptAvailability {
        let osSupported: Bool
        if #available(macOS 26.0, *) { osSupported = true } else { osSupported = false }
        let hasUsage = Bundle.main.object(forInfoDictionaryKey: usageDescriptionKey) != nil
        guard osSupported, hasUsage else {
            return TranscriptAvailability.decide(osSupported: osSupported, hasUsageDescription: hasUsage, onDeviceSupported: false)
        }
        if cachedOnDeviceSupport == nil {
            cachedOnDeviceSupport = SFSpeechRecognizer(locale: .current)?.supportsOnDeviceRecognition ?? false
        }
        return TranscriptAvailability.decide(osSupported: true, hasUsageDescription: true,
                                             onDeviceSupported: cachedOnDeviceSupport ?? false)
    }

    /// Decrypts the memo in memory and transcribes it.
    static func transcribe(_ attachment: Attachment, db: DatabaseManager, using transcriber: MemoTranscriber) async throws -> String {
        guard let data = db.readAttachmentData(attachment) else { throw MemoTranscriptionError.unreadable }
        let raw = try await transcriber.transcribe(audio: data)
        let text = TranscriptText.clean(raw)
        guard !text.isEmpty else { throw MemoTranscriptionError.nothingHeard }
        return text
    }
}

/// `SFSpeechRecognizer` with `requiresOnDeviceRecognition = true`: audio never leaves
/// the Mac. The decrypted audio is written to the private temp folder for the
/// recognizer and deleted as soon as it finishes.
final class SpeechMemoTranscriber: MemoTranscriber {
    func transcribe(audio: Data) async throws -> String {
        if case .unavailable(let why) = MemoTranscription.availability { throw MemoTranscriptionError.unavailable(why) }
        switch await Self.authorization() {
        case .authorized: break
        case .denied, .restricted: throw MemoTranscriptionError.denied
        default: throw MemoTranscriptionError.denied
        }
        let url = try MemoTempFiles.makeURL(prefix: MemoTempFiles.transcribePrefix)
        MemoTempFiles.markActive(url)
        defer {
            try? FileManager.default.removeItem(at: url)
            MemoTempFiles.markInactive(url)
        }
        do { try audio.write(to: url, options: .atomic) } catch { throw MemoTranscriptionError.unreadable }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return try await Self.recognize(fileURL: url, locale: .current)
    }

    nonisolated private static func authorization() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    @concurrent
    nonisolated private static func recognize(fileURL: URL, locale: Locale) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.supportsOnDeviceRecognition else {
            throw MemoTranscriptionError.unavailable("On-device transcription isn't available for your language on this Mac.")
        }
        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        let once = ResumeOnce()
        return try await withCheckedThrowingContinuation { continuation in
            _ = recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    if once.claim() { continuation.resume(returning: result.bestTranscription.formattedString) }
                } else if error != nil {
                    // "No speech detected" also arrives as an error.
                    if once.claim() { continuation.resume(throwing: MemoTranscriptionError.nothingHeard) }
                }
                withExtendedLifetime(recognizer) {}
            }
        }
    }

    /// Resumes a continuation exactly once from the recognizer's callback queue.
    nonisolated private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
    }
}

/// State for one transcription request (memo row popover or editor sheet).
@MainActor
@Observable
final class MemoTranscriptionModel {
    enum State: Equatable { case idle, working, done(String), failed(String) }
    private(set) var state: State = .idle
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let transcriber: MemoTranscriber

    init(transcriber: MemoTranscriber? = nil) {
        self.transcriber = transcriber ?? SpeechMemoTranscriber()
    }

    func start(_ attachment: Attachment, db: DatabaseManager) {
        task?.cancel()
        state = .working
        task = Task { [transcriber] in
            do {
                let text = try await MemoTranscription.transcribe(attachment, db: db, using: transcriber)
                if !Task.isCancelled { state = .done(text) }
            } catch {
                if Task.isCancelled { return }
                let message = (error as? LocalizedError)?.errorDescription ?? MemoTranscriptionError.failed.errorDescription ?? ""
                state = .failed(message)
            }
        }
    }

    /// Test seam: waits for the current request.
    func waitForCompletion() async { await task?.value }

    func cancel() { task?.cancel(); task = nil; if state == .working { state = .idle } }
}

/// Transcript panel shared by the reader's memo row (popover) and the editor (sheet).
struct MemoTranscriptPanel: View {
    let attachment: Attachment
    let db: DatabaseManager
    /// Inserts the transcript into the entry's text. Nil hides the button.
    var onInsert: ((String) -> Void)?
    var onClose: () -> Void
    @State private var model: MemoTranscriptionModel
    private let theme = ThemeManager.shared

    init(attachment: Attachment, db: DatabaseManager, transcriber: MemoTranscriber? = nil,
         onInsert: ((String) -> Void)?, onClose: @escaping () -> Void) {
        self.attachment = attachment
        self.db = db
        self.onInsert = onInsert
        self.onClose = onClose
        _model = State(initialValue: MemoTranscriptionModel(transcriber: transcriber))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "waveform").foregroundColor(theme.accentColor).accessibilityHidden(true)
                Text("Transcript").font(OmegaTheme.font(.caption, .semibold)).foregroundColor(theme.titleTextColor)
                Spacer()
                Text("On this Mac").font(OmegaTheme.font(.meta)).foregroundColor(theme.secondaryTextColor)
            }

            switch model.state {
            case .idle, .working:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Transcribing…").font(OmegaTheme.font(.caption)).foregroundColor(theme.secondaryTextColor)
                }
                .accessibilityElement(children: .combine)
                .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            case .failed(let message):
                Text(message).font(OmegaTheme.font(.caption)).foregroundColor(theme.dangerColor)
                    .fixedSize(horizontal: false, vertical: true)
            case .done(let text):
                ScrollView {
                    Text(text)
                        .font(OmegaTheme.font(.body))
                        .foregroundColor(theme.bodyTextColor)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
            }

            HStack {
                Spacer()
                switch model.state {
                case .done(let text):
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                    if let onInsert {
                        Button("Insert into entry") { onInsert(text); onClose() }
                            .buttonStyle(.borderedProminent).tint(theme.accentColor)
                            .keyboardShortcut(.defaultAction)
                            .help("Adds the transcript to the entry's text, so it's encrypted and searchable")
                    }
                case .failed:
                    Button("Close") { onClose() }
                    Button("Try again") { model.start(attachment, db: db) }
                        .buttonStyle(.borderedProminent).tint(theme.accentColor)
                default:
                    Button("Cancel") { model.cancel(); onClose() }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(14)
        .frame(width: 340)
        .onAppear { if model.state == .idle { model.start(attachment, db: db) } }
        .onDisappear { model.cancel() }
    }
}

struct AudioMemoRow: View {
    let attachment: Attachment
    let db: DatabaseManager
    /// Adds a transcript to the entry's text (shown as "Insert into entry"). Nil = copy only.
    var onInsertTranscript: ((String) -> Void)? = nil
    @State private var player = AudioMemoPlayer()
    @State private var showTranscript = false
    private let theme = ThemeManager.shared

    var body: some View {
        HStack(spacing: 10) {
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(OmegaTheme.font(.title))
                    .foregroundColor(theme.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(player.failed)
            .accessibilityLabel(player.isPlaying ? "Pause voice memo" : "Play voice memo")

            WaveformBars(bars: player.bars.isEmpty ? Array(repeating: 0.2, count: 48) : player.bars,
                         progress: player.progress, tint: theme.accentColor)
                .frame(height: 28)
                .accessibilityHidden(true)

            Text(player.failed ? "Unreadable" : WritingSessionMath.clock(player.duration))
                .font(OmegaTheme.font(.meta)).monospacedDigit()
                .foregroundColor(theme.secondaryTextColor)

            if MemoTranscription.availability.isAvailable && !player.failed {
                Button { showTranscript = true } label: {
                    Label("Transcribe", systemImage: "text.bubble").labelStyle(.iconOnly)
                        .font(OmegaTheme.font(.caption, .medium))
                        .foregroundColor(theme.accentColor)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Transcribe on this Mac")
                .accessibilityLabel("Transcribe voice memo")
                .popover(isPresented: $showTranscript, arrowEdge: .bottom) {
                    MemoTranscriptPanel(attachment: attachment, db: db, onInsert: onInsertTranscript) {
                        showTranscript = false
                    }
                }
            }
        }
        .onAppear { player.load(attachment, db: db) }
        .onDisappear { player.stop() }
    }
}
