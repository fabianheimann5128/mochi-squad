import AVFoundation
import Speech
import SwiftUI

/// Spracheingabe: nimmt über das Mikrofon auf, schreibt die erkannten Wörter laufend ins Eingabefeld
/// und liefert den Pegel für die Anzeige.
@MainActor final class SpeechInput: ObservableObject {
    static let bars = 24
    @Published private(set) var listening = false
    /// Jüngste Pegel von 0 bis 1, der neueste zuletzt.
    @Published private(set) var levels = [CGFloat](repeating: 0, count: SpeechInput.bars)
    @Published var issue: String?

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    func toggle(text: Binding<String>) {
        if listening { stop() } else { start(text) }
    }

    private func start(_ text: Binding<String>) {
        issue = nil
        SFSpeechRecognizer.requestAuthorization { status in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in
                    guard status == .authorized, granted else {
                        self.issue = "Erlaube Mochi Squad in den Systemeinstellungen unter „Datenschutz & Sicherheit“ das Mikrofon und die Spracherkennung."
                        return
                    }
                    self.begin(text)
                }
            }
        }
    }

    private func begin(_ text: Binding<String>) {
        guard !listening else { return }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "de-DE")) ?? SFSpeechRecognizer(), recognizer.isAvailable else {
            issue = "Die Spracherkennung ist gerade nicht verfügbar."
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Wo möglich, bleibt die Erkennung auf dem Mac.
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        let input = engine.inputNode, format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { issue = "Es wurde kein Mikrofon gefunden."; return }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            request.append(buffer)
            let level = Self.level(of: buffer)
            Task { @MainActor in self?.push(level) }
        }
        let before = text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let spoken = result?.bestTranscription.formattedString ?? ""
            let finished = error != nil || result?.isFinal == true
            Task { @MainActor in
                if !spoken.isEmpty { text.wrappedValue = before.isEmpty ? spoken : before + " " + spoken }
                if finished { self?.stop() }
            }
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            issue = "Das Mikrofon ließ sich nicht starten."
            task?.cancel(); task = nil
            input.removeTap(onBus: 0)
            return
        }
        self.request = request
        listening = true
    }

    func stop() {
        guard listening else { return }
        listening = false
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.finish()
        request = nil; task = nil
        levels = [CGFloat](repeating: 0, count: Self.bars)
    }

    private func push(_ level: CGFloat) {
        guard listening else { return }
        levels.removeFirst()
        // Leicht geglättet, damit die Balken nicht flackern.
        levels.append(level * 0.7 + (levels.last ?? 0) * 0.3)
    }

    /// Lautstärke eines Tonpuffers von 0 bis 1 (Effektivwert, für Sprache gespreizt).
    nonisolated static func level(of buffer: AVAudioPCMBuffer) -> CGFloat {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
        return scaled(rms: (sum / Float(buffer.frameLength)).squareRoot())
    }

    nonisolated static func scaled(rms: Float) -> CGFloat { CGFloat(min(1, max(0, rms * 14))) }
}

/// Pegelanzeige: weiche Balken, die mit der Stimme ausschlagen.
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
            .animation(.easeOut(duration: 0.12), value: levels)
        }.accessibilityHidden(true)
    }
}

/// Mikrofonknopf mit Pegelanzeige. Die erkannten Wörter laufen direkt in `draft`.
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
            .buttonStyle(.plain).help(speech.listening ? "Aufnahme beenden" : "Nachricht einsprechen")
            .accessibilityLabel(speech.listening ? "Aufnahme beenden" : "Nachricht einsprechen")
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: speech.listening)
        .popover(isPresented: Binding(get: { speech.issue != nil }, set: { if !$0 { speech.issue = nil } }), arrowEdge: .top) {
            Text(speech.issue ?? "").font(.system(size: 13)).frame(width: 280).padding(14)
        }
        .onDisappear { speech.stop() }
    }
}
