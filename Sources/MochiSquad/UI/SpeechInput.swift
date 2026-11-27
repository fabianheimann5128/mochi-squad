import AVFoundation
import Speech
import SwiftUI

/// Speech input: records through the microphone, writes the recognised words into the input field as they come
/// and provides the level for the display.
@MainActor final class SpeechInput: ObservableObject {
    static let bars = 24
    @Published private(set) var listening = false
    /// Latest levels from 0 to 1, the newest last.
    @Published private(set) var levels = [CGFloat](repeating: 0, count: SpeechInput.bars)
    @Published var issue: String?

    /// Passes the audio on to the recognition in progress; the tap runs on an audio thread.
    private final class Feed: @unchecked Sendable {
        private let lock = NSLock()
        private var request: SFSpeechAudioBufferRecognitionRequest?
        func set(_ next: SFSpeechAudioBufferRecognitionRequest?) { lock.lock(); request = next; lock.unlock() }
        func append(_ buffer: AVAudioPCMBuffer) { lock.lock(); request?.append(buffer); lock.unlock() }
        func end() { lock.lock(); request?.endAudio(); request = nil; lock.unlock() }
    }

    private let engine = AVAudioEngine()
    private let feed = Feed()
    private var recognizer: SFSpeechRecognizer?
    private var task: SFSpeechRecognitionTask?
    /// Counts recordings and segments: results of older segments are discarded.
    private var round = 0
    /// Text that was already in the field before the current segment.
    private var committed = ""
    /// What the recognition wrote into the field last; if the field differs, the user typed.
    private var written = ""
    /// The latest result of the current segment.
    private var heard = ""
    private var peak: CGFloat = 0
    private var lastLevel = Date.distantPast

    /// The start the user asked for last. A stop clears it, so a permission answer that arrives late
    /// (after the user left the chat or the app) cannot switch the microphone on.
    private var wanted: UUID?

    func toggle(text: Binding<String>) {
        if listening || wanted != nil { stop() } else { start(text) }
    }

    private func start(_ text: Binding<String>) {
        issue = nil
        let request = UUID()
        wanted = request
        SFSpeechRecognizer.requestAuthorization { status in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in
                    guard self.wanted == request else { return }
                    self.wanted = nil
                    guard status == .authorized, granted else {
                        self.issue = t("Allow Mochi Squad to use the microphone and speech recognition in System Settings under “Privacy & Security”.",
                                       "Erlaube Mochi Squad in den Systemeinstellungen unter „Datenschutz & Sicherheit“ das Mikrofon und die Spracherkennung.")
                        return
                    }
                    // Recording starts only in front of the user's eyes.
                    guard NSApp.isActive, !NSApp.isHidden else { return }
                    self.begin(text)
                }
            }
        }
    }

    private func begin(_ text: Binding<String>) {
        guard !listening else { return }
        // Dictation follows the interface language; if that is not offered, the system's language.
        guard let recognizer = SFSpeechRecognizer(locale: L10n.language.locale) ?? SFSpeechRecognizer(), recognizer.isAvailable else {
            issue = t("Speech recognition is not available right now.", "Die Spracherkennung ist gerade nicht verfügbar.")
            return
        }
        let input = engine.inputNode, format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { issue = t("No microphone was found.", "Es wurde kein Mikrofon gefunden."); return }
        self.recognizer = recognizer
        committed = text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        written = text.wrappedValue
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self, feed] buffer, _ in
            feed.append(buffer)
            let level = Self.level(of: buffer)
            Task { @MainActor in self?.push(level) }
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            issue = t("The microphone could not be started.", "Das Mikrofon ließ sich nicht starten.")
            input.removeTap(onBus: 0)
            return
        }
        listening = true
        recognize(into: text)
    }

    /// Starts a recognition segment. After a pause in speech the recognition completes it; then the next begins
    /// without interrupting the recording.
    private func recognize(into text: Binding<String>) {
        guard listening, let recognizer else { return }
        round += 1
        let current = round
        heard = ""
        task?.cancel()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Where possible, recognition stays on the Mac.
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        feed.set(request)
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let spoken = result?.bestTranscription.formattedString ?? ""
            let final = result?.isFinal == true, failed = error != nil
            Task { @MainActor in
                guard let self, self.round == current else { return }
                // If the user typed in between, their text is the basis for everything that follows.
                // The current segment is then already in the field; a fresh segment delivers only what is new.
                if text.wrappedValue != self.written {
                    self.committed = text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.written = text.wrappedValue
                    self.recognize(into: text)
                    return
                }
                // During a long stretch of speech the recognition may start over inside the same segment and from
                // then on report only what came after. What it had heard so far is kept, not overwritten.
                if Self.startedOver(previous: self.heard, latest: spoken) {
                    self.committed = Self.join(self.committed, self.heard)
                }
                if !spoken.isEmpty { self.heard = spoken }
                let joined = Self.join(self.committed, self.heard)
                if !self.heard.isEmpty, text.wrappedValue != joined { text.wrappedValue = joined }
                self.written = text.wrappedValue
                if final {
                    self.committed = joined
                    self.recognize(into: text)
                } else if failed {
                    // A segment ends with an error after a long time (or a short network hiccup). The text is kept;
                    // recording goes on with a new segment, unless this one never heard anything.
                    self.committed = joined
                    if self.heard.isEmpty { self.stop() } else { self.recognize(into: text) }
                }
            }
        }
    }

    /// Ends the recording, or cancels a start that still waits for permission. The text in the field stays,
    /// later results of the recognition are no longer taken over.
    func stop() {
        wanted = nil
        guard listening else { return }
        listening = false
        round += 1
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        feed.end()
        task?.cancel()
        task = nil
        peak = 0
        levels = [CGFloat](repeating: 0, count: Self.bars)
    }

    /// At most about 16 new bars per second: calm enough for the eye, fast enough for the voice.
    private func push(_ level: CGFloat) {
        guard listening else { return }
        peak = max(peak, level)
        guard Date().timeIntervalSince(lastLevel) >= 0.06 else { return }
        lastLevel = Date()
        levels.removeFirst()
        levels.append(peak * 0.75 + (levels.last ?? 0) * 0.25)
        peak = 0
    }

    /// True if `latest` is not a revision of `previous` but the start of a new stretch of speech: it no longer begins
    /// with the same words, or it is far shorter. Partial results only ever revise their end and grow.
    nonisolated static func startedOver(previous: String, latest: String) -> Bool {
        func words(_ text: String) -> [String] {
            text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        }
        let before = words(previous), now = words(latest)
        guard !before.isEmpty, !now.isEmpty else { return false }
        if before.count >= 6, now.count * 2 < before.count { return true }
        let compared = min(2, before.count, now.count)
        return now.count < before.count && Array(now.prefix(compared)) != Array(before.prefix(compared))
    }

    nonisolated static func join(_ before: String, _ spoken: String) -> String {
        before.isEmpty ? spoken : spoken.isEmpty ? before : before + " " + spoken
    }

    /// Loudness of an audio buffer from 0 to 1 (RMS, spread for speech).
    nonisolated static func level(of buffer: AVAudioPCMBuffer) -> CGFloat {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
        return scaled(rms: (sum / Float(buffer.frameLength)).squareRoot())
    }

    nonisolated static func scaled(rms: Float) -> CGFloat { CGFloat(min(1, max(0, rms * 14))) }
}

