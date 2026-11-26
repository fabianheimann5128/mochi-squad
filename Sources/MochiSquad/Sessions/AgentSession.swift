import AppKit
import SwiftTerm

/// Eine Rückfrage des Clients in der Konsole, etwa die Freigabe eines Befehls, mit ihren Antworten.
struct ClientPrompt: Equatable {
    struct Option: Equatable, Identifiable {
        let key, label: String
        var id: String { key }
    }
    let context: [String]
    let options: [Option]
    /// Bei Menüs ohne Nummern: Position der markierten Zeile; gewählt wird mit Pfeiltasten und Return.
    var marked: Int?
}

/// Was eine Sitzung zum Start braucht. Wird als spec.json für launcher.py geschrieben.
/// Pfade stehen bewusst nicht darin: Der Starter leitet sie aus dem Sitzungsordner ab.
struct SessionSpec: Encodable {
    struct AgentPart: Encodable {
        let name, job, instructions, persona, model, effort: String
        let canEdit, isCoordinator, fullAccess, computerUse: Bool
    }
    let provider: String
    let project: String
    let task: String
    let sessionId: String
    let owner: String
    let agent: AgentPart
    let team: [String]
    /// Weiteres ChatGPT-Abo oder leer für die normale Anmeldung.
    let account: String
    let postEnabled = true
    var parentChat: String?

    init(agent: Agent, project: URL, task: String, sessionID: UUID, owner: String, team: [String], parentChat: String?) {
        provider = agent.provider.rawValue
        self.project = project.path
        self.task = task
        sessionId = sessionID.uuidString.lowercased()
        self.owner = owner
        self.agent = AgentPart(name: agent.name, job: agent.jobTitle, instructions: agent.instructions, persona: agent.persona,
                               model: agent.model, effort: agent.effort, canEdit: agent.canEdit, isCoordinator: agent.isCoordinator,
                               fullAccess: agent.fullAccess == true, computerUse: agent.computerUse == true)
        self.team = team
        account = agent.provider == .codex ? agent.account ?? "" : ""
        self.parentChat = parentChat
    }
}

enum LaunchError: LocalizedError {
    case resourcesMissing, startFailed
    var errorDescription: String? {
        switch self {
        case .resourcesMissing: return "Der App fehlen Bestandteile. Installiere Mochi Squad bitte neu."
        case .startFailed: return "Die Sitzung konnte nicht gestartet werden."
        }
    }
}

