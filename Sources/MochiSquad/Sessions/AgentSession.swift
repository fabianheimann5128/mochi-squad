import AppKit
import SwiftTerm

/// A question the client asks in the console, such as approving a command, with its answers.
struct ClientPrompt: Equatable {
    struct Option: Equatable, Identifiable {
        let key, label: String
        var id: String { key }
    }
    let context: [String]
    let options: [Option]
    /// For menus without numbers: position of the marked line; chosen with arrow keys and Return.
    var marked: Int?
}

/// What a session needs to start. Written as spec.json for launcher.py.
/// Paths are deliberately not part of it: the launcher derives them from the session folder.
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
    /// Interface language: the fallback when the language of a message is unclear.
    let language: String
    let agent: AgentPart
    let team: [String]
    /// Extra ChatGPT subscription, or empty for the regular sign-in.
    let account: String
    let postEnabled = true
    var parentChat: String?

    init(agent: Agent, project: URL, task: String, sessionID: UUID, owner: String, team: [String], parentChat: String?) {
        provider = agent.provider.rawValue
        self.project = project.path
        self.task = task
        sessionId = sessionID.uuidString.lowercased()
        self.owner = owner
        language = L10n.language.rawValue
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
        case .resourcesMissing: return t("Parts of the app are missing. Please install Mochi Squad again.", "Der App fehlen Bestandteile. Installiere Mochi Squad bitte neu.")
        case .startFailed: return t("The session could not be started.", "Die Sitzung konnte nicht gestartet werden.")
        }
    }
}