/// Level display: soft bars that move with the voice.
struct Waveform: View {
    let levels: [CGFloat]
    var body: some View {
        GeometryReader { area in
            HStack(alignment: .center, spacing: 2) {
                ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                    Capsule().fill(Desk.accent).frame(width: 2, height: max(2.5, level * area.size.height))
                }
            }
            .frame(width: area.size.width, height: area.size.height)
            .animation(.linear(duration: 0.07), value: levels)
        }.accessibilityHidden(true)
    }
}

/// Microphone button with level display. The recognised words go straight into `draft`.
struct MicControl: View {
    @Binding var draft: String
    @StateObject private var speech = SpeechInput()

    var body: some View {
        HStack(spacing: 8) {
            if speech.listening {
                Waveform(levels: speech.levels).frame(width: CGFloat(SpeechInput.bars) * 4 - 2, height: 24)
                    .transition(.opacity.combined(with: .scale(scale: 0.6, anchor: .trailing)))
            }
            Button { speech.toggle(text: $draft) } label: {
                Image(systemName: speech.listening ? "stop.fill" : "mic").font(.system(size: speech.listening ? 11 : 14, weight: .medium))
                    .foregroundStyle(speech.listening ? Color.white : Desk.dim)
                    .frame(width: 32, height: 32).background(speech.listening ? Desk.accent : Desk.card, in: Circle())
                    .overlay { Circle().strokeBorder(speech.listening ? Color.clear : Desk.edge) }.contentShape(Circle())
            }
            .buttonStyle(.plain).help(speech.listening ? t("Stop recording", "Aufnahme beenden") : t("Dictate a message", "Nachricht einsprechen"))
            .accessibilityLabel(speech.listening ? t("Stop recording", "Aufnahme beenden") : t("Dictate a message", "Nachricht einsprechen"))
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: speech.listening)
        .popover(isPresented: Binding(get: { speech.issue != nil }, set: { if !$0 { speech.issue = nil } }), arrowEdge: .top) {
            Text(speech.issue ?? "").font(.system(size: 13)).frame(width: 280).padding(14)
        }
        // When the field is emptied (sent), the recording ends; otherwise the text would come right back.
        .onChange(of: draft) { _, text in if text.isEmpty { speech.stop() } }
        .onDisappear { speech.stop() }
        // The microphone never stays open when the app is hidden or goes to the background.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in speech.stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didHideNotification)) { _ in speech.stop() }
    }
}
