import Combine
import Foundation
import Security

/// Secrets of the messengers in the user's keychain. Nothing of this is written to the app's own files.
enum Keychain {
    private static var service: String { (Bundle.main.bundleIdentifier ?? "dev.mochisquad.app") + ".messengers" }

    private static func query(_ name: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: name]
    }

    static func read(_ name: String) -> String? {
        var item: CFTypeRef?
        let request = query(name).merging([kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]) { $1 }
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(_ value: String, as name: String) -> Bool {
        SecItemDelete(query(name) as CFDictionary)
        let item = query(name).merging([kSecValueData as String: Data(value.utf8)]) { $1 }
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ name: String) { SecItemDelete(query(name) as CFDictionary) }
}

/// A helper process that exchanges one JSON object per line with the app.
@MainActor final class LineProcess {
    /// Collects the helper's output and cuts it into lines. Fed from the pipe's own queue.
    private final class Splitter: @unchecked Sendable {
        private var rest = Data()
        func feed(_ data: Data) -> [Data] {
            rest.append(data)
            var lines = [Data]()
            while let cut = rest.firstIndex(of: 10) {
                lines.append(rest[rest.startIndex..<cut])
                rest = rest[rest.index(after: cut)...]
            }
            return lines
        }
    }

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var stopped = false
    var isRunning: Bool { process.isRunning }

    /// Starts the helper. `onEvent` gets every JSON line it prints, `onExit` is called once when its output ends.
    /// Both run on the main thread, in the order the helper wrote them.
    init(executable: URL, arguments: [String], environment: [String: String], directory: URL? = nil,
         onEvent: @escaping @MainActor ([String: Any]) -> Void, onExit: @escaping @MainActor () -> Void) throws {
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = directory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let splitter = Splitter()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            let lines = splitter.feed(data)
            // The main queue keeps the order; a hop through unstructured tasks would not.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !self.stopped else { return }
                    for line in lines {
                        if let event = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] { onEvent(event) }
                    }
                    if data.isEmpty {
                        self.stopped = true
                        onExit()
                    }
                }
            }
            if data.isEmpty { handle.readabilityHandler = nil }
        }
    }

    func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        try? input.fileHandleForWriting.write(contentsOf: data + Data("\n".utf8))
    }

    func sendLine(_ text: String) {
        try? input.fileHandleForWriting.write(contentsOf: Data((text + "\n").utf8))
    }

    /// Ends the helper on purpose; `onExit` is not called for that.
    func stop() {
        stopped = true
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }
}

/// Telegram through a bot the user created themselves. The bot token is kept in the keychain; after pairing,
/// only the one Telegram account the user confirmed may talk to the bot.
@MainActor final class TelegramLink: ObservableObject {
    enum State: Equatable { case off, connecting, ready, failed(String) }
    struct Pairing: Equatable { let code: String; let link: URL; let expires: Date }
    struct Candidate: Equatable { let user: Int64; let name: String; let username: String }

    @Published private(set) var state = State.off
    /// Open pairing: the link the user opens on their phone, valid for a quarter of an hour.
    @Published private(set) var pairing: Pairing?
    /// Someone pressed Start with the pairing code; the user confirms that it is their account.
    @Published private(set) var candidate: Candidate?

    var onMessage: ((String) -> Void)?
    private let settings: SettingsStore
    private var process: LineProcess?
    private static let tokenName = "telegram-bot-token"

    init(settings: SettingsStore) { self.settings = settings }

    var config: Messengers.Telegram? { settings.messengers.telegram }
    var paired: Bool { config?.userID != nil }

