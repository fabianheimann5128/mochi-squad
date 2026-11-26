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

    /// Reicht den Ton an die gerade laufende Erkennung weiter; der Abgriff läuft auf einem Audio-Thread.
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
    /// Zählt Aufnahmen und Abschnitte: Ergebnisse älterer Abschnitte werden verworfen.
    private var round = 0
    /// Text, der vor dem laufenden Abschnitt schon im Feld stand.
    private var committed = ""
    /// Was die Erkennung zuletzt ins Feld geschrieben hat; weicht das Feld davon ab, hat der Nutzer getippt.
    private var written = ""
    private var peak: CGFloat = 0
    private var lastLevel = Date.distantPast

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
        let input = engine.inputNode, format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { issue = "Es wurde kein Mikrofon gefunden."; return }
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
            issue = "Das Mikrofon ließ sich nicht starten."
            input.removeTap(onBus: 0)
            return
        }
        listening = true
        recognize(into: text)
    }

    /// Startet einen Erkennungsabschnitt. Nach einer Sprechpause schließt die Erkennung ihn ab; dann beginnt der nächste,
    /// ohne dass die Aufnahme unterbrochen wird.
    private func recognize(into text: Binding<String>) {
        guard listening, let recognizer else { return }
        round += 1
        let current = round
        task?.cancel()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Wo möglich, bleibt die Erkennung auf dem Mac.
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        feed.set(request)
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let spoken = result?.bestTranscription.formattedString ?? ""
            let final = result?.isFinal == true, failed = error != nil
            Task { @MainActor in
                guard let self, self.round == current else { return }
                // Hat der Nutzer zwischendurch getippt, zählt sein Text als Grundlage für alles Weitere.
                // Der laufende Abschnitt steckt dann schon im Feld; ein frischer Abschnitt liefert nur noch Neues.
                if text.wrappedValue != self.written {
                    self.committed = text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.written = text.wrappedValue
                    self.recognize(into: text)
                    return
                }
                let joined = Self.join(self.committed, spoken)
                if !spoken.isEmpty, text.wrappedValue != joined { text.wrappedValue = joined }
                self.written = text.wrappedValue
                if final {
                    self.committed = Self.join(self.committed, spoken)
                    self.recognize(into: text)
                } else if failed {
                    self.stop()
                }
            }
        }
    }

    /// Beendet die Aufnahme. Der Text im Feld bleibt, spätere Ergebnisse der Erkennung werden nicht mehr übernommen.
    func stop() {
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

    /// Höchstens etwa 16 neue Balken je Sekunde: ruhig genug fürs Auge, schnell genug für die Stimme.
    private func push(_ level: CGFloat) {
        guard listening else { return }
        peak = max(peak, level)
        guard Date().timeIntervalSince(lastLevel) >= 0.06 else { return }
        lastLevel = Date()
        levels.removeFirst()
        levels.append(peak * 0.75 + (levels.last ?? 0) * 0.25)
        peak = 0
    }

    nonisolated static func join(_ before: String, _ spoken: String) -> String {
        before.isEmpty ? spoken : spoken.isEmpty ? before : before + " " + spoken
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
            .animation(.linear(duration: 0.07), value: levels)
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
        // Wird das Feld geleert (gesendet), endet die Aufnahme; sonst käme der Text gleich wieder hinein.
        .onChange(of: draft) { _, text in if text.isEmpty { speech.stop() } }
        .onDisappear { speech.stop() }
        // Das Mikrofon bleibt nie offen, wenn die App ausgeblendet wird oder in den Hintergrund geht.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in speech.stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didHideNotification)) { _ in speech.stop() }
    }
}
