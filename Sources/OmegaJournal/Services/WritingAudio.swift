import SwiftUI
import AVFoundation
import OmegaJournalCore

extension Attachment {
    var isAudio: Bool { mimeType.hasPrefix("audio/") }
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
final class AudioMemoRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    enum State: Equatable { case idle, recording, denied, failed(String) }

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var levels: [Float] = []

    /// Called with the recorded bytes when the time cap stops a recording on its own.
    var onAutoStop: ((Data) -> Void)?
    /// Bytes from an auto-stop that nobody has collected yet (no `onAutoStop` listener).
    private var pendingMemo: Data?

    private var backend: MemoRecordingBackend?
    private var timer: Timer?
    private var fileURL: URL?
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
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("omega-memo-\(UUID().uuidString).m4a")
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
        levels = []; elapsed = 0; state = .recording
    }

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
        defer { if let u = fileURL { try? FileManager.default.removeItem(at: u) }; fileURL = nil }
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
    @ObservedObject var vm: JournalViewModel
    let entry: JournalEntry
    @StateObject private var recorder = AudioMemoRecorder()
    @ObservedObject private var theme = ThemeManager.shared
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
final class AudioMemoPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var bars: [Float] = []
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var failed = false

    private var player: AVAudioPlayer?
    private var timer: Timer?
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
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("omega-wave-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        guard (try? data.write(to: url)) != nil, let file = try? AVAudioFile(forReading: url) else { return [] }
        let frames = AVAudioFrameCount(min(file.length, 20_000_000))
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames),
              (try? file.read(into: buf, frameCount: frames)) != nil, let ch = buf.floatChannelData?[0] else { return [] }
        let n = Int(buf.frameLength)
        let stride = max(1, n / 4000)
        return (0..<(n / stride)).map { abs(ch[$0 * stride]) }
    }
}

struct AudioMemoRow: View {
    let attachment: Attachment
    let db: DatabaseManager
    @StateObject private var player = AudioMemoPlayer()
    @ObservedObject private var theme = ThemeManager.shared

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
        }
        .onAppear { player.load(attachment, db: db) }
        .onDisappear { player.stop() }
    }
}