    /// A bot token as BotFather shows it, also when the whole reply was pasted.
    static func token(in text: String) -> String? {
        text.range(of: #"\d{5,15}:[A-Za-z0-9_-]{30,60}"#, options: .regularExpression).map { String(text[$0]) }
    }

    /// At launch: connect if a bot was set up before.
    func start() {
        guard config != nil, process == nil, let token = Keychain.read(Self.tokenName) else { return }
        run(token: token, fresh: false)
    }

    /// Checks a new token with Telegram and, if it works, keeps it in the keychain.
    func connect(token: String) { run(token: token, fresh: true) }

    private func run(token: String, fresh: Bool) {
        process?.stop()
        guard let script = AppPaths.script("telegram") else { state = .failed(t("Parts of the app are missing.", "Der App fehlen Bestandteile.")); return }
        state = .connecting
        do {
            process = try LineProcess(executable: AppPaths.python, arguments: ["-B", script.path], environment: AppPaths.helperEnvironment(),
                                      onEvent: { [weak self] event in self?.handle(event, token: token, fresh: fresh) },
                                      onExit: { [weak self] in
                                          guard let self else { return }
                                          self.process = nil
                                          if self.state == .ready || self.state == .connecting { self.state = .off }
                                          // The helper should never end by itself while a bot is set up: start it again shortly.
                                          guard self.config != nil, !fresh else { return }
                                          Task { [weak self] in
                                              try? await Task.sleep(for: .seconds(30))
                                              self?.start()
                                          }
                                      })
            process?.sendLine(token)
        } catch {
            state = .failed(t("The Telegram helper could not be started.", "Der Telegram-Helfer konnte nicht gestartet werden."))
        }
    }

    private func handle(_ event: [String: Any], token: String, fresh: Bool) {
        if event["ready"] as? Bool == true, let bot = event["bot"] as? String, !bot.isEmpty {
            if fresh {
                guard Keychain.save(token, as: Self.tokenName) else {
                    state = .failed(t("The token could not be stored in the keychain.", "Das Token konnte nicht im Schlüsselbund gespeichert werden."))
                    process?.stop()
                    return
                }
                // A new bot starts unpaired, also when another one was set up before.
                settings.messengers.telegram = .init(bot: bot, userID: nil, userName: nil)
            }
            state = .ready
            process?.send(["allow": config?.userID.map { NSNumber(value: $0) } ?? NSNull()])
        } else if let reason = event["error"] as? String {
            switch reason {
            case "token": state = .failed(t("Telegram does not accept this token. Copy it again from BotFather.", "Telegram akzeptiert dieses Token nicht. Kopiere es noch einmal aus BotFather."))
            // After a successful start these are passing troubles: the helper keeps trying, the link stays up.
            case "conflict": if state != .ready { state = .failed(t("Another program is already reading this bot. Use a bot of its own for Mochi Squad.", "Ein anderes Programm liest diesen Bot bereits. Nutze für Mochi Squad einen eigenen Bot.")) }
            default: if state == .connecting { state = .failed(t("Telegram cannot be reached right now. Mochi Squad keeps trying.", "Telegram ist gerade nicht erreichbar. Mochi Squad versucht es weiter.")) }
            }
        } else if let start = event["start"] as? [String: Any], let code = start["code"] as? String, let user = (start["user"] as? NSNumber)?.int64Value {
            // Only the code from the open, unexpired pairing counts; everything else is someone guessing.
            guard let pairing, pairing.expires > Date(), Self.same(code, pairing.code) else { return }
            candidate = Candidate(user: user, name: start["name"] as? String ?? "", username: start["username"] as? String ?? "")
        } else if let message = event["message"] as? [String: Any], let user = (message["user"] as? NSNumber)?.int64Value,
                  user == config?.userID, let text = message["text"] as? String {
            onMessage?(text)
        } else if event["unsupported"] != nil {
            send(t("I can only read text here so far. Send pictures and files in the app.", "Hier kann ich bisher nur Text lesen. Bilder und Dateien schickst du in der App."))
        }
    }

    /// Compares in constant time.
    private static func same(_ a: String, _ b: String) -> Bool {
        let left = Array(a.utf8), right = Array(b.utf8)
        guard left.count == right.count else { return false }
        return zip(left, right).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    func beginPairing() {
        guard let bot = config?.bot else { return }
        var bytes = [UInt8](repeating: 0, count: 24)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return }
        let code = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        guard let link = URL(string: "https://t.me/\(bot)?start=\(code)") else { return }
        candidate = nil
        pairing = Pairing(code: code, link: link, expires: Date().addingTimeInterval(900))
    }

    /// The user confirmed that the candidate is their own account: from now on only it may write.
    func confirmCandidate() {
        guard let candidate, var config else { return }
        config.userID = candidate.user
        config.userName = candidate.name.isEmpty ? "@" + candidate.username : candidate.name
        settings.messengers.telegram = config
        pairing = nil
        self.candidate = nil
        process?.send(["allow": NSNumber(value: candidate.user)])
        send(t("Connected. Write here to talk to your coordinator: it knows what your agents are working on and hands out work for you.",
               "Verbunden. Schreib hier mit deinem Koordinator: Er weiß, woran deine Agenten arbeiten, und verteilt Aufgaben für dich."))
    }

    func rejectCandidate() { candidate = nil; pairing = nil }

    func send(_ text: String) {
        guard state == .ready, let user = config?.userID else { return }
        process?.send(["send": text, "to": NSNumber(value: user)])
    }

    func stop() { process?.stop(); process = nil }

    /// Connects again with the stored token, for example after "not connected right now".
    func reconnect() { stop(); start() }

    /// Forgets the bot: the process ends, the token leaves the keychain.
    func disconnect() {
        stop()
        Keychain.delete(Self.tokenName)
        settings.messengers.telegram = nil
        pairing = nil; candidate = nil
        state = .off
    }
}

/// WhatsApp as a linked device of the user's own account, through the unofficial Baileys library (needs Node.js).
/// Only the "Message yourself" chat is read and written. The session is stored in the app data.
@MainActor final class WhatsAppLink: ObservableObject {
    enum State: Equatable { case off, needsNode, installing, connecting, code(String), open(String), failed(String) }