/// Eine laufende Agenten-Sitzung im eingebetteten Terminal.
@MainActor final class AgentSession: NSObject, Identifiable, ObservableObject {
    let id = UUID()
    let agentID: UUID
    /// Zugriffsstufe, mit der diese Sitzung gestartet wurde; sie gilt, bis die Sitzung endet.
    let access: Agent.Access
    /// Einstellungen des Agenten beim Start (siehe Agent.sessionSignature).
    let signature: String
    /// Der Starter wartet in der Konsole auf eine Anmeldung beim Client.
    @Published private(set) var needsLogin = false
    let project: URL
    let provider: Provider
    let task: String
    let started = Date()
    let terminal = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 440))

    @Published private(set) var usage = Usage()
    @Published private(set) var status = "Wird gestartet"
    @Published private(set) var isRunning = false
    /// Der Client schreibt gerade in seinen Verlauf, arbeitet also.
    @Published private(set) var working = false
    /// Gesetzt, solange der Client in der Konsole auf eine Auswahl wartet.
    @Published private(set) var prompt: ClientPrompt?
    @Published var replyDraft = ""
    private(set) var endedAt: Date?

    /// Agenten-Post: (Empfänger, Text) → Rückmeldung für den Absender.
    var onPost: ((String, String) -> String)?
    /// Neuer Verlauf erkannt (Pfad der Verlaufsdatei).
    var onJournal: ((String) -> Void)?

    /// Startdaten und Statusdatei. In den App-Daten, die Agenten weder lesen noch beschreiben dürfen.
    private let folder: URL
    /// Postausgang: der einzige Ort außerhalb des Projekts, den die Sandbox dieser Sitzung beschreiben darf.
    private let outbox: URL
    private var watcher: Process?
    private var timer: Timer?
    private var pendingSubmit: Date?
    private var sessionKey: String { id.uuidString.lowercased() }

    init(agent: Agent, project: URL, task: String) throws {
        agentID = agent.id
        access = agent.access
        signature = agent.sessionSignature
        self.project = project
        provider = agent.provider
        self.task = task
        let key = id.uuidString.lowercased()
        folder = AppPaths.sessions.appendingPathComponent(key, isDirectory: true)
        outbox = AppPaths.outboxes.appendingPathComponent(key, isDirectory: true)
        for directory in [folder, outbox] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        super.init()
        terminal.processDelegate = self
        terminal.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        terminal.nativeBackgroundColor = NSColor(srgbRed: 0.08, green: 0.08, blue: 0.08, alpha: 1)
        terminal.nativeForegroundColor = NSColor(white: 0.93, alpha: 1)
    }

    /// Startet den Client über launcher.py. `tools` sind Konfiguration und Token des Werkzeugservers für den Koordinator.
    func launch(spec: SessionSpec, tools: (config: String, token: String)?) throws {
        guard let launcher = AppPaths.script("launcher") else { throw LaunchError.resourcesMissing }
        let specFile = folder.appendingPathComponent("spec.json")
        do {
            try JSONFile.save(spec, to: specFile)
            if let tools { try JSONFile.write(Data(tools.config.utf8), to: folder.appendingPathComponent("mcp.json")) }
        } catch { throw LaunchError.startFailed }

        var env = ProcessInfo.processInfo.environment
        for key in env.keys where key.hasPrefix("CLAUDE_CODE_") || key.hasPrefix("CLAUDE_AGENT_SDK_") || key.hasPrefix("CLAUDE_PREVIEW_")
            || ["CLAUDECODE", "CLAUDE_PID", "CLAUDE_EFFORT", "ANTHROPIC_BASE_URL"].contains(key) {
            env[key] = nil
        }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        // Das Token steht nur in der Umgebung des Koordinators, nicht in einer Datei.
        env[ToolBridge.tokenVariable] = tools?.token
        terminal.startProcess(executable: AppPaths.python.path, args: ["-B", launcher.path, "run", specFile.path],
                              environment: env.map { $0.key + "=" + $0.value }, currentDirectory: project.path)
        guard terminal.process.running else { throw LaunchError.startFailed }
        isRunning = true
        status = "Aktiv"
        if provider == .codex, let monitor = AppPaths.script("context") {
            let process = Process()
            process.executableURL = AppPaths.python
            process.arguments = ["-B", monitor.path, "codex", folder.appendingPathComponent("context.json").path, project.path,
                                 spec.sessionId, String(getpid())]
            // Der Beobachter liest den Verlauf im Ordner des gewählten Abos.
            if !spec.account.isEmpty {
                process.environment = ProcessInfo.processInfo.environment.merging(["CODEX_HOME": AppPaths.accountHome(spec.account).path]) { $1 }
            }
            if (try? process.run()) != nil { watcher = process }
        }
        // .common: läuft auch, während der Nutzer scrollt oder ein Menü offen hat.
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Sichtbarer Text der Konsole, höchstens die letzten `lines` nicht leeren Zeilen.
    func screenText(lines: Int = 40) -> String {
        let screen = terminal.getTerminal()
        let rows = (0..<screen.rows).map { (screen.getLine(row: $0)?.translateToString(trimRight: true) ?? "").replacingOccurrences(of: "\u{0}", with: " ") }
        return rows.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.suffix(lines).joined(separator: "\n")
    }

    private func tick() {
        if let data = AppPaths.readSmallFile(folder.appendingPathComponent("context.json")),
           var next = try? JSONDecoder().decode(Usage.self, from: data) {
            // Nur echte Verläufe des Clients übernehmen; alles andere wird verworfen.
            if let path = next.historyPath, !Self.isJournal(path) { next.historyPath = usage.historyPath }
            if let path = next.historyPath, path != usage.historyPath { onJournal?(path) }
            if next != usage { usage = next }
        }
        let touched = usage.historyPath.flatMap { try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate] as? Date }
        let now = isRunning && touched.map { Date().timeIntervalSince($0) < 7 } == true
        if now != working { working = now }
        let ask = isRunning ? TerminalPromptScanner.scan(terminal) : nil
        if ask != prompt { prompt = ask }
        // Solange noch kein Verlauf existiert, kann der Starter an der Anmeldung hängen.
        let login = isRunning && usage.historyPath == nil && screenText().contains("musst du dich einmal bei")
        if login != needsLogin { needsLogin = login }
        collectPost()
    }

    /// Nur Verlaufsdateien in den Ordnern der Clients zählen (Verweise aufgelöst).
    nonisolated static func isJournal(_ path: String) -> Bool {
        let resolved = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        let env = ProcessInfo.processInfo.environment
        // Auch die Codex-Ordner weiterer ChatGPT-Abos zählen dazu.
        let roots = [(env["CLAUDE_CONFIG_DIR"] ?? NSHomeDirectory() + "/.claude") + "/projects", (env["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex"),
                     AppPaths.support.appendingPathComponent("accounts/codex").path]
        return resolved.hasSuffix(".jsonl") && roots.contains {
            resolved.hasPrefix(URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path + "/")
        }
    }

    /// Holt Briefe aus dem Postausgang. Der Absender steht fest: Nur diese Sitzung kann dort schreiben.
    private func collectPost() {
        guard let onPost, let names = try? FileManager.default.contentsOfDirectory(atPath: outbox.path) else { return }
        for name in names.sorted().prefix(20) where name.hasPrefix("out-") && name.hasSuffix(".json") {
            let file = outbox.appendingPathComponent(name)
            defer { try? FileManager.default.removeItem(at: file) }
            let receipt = outbox.appendingPathComponent(String(name.dropLast(5)) + ".result")
            guard let data = AppPaths.readSmallFile(file), let letter = try? JSONDecoder().decode([String: String].self, from: data),
                  let to = letter["to"] else {
                try? Data("Nicht zugestellt: Die Nachricht ist zu groß oder unlesbar.".utf8).write(to: receipt, options: .atomic)
                continue
            }
            try? Data(onPost(to, letter["text"] ?? "").utf8).write(to: receipt, options: .atomic)
        }
    }

    fileprivate func terminated(exitCode: Int32?) {
        isRunning = false
        working = false
        prompt = nil
        endedAt = Date()
        status = exitCode == 0 ? "Beendet" : "Unterbrochen"
        // Der Client schreibt seine letzten Zeilen kurz nach dem Ende; danach aufräumen.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            self?.tick()
            self?.stopObserving()
        }
    }

    private func stopObserving() {
        timer?.invalidate()
        timer = nil
        if watcher?.isRunning == true { watcher?.terminate() }
        watcher = nil
    }

    /// Beendet den Client und entfernt alle Dateien der Sitzung.
    func end() {
        if terminal.process.running { terminal.terminate() }
        stopObserving()
        if endedAt == nil { endedAt = Date() }
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.removeItem(at: outbox)
    }

    /// Beantwortet die offene Rückfrage des Clients.
    func answer(_ option: ClientPrompt.Option) {
        guard isRunning, let ask = prompt, ask.options.contains(option) else { return }
        if let marked = ask.marked, option.key.hasPrefix("pos:"), let target = Int(option.key.dropFirst(4)) {
            terminal.send(txt: String(repeating: target >= marked ? "\u{1b}[B" : "\u{1b}[A", count: abs(target - marked)))
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                self?.terminal.send(txt: "\r")
            }
        } else {
            terminal.send(txt: option.key)
        }
        prompt = nil
    }

    /// Wahr, solange eine eben eingefügte Nachricht noch auf ihr Return wartet.
    var submitPending: Bool { pendingSubmit.map { Date().timeIntervalSince($0) < 1.2 } ?? false }

    /// Fügt Text in die leere Eingabezeile des Clients ein und schickt ihn ab. Falsch, wenn die Eingabe nicht frei ist.
    func send(_ text: String) -> Bool {
        // Steht gerade ein Auswahlmenü im Terminal, würde das Return eine Rückfrage bestätigen.
        guard isRunning, !submitPending, TerminalPromptScanner.scan(terminal) == nil else { return false }
        let screen = terminal.getTerminal()
        let cursor = screen.getCursorLocation()
        guard (1...4).contains(cursor.x), let row = screen.getLine(row: cursor.y),
              TerminalPromptScanner.isInputPrompt(row.translateToString(trimRight: true, startCol: 0, endCol: cursor.x)) else { return false }
        let clean = String(String.UnicodeScalarView(text.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t"
        }))
        guard !clean.isEmpty else { return false }
        pendingSubmit = Date()
        terminal.send(txt: "\u{1b}[200~" + clean + "\u{1b}[201~")
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard let self, self.isRunning else { return }
            self.terminal.send(txt: "\r")
        }
        return true
    }
}