/// A running agent session in the embedded terminal.
@MainActor final class AgentSession: NSObject, Identifiable, ObservableObject {
    let id = UUID()
    let agentID: UUID
    /// Access level this session was started with; it applies until the session ends.
    let access: Agent.Access
    /// The session was started with computer use.
    let computerUse: Bool
    /// Extra ChatGPT subscription this session was started with; nil for the regular sign-in.
    let account: String?
    /// The client ended with an error.
    private(set) var failed = false
    /// The agent's settings at start (see Agent.sessionSignature).
    let signature: String
    /// The launcher waits in the console for a sign-in to the client.
    @Published private(set) var needsLogin = false
    let project: URL
    let provider: Provider
    let task: String
    let started = Date()
    let terminal = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 440))

    @Published private(set) var usage = Usage()
    @Published private(set) var status = t("Starting", "Wird gestartet")
    @Published private(set) var isRunning = false
    /// The client is writing to its history right now, so it is working.
    @Published private(set) var working = false
    /// Set while the client waits for a choice in the console.
    @Published private(set) var prompt: ClientPrompt?
    @Published var replyDraft = ""
    private(set) var endedAt: Date?

    /// Agent post: (recipient, text) → receipt for the sender.
    var onPost: ((String, String) -> String)?
    /// New history detected (path of the history file).
    var onJournal: ((String) -> Void)?

    /// Launch data and status file. Inside the app data, which agents may neither read nor write.
    private let folder: URL
    /// Outbox: the only place outside the project this session's sandbox may write to.
    private let outbox: URL
    private var watcher: Process?
    private var timer: Timer?
    private var pendingSubmit: Date?
    private var sessionKey: String { id.uuidString.lowercased() }

    init(agent: Agent, project: URL, task: String) throws {
        agentID = agent.id
        access = agent.access
        signature = agent.sessionSignature
        computerUse = agent.computerUse == true
        account = agent.provider == .codex ? agent.account : nil
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

    /// Starts the client through launcher.py. `tools` are configuration and token of the tool server for a coordinator.
    func launch(spec: SessionSpec, tools: (config: String, token: String)?) throws {
        guard let launcher = AppPaths.script("launcher") else { throw LaunchError.resourcesMissing }
        let specFile = folder.appendingPathComponent("spec.json")
        do {
            try JSONFile.save(spec, to: specFile)
            if let tools { try JSONFile.write(Data(tools.config.utf8), to: folder.appendingPathComponent("mcp.json")) }
        } catch { throw LaunchError.startFailed }

        var env = AppPaths.helperEnvironment()
        for key in env.keys where key.hasPrefix("CLAUDE_CODE_") || key.hasPrefix("CLAUDE_AGENT_SDK_") || key.hasPrefix("CLAUDE_PREVIEW_")
            || ["CLAUDECODE", "CLAUDE_PID", "CLAUDE_EFFORT", "ANTHROPIC_BASE_URL"].contains(key) {
            env[key] = nil
        }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        // The token exists only in the coordinator's environment, not in a file.
        env[ToolBridge.tokenVariable] = tools?.token
        terminal.startProcess(executable: AppPaths.python.path, args: ["-B", launcher.path, "run", specFile.path],
                              environment: env.map { $0.key + "=" + $0.value }, currentDirectory: project.path)
        guard terminal.process.running else { throw LaunchError.startFailed }
        isRunning = true
        status = t("Active", "Aktiv")
        if provider == .codex, let monitor = AppPaths.script("context") {
            let process = Process()
            process.executableURL = AppPaths.python
            process.arguments = ["-B", monitor.path, "codex", folder.appendingPathComponent("context.json").path, project.path,
                                 spec.sessionId, String(getpid())]
            // The watcher reads the history in the chosen subscription's folder.
            if let home = AppPaths.accountHome(spec.account) {
                process.environment = ProcessInfo.processInfo.environment.merging(["CODEX_HOME": home.path]) { $1 }
            }
            if (try? process.run()) != nil { watcher = process }
        }
        // .common: also runs while the user scrolls or has a menu open.
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Visible text of the console, at most the last `lines` non-empty lines.
    func screenText(lines: Int = 40) -> String {
        let screen = terminal.getTerminal()
        let rows = (0..<screen.rows).map { (screen.getLine(row: $0)?.translateToString(trimRight: true) ?? "").replacingOccurrences(of: "\u{0}", with: " ") }
        return rows.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.suffix(lines).joined(separator: "\n")
    }

    private func tick() {
        if let data = AppPaths.readSmallFile(folder.appendingPathComponent("context.json")),
           var next = try? JSONDecoder().decode(Usage.self, from: data) {
            // Accept only real histories of the client; anything else is dropped.
            if let path = next.historyPath, !Self.isJournal(path) { next.historyPath = usage.historyPath }
            if let path = next.historyPath, path != usage.historyPath { onJournal?(path) }
            if next != usage { usage = next }
        }
        let touched = usage.historyPath.flatMap { try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate] as? Date }
        // Busy means: the history was written just now, or the client itself says it can be interrupted. The second
        // sign covers long steps (a command that runs for minutes) during which nothing is written.
        let now = isRunning && (touched.map { Date().timeIntervalSince($0) < 7 } == true || Self.showsBusy(screenText(lines: 8)))
        if now != working { working = now }
        var ask = isRunning ? TerminalPromptScanner.scan(terminal) : nil
        // The client introduces Claude in Chrome once with a screen that only waits for Return. The user already
        // switched computer use on for this agent, so the app confirms it instead of leaving the session waiting.
        if computerUse, let notice = ask, TerminalPromptScanner.isChromeIntroduction(notice) {
            terminal.send(txt: TerminalPromptScanner.continueKey)
            ask = nil
        }
        if ask != prompt { prompt = ask }
        // While no history exists yet, the launcher may be waiting at the sign-in (see launcher.LOGIN_NOTICE).
        let login = isRunning && usage.historyPath == nil && screenText().contains("MOCHI-SIGN-IN")
        if login != needsLogin { needsLogin = login }
        collectPost()
    }

    /// Both clients show "esc to interrupt" in their status line for as long as a turn is running.
    nonisolated static func showsBusy(_ screen: String) -> Bool {
        screen.lowercased().filter { !$0.isWhitespace }.contains("esctointerrupt")
    }

    /// Only history files in the clients' folders count (links resolved).
    nonisolated static func isJournal(_ path: String) -> Bool {
        let resolved = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        let env = ProcessInfo.processInfo.environment
        // The Codex folders of extra ChatGPT subscriptions count as well.
        let roots = [(env["CLAUDE_CONFIG_DIR"] ?? NSHomeDirectory() + "/.claude") + "/projects", (env["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex"),
                     AppPaths.support.appendingPathComponent("accounts/codex").path]
        return resolved.hasSuffix(".jsonl") && roots.contains {
            resolved.hasPrefix(URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path + "/")
        }
    }

    /// Collects letters from the outbox. The sender is certain: only this session can write there.
    private func collectPost() {
        guard let onPost, let names = try? FileManager.default.contentsOfDirectory(atPath: outbox.path) else { return }
        for name in names.sorted().prefix(20) where name.hasPrefix("out-") && name.hasSuffix(".json") {
            let file = outbox.appendingPathComponent(name)
            defer { try? FileManager.default.removeItem(at: file) }
            let receipt = outbox.appendingPathComponent(String(name.dropLast(5)) + ".result")
            guard let data = AppPaths.readSmallFile(file), let letter = try? JSONDecoder().decode([String: String].self, from: data),
                  let to = letter["to"] else {
                try? Data("Not delivered: the message is too large or unreadable.".utf8).write(to: receipt, options: .atomic)
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
        failed = exitCode != 0
        status = exitCode == 0 ? t("Finished", "Beendet") : t("Interrupted", "Unterbrochen")
        // The client writes its last lines shortly after the end; clean up after that.
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

    /// Ends the client and removes all files of the session. The client leads its own process group, so the
    /// signal reaches its helpers too; whatever is still alive after a moment is killed, so that a session
    /// closed to take rights away is really gone.
    func end() {
        let pid = terminal.process.shellPid
        if terminal.process.running {
            terminal.terminate()
            if pid > 1 {
                killpg(pid, SIGTERM)
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
                    // Signal 0 only asks whether anyone in the group is left.
                    if killpg(pid, 0) == 0 { killpg(pid, SIGKILL) }
                }
            }
        }
        stopObserving()
        if endedAt == nil { endedAt = Date() }
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.removeItem(at: outbox)
    }

    /// Answers the client's open question. The console is read again first: if the client shows a different
    /// question by now, nothing is sent and the card updates instead, so a click never confirms something
    /// the user has not seen.
    func answer(_ option: ClientPrompt.Option) {
        guard isRunning, let ask = prompt, ask.options.contains(option) else { return }
        guard let current = TerminalPromptScanner.scan(terminal), current == ask else {
            prompt = TerminalPromptScanner.scan(terminal)
            return
        }
        if let marked = ask.marked, option.key.hasPrefix("pos:"), let target = Int(option.key.dropFirst(4)) {
            terminal.send(txt: String(repeating: target >= marked ? "\u{1b}[B" : "\u{1b}[A", count: abs(target - marked)))
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                // Return only if the same menu is still there and the mark sits on the chosen line.
                guard let self, self.isRunning, let now = TerminalPromptScanner.scan(self.terminal),
                      now.options == ask.options, now.marked == target else { return }
                self.terminal.send(txt: "\r")
            }
        } else {
            terminal.send(txt: option.key)
        }
        prompt = nil
    }

    /// True while a message that was just pasted still waits for its Return.
    var submitPending: Bool { pendingSubmit.map { Date().timeIntervalSince($0) < 1.2 } ?? false }

    /// Pastes text into the client's empty input line and submits it. False if the input is not free.
    func send(_ text: String) -> Bool {
        // If a menu is on screen right now, the Return would confirm a question.
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

/// Detects the client's menus on the visible console screen.
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

    /// Is only the client's prompt character in front of the cursor? Empty terminal cells arrive as NUL, not as spaces.
    static func isInputPrompt(_ beforeCursor: String) -> Bool {
        ["❯", "›", ">"].contains(beforeCursor.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\u{0}"))))
    }

    /// Numbered lines from 1, one of them marked (❯ or ›); otherwise a menu without numbers with "Enter to confirm".
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
        return plainMenu(lines) ?? notice(lines)
    }

    /// The one-time introduction to Claude in Chrome: a notice, nothing to decide.
    static func isChromeIntroduction(_ prompt: ClientPrompt) -> Bool {
        prompt.options.map(\.key) == [continueKey] && prompt.context.first == "Claude in Chrome"
    }

    /// Key of the single answer to a notice: Return.
    static let continueKey = "\r"

    /// A screen the client shows once and that only waits for Return ("Enter to continue"), for example the
    /// introduction to Claude in Chrome. Without a card for it the session would sit there unanswered.
    private static func notice(_ lines: [String]) -> ClientPrompt? {
        guard let hint = lines.lastIndex(where: { $0.localizedCaseInsensitiveContains("enter to continue") }),
              lines[(hint + 1)...].allSatisfy(\.isEmpty) else { return nil }
        let context = lines[..<hint].filter { !$0.isEmpty && !$0.allSatisfy { "─━-—=".contains($0) } }.suffix(7)
        return ClientPrompt(context: Array(context), options: [.init(key: continueKey, label: "Continue")])
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