    @Published private(set) var state = State.off
    var onMessage: ((String) -> Void)?
    private let settings: SettingsStore
    private var process: LineProcess?
    private var installer: Process?

    init(settings: SettingsStore) { self.settings = settings }

    private var home: URL { AppPaths.folder("messengers/whatsapp") }
    private var auth: URL { home.appendingPathComponent("auth", isDirectory: true) }
    var linked: Bool { settings.messengers.whatsapp != nil }

    /// Folders in which Node.js is usually found; graphical apps do not inherit the shell's PATH.
    private static var searchPaths: [String] {
        let home = NSHomeDirectory(), fm = FileManager.default
        func versions(_ folder: String, _ prefix: String) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: folder)) ?? []).filter { $0.hasPrefix(prefix) }.sorted(by: >).map { folder + "/" + $0 + "/bin" }
        }
        return (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + [home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", home + "/.volta/bin"]
            + versions(home + "/.nvm/versions/node", "v") + versions(home + "/.local/opt", "node-")
    }

    static func find(_ tool: String) -> URL? {
        searchPaths.map { URL(fileURLWithPath: $0).appendingPathComponent(tool) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private var environment: [String: String] {
        AppPaths.helperEnvironment().merging(["PATH": Self.searchPaths.joined(separator: ":")]) { $1 }
    }

    /// At launch: reconnect if an account was linked before.
    func start() { if linked, process == nil { connect() } }

    /// Installs the helper if needed and connects. A new account shows a code to scan first.
    func connect() {
        guard process == nil, installer == nil else { return }
        guard let node = Self.find("node"), let npm = Self.find("npm") else { state = .needsNode; return }
        guard let source = Bundle.main.resourceURL?.appendingPathComponent("whatsapp"),
              let package = try? Data(contentsOf: source.appendingPathComponent("package.json")),
              let bridge = try? Data(contentsOf: source.appendingPathComponent("bridge.mjs")) else {
            state = .failed(t("Parts of the app are missing.", "Der App fehlen Bestandteile.")); return
        }
        let fm = FileManager.default
        try? fm.createDirectory(at: auth, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let installed = (try? Data(contentsOf: home.appendingPathComponent("package.json"))) == package
            && fm.fileExists(atPath: home.appendingPathComponent("node_modules/@whiskeysockets/baileys").path)
        do {
            try bridge.write(to: home.appendingPathComponent("bridge.mjs"), options: .atomic)
            if installed { return run(node) }
            try package.write(to: home.appendingPathComponent("package.json"), options: .atomic)
        } catch {
            state = .failed(t("The WhatsApp helper could not be set up.", "Der WhatsApp-Helfer konnte nicht eingerichtet werden.")); return
        }
        // The library is fetched once from the npm registry, without running install scripts of its packages.
        state = .installing
        let install = Process()
        install.executableURL = npm
        install.arguments = ["install", "--omit=dev", "--ignore-scripts", "--no-audit", "--no-fund", "--loglevel=error"]
        install.currentDirectoryURL = home
        install.environment = environment
        install.standardOutput = FileHandle.nullDevice
        install.standardError = FileHandle.nullDevice
        install.terminationHandler = { [weak self] done in
            Task { @MainActor in
                guard let self else { return }
                self.installer = nil
                if done.terminationStatus == 0 { self.run(node) } else {
                    try? FileManager.default.removeItem(at: self.home.appendingPathComponent("package.json"))
                    self.state = .failed(t("The WhatsApp library could not be downloaded. Check your internet connection and try again.",
                                           "Die WhatsApp-Bibliothek konnte nicht geladen werden. Prüfe deine Internetverbindung und versuch es erneut."))
                }
            }
        }
        do { try install.run(); installer = install } catch {
            state = .failed(t("npm could not be started.", "npm konnte nicht gestartet werden."))
        }
    }

    private func run(_ node: URL) {
        state = .connecting
        do {
            process = try LineProcess(executable: node, arguments: [home.appendingPathComponent("bridge.mjs").path, auth.path],
                                      environment: environment, directory: home,
                                      onEvent: { [weak self] event in self?.handle(event) },
                                      onExit: { [weak self] in
                                          guard let self else { return }
                                          self.process = nil
                                          if case .failed = self.state { return }
                                          self.state = .off
                                      })
        } catch {
            state = .failed(t("The WhatsApp helper could not be started.", "Der WhatsApp-Helfer konnte nicht gestartet werden."))
        }
    }

    private func handle(_ event: [String: Any]) {
        if let code = event["qr"] as? String {
            state = .code(code)
        } else if let phase = event["state"] as? String {
            switch phase {
            case "open":
                let number = event["number"] as? String ?? ""
                settings.messengers.whatsapp = .init(number: number)
                state = .open(number)
            case "logged_out":
                forget()
            default:
                // While a code is on screen, "connecting" only means the code is being renewed.
                if case .code = state { return }
                state = .connecting
            }
        } else if let message = event["message"] as? [String: Any], let text = message["text"] as? String {
            onMessage?(text)
        } else if event["unsupported"] != nil {
            send(t("I can only read text here so far. Send pictures and files in the app.", "Hier kann ich bisher nur Text lesen. Bilder und Dateien schickst du in der App."))
        }
    }

    func send(_ text: String) {
        guard case .open = state else { return }
        process?.send(["send": text])
    }

    /// Closes the setup without linking: the helper stops, nothing stays behind.
    func cancel() {
        guard !linked else { return }
        stop()
        try? FileManager.default.removeItem(at: auth)
        state = .off
    }

    func stop() {
        installer?.terminate(); installer = nil
        process?.stop(); process = nil
    }

    /// Unlinks the device at WhatsApp and removes the stored session.
    func disconnect() {
        if let process, process.isRunning { process.send(["logout": true]) } else { forget() }
        // If WhatsApp does not answer, the local session is removed anyway.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            self?.forget()
        }
    }

    private func forget() {
        stop()
        try? FileManager.default.removeItem(at: auth)
        settings.messengers.whatsapp = nil
        state = .off
    }
}

/// Connects the messengers with the team chat of one project: what the user writes on the phone becomes a
/// message to the team, and the team's answers go back to the messenger the user wrote from.
@MainActor final class MessengerHub: ObservableObject {
    let telegram: TelegramLink
    let whatsapp: WhatsAppLink
    private let manager: SessionManager
    private let settings: SettingsStore
    /// Routines that a keyword from the phone can start.
    weak var routines: RoutineStore?
    private let team: TeamLog
    /// When the user last wrote through a messenger. Answers follow for a while, then the phone stays quiet again.
    private var lastHeard = [String: Date]()
    private static let follow: TimeInterval = 1800

    init(manager: SessionManager, settings: SettingsStore, team: TeamLog) {
        self.manager = manager
        self.settings = settings
        self.team = team
        telegram = TelegramLink(settings: settings)
        whatsapp = WhatsAppLink(settings: settings)
        telegram.onMessage = { [weak self] text in self?.receive(text, from: "Telegram") }
        whatsapp.onMessage = { [weak self] text in self?.receive(text, from: "WhatsApp") }
        team.onAppend = { [weak self] line, project in self?.forward(line, project: project) }
        watchers = [telegram.$state.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.flush("Telegram") },
                    whatsapp.$state.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.flush("WhatsApp") }]
    }

    func start() { telegram.start(); whatsapp.start() }
    func stop() { telegram.stop(); whatsapp.stop() }

    /// A message of the app itself (for example a usage warning) to every connected messenger, whether the user
    /// wrote from there recently or not. With `project`, only while that project is still the messenger's one.
    func announce(_ text: String, project: String? = nil) {
        deliver("ℹ️ " + text, to: "Telegram", project: project)
        deliver("Mochi Squad: " + text, to: "WhatsApp", project: project)
    }

    /// A message of the app waiting while a set-up messenger is still connecting. It is bound to the account it was
    /// meant for and, if it came from a project, to that project: it goes out only if both are still the same.
    struct Waiting: Equatable {
        let text: String
        let recipient: String
        let project: String?
    }
    private(set) var pending = [String: [Waiting]]()
    private var watchers = [AnyCancellable]()

    /// The account a messenger talks to now: the paired Telegram user or the linked WhatsApp number.
    func recipient(_ channel: String) -> String? {
        if channel == "Telegram" { return settings.messengers.telegram?.userID.map { "telegram:\($0)" } }
        return settings.messengers.whatsapp.map { "whatsapp:" + $0.number }
    }

    private func allowed(_ waiting: Waiting, on channel: String) -> Bool {
        guard recipient(channel) == waiting.recipient else { return false }
        return waiting.project == nil || waiting.project == settings.messengerProject?.path
    }

    func deliver(_ text: String, to channel: String, project: String? = nil) {
        guard let recipient = recipient(channel) else { return }
        if project != nil, project != settings.messengerProject?.path { return }
        if ready(channel) { return send(text, to: channel) }
        pending[channel, default: []] = Array((pending[channel, default: []] + [Waiting(text: text, recipient: recipient, project: project)]).suffix(10))
    }

    private func ready(_ channel: String) -> Bool {
        if channel == "Telegram" { return telegram.state == .ready }
        if case .open = whatsapp.state { return true }
        return false
    }

    /// Sends what waits once the messenger is ready; what no longer belongs to its account or project is dropped,
    /// and so is everything once the messenger is unlinked.
    func flush(_ channel: String) {
        guard var waiting = pending[channel] else { return }
        waiting.removeAll { !allowed($0, on: channel) }
        pending[channel] = waiting.isEmpty ? nil : waiting
        guard ready(channel), !waiting.isEmpty else { return }
        pending[channel] = nil
        waiting.forEach { send($0.text, to: channel) }
    }

    private func send(_ text: String, to channel: String) {
        if channel == "Telegram" { telegram.send(text) } else { whatsapp.send(text) }
    }

    private func receive(_ text: String, from channel: String) {
        guard settings.value.onboarded, let project = settings.messengerProject else {
            return send(t("Mochi Squad is not set up yet. Open the app on your Mac first.", "Mochi Squad ist noch nicht eingerichtet. Öffne zuerst die App auf deinem Mac."), to: channel)
        }
        lastHeard[channel] = Date()
        // "#keyword …" starts the routine with that keyword instead of going to the coordinator.
        if let routines, let (routine, input) = routines.match(message: text, project: project.path) {
            let what = routine.agent.name + " · " + routine.summary
            switch routines.start(routine, input: input.isEmpty ? nil : input) {
            case .started:
                send(routine.quiet == true
                     ? t("▶︎ Started: \(what). You hear back only if there is something new.", "▶︎ Gestartet: \(what). Du hörst nur etwas, wenn es Neues gibt.")
                     : t("▶︎ Started: \(what). The result follows here.", "▶︎ Gestartet: \(what). Das Ergebnis kommt hierher."), to: channel)
            case .alreadyRunning:
                send(t("\(what) is still running from before; try again when it is done.", "\(what) läuft noch vom letzten Mal; versuch es, wenn es fertig ist."), to: channel)
            case .failed:
                send(t("The routine could not be started.", "Die Routine ließ sich nicht starten."), to: channel)
            }
            return
        }
        manager.sendToTeam(text, project: project, via: channel)
    }

    /// Answers and notices of the messenger project go to every messenger the user wrote from recently.
    private func forward(_ line: TeamLine, project: String) {
        guard line.kind != .user, project == settings.messengerProject?.path else { return }
        // The phone is a conversation with the coordinator: what other agents say in the team chat stays in the app.
        if line.kind == .agent, !manager.isCoordinator(line.agent) { return }
        for (channel, heard) in lastHeard where Date().timeIntervalSince(heard) < Self.follow {
            // In WhatsApp the answer lands in the user's own chat, so it carries the coordinator's name; a Telegram bot speaks for itself.
            let named = channel == "WhatsApp" ? line.from + ": " + line.text : line.text
            send(line.kind == .agent ? named : "ℹ️ " + line.text, to: channel)
        }
    }
}