extension AgentSession: LocalProcessTerminalViewDelegate {
    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor in self.terminated(exitCode: exitCode) }
    }
    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
}

/// Erkennt Auswahlmenüs des Clients auf dem sichtbaren Konsolenbild.
enum TerminalPromptScanner {
    private static let optionLine = try! Regex(#"([❯›>]\s*)?(\d)[.)]\s+(\S.*)"#, as: (Substring, Substring?, Substring, Substring).self)

    @MainActor static func scan(_ terminal: LocalProcessTerminalView) -> ClientPrompt? {
        let screen = terminal.getTerminal()
        let lines = (0..<screen.rows).map { row in
            (screen.getLine(row: row)?.translateToString(trimRight: true) ?? "")
                .replacingOccurrences(of: "\u{0}", with: " ")
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t│|╭╮╰╯─"))
        }
        return parse(lines)
    }

    /// Steht vor dem Cursor nur das Eingabezeichen des Clients? Leere Terminalzellen kommen als NUL statt als Leerzeichen.
    static func isInputPrompt(_ beforeCursor: String) -> Bool {
        ["❯", "›", ">"].contains(beforeCursor.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\u{0}"))))
    }

    /// Nummerierte Zeilen ab 1, eine davon markiert (❯ oder ›); sonst ein Menü ohne Nummern mit „Enter to confirm“.
    static func parse(_ lines: [String]) -> ClientPrompt? {
        var options = [ClientPrompt.Option](), first = -1, marked = false
        for (index, line) in lines.enumerated() {
            guard let match = line.wholeMatch(of: optionLine) else {
                if !options.isEmpty, line.isEmpty || index - first > 12 {
                    if options.count >= 2 && marked { break }
                    options = []; first = -1; marked = false
                }
                continue
            }
            let number = String(match.2)
            if number == "1" { options = []; first = index; marked = false }
            guard first >= 0, number == String(options.count + 1) else { options = []; first = -1; marked = false; continue }
            if match.1 != nil { marked = true }
            options.append(.init(key: number, label: String(match.3).trimmingCharacters(in: .whitespaces)))
        }
        if (2...6).contains(options.count), marked, first >= 0 {
            return ClientPrompt(context: Array(lines[max(0, first - 9)..<first].filter { !$0.isEmpty }.suffix(6)), options: options)
        }
        return plainMenu(lines)
    }

    private static func plainMenu(_ lines: [String]) -> ClientPrompt? {
        guard let pointer = lines.lastIndex(where: { $0.hasPrefix("❯ ") || $0.hasPrefix("› ") }),
              lines[pointer...].prefix(6).contains(where: { $0.localizedCaseInsensitiveContains("enter to confirm") }) else { return nil }
        var start = pointer, end = pointer
        while start > 0, !lines[start - 1].isEmpty { start -= 1 }
        while end + 1 < lines.count, !lines[end + 1].isEmpty, !lines[end + 1].localizedCaseInsensitiveContains("enter to confirm") { end += 1 }
        let block = Array(lines[start...end])
        guard (2...6).contains(block.count), block.allSatisfy({ $0.count < 90 }) else { return nil }
        let options = block.enumerated().map { index, line in
            ClientPrompt.Option(key: "pos:\(index)", label: line.replacingOccurrences(of: "^[❯›]\\s*", with: "", options: .regularExpression))
        }
        return ClientPrompt(context: Array(lines[max(0, start - 10)..<start].filter { !$0.isEmpty }.suffix(7)),
                            options: options, marked: pointer - start)
    }
}
