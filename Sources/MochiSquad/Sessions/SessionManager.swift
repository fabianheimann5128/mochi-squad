import Foundation

/// Manages all running sessions and the collaboration of the agents: agent post, team chat,
/// waiting messages and the coordinator's tools. The interface only observes.
@MainActor final class SessionManager: ObservableObject {
    enum Handover { case delivered(AgentSession), queued(AgentSession), started(AgentSession), failed(String) }

    nonisolated static let maxRunning = 8
    nonisolated static let relayLimit = 24
    nonisolated static let relayWindow: TimeInterval = 1800
    /// Longest task text handed to one recipient of a team message.
    nonisolated static let teamTextLimit = 8000

    @Published private(set) var sessions = [AgentSession]()
    /// Who is writing in a project's team chat right now (names).
    @Published private(set) var teamTyping = [String: [String]]()
    /// Error message for the user.
    @Published var notice: String?
    /// Sessions the interface is showing are not cleaned up.
    var pinned = Set<UUID>()

    let agents: AgentStore
    let settings: SettingsStore
    let routines: RoutineStore
    let team: TeamLog
    let bridge = ToolBridge()

    private var feeds = [UUID: TeamFeed]()
    private var waiting = [WaitingPost]()
    private var relays = [String: [Date]]()
    private var loops = [Task<Void, Never>]()

    init(agents: AgentStore, settings: SettingsStore, routines: RoutineStore, team: TeamLog) {
        self.agents = agents
        self.settings = settings
        self.routines = routines
        self.team = team
    }

    func start() {
        guard loops.isEmpty else { return }
        bridge.start { [weak self] name, args, caller in await self?.tool(name, args, caller: caller) ?? ["error": "Mochi Squad is quitting."] }
        loops = [
            Task { [weak self] in await self?.every(.seconds(2)) { await $0.pumpTeam() } },
            Task { [weak self] in await self?.every(.seconds(3)) { $0.retryWaiting() } },
            Task { [weak self] in await self?.every(.seconds(10)) { $0.prune(); SaveGuard.retry() } },
        ]
    }

    func shutdown() {
        loops.forEach { $0.cancel() }
        loops = []
        bridge.stop()
        sessions.forEach { $0.end() }
        sessions = []
        agents.flush()
    }

    private func every(_ interval: Duration, _ work: (SessionManager) async -> Void) async {
        while !Task.isCancelled {
            await work(self)
            try? await Task.sleep(for: interval)
        }
    }

    // MARK: Sessions

    func liveSession(for agent: UUID) -> AgentSession? { sessions.last { $0.agentID == agent && $0.isRunning } }
    func latestSession(for agent: UUID) -> AgentSession? { sessions.last { $0.agentID == agent } }
    var runningCount: Int { sessions.filter(\.isRunning).count }

    @discardableResult
    func launch(_ agent: Agent, task: String, parentChat: String? = nil) throws -> AgentSession {
        let project = URL(fileURLWithPath: agent.project, isDirectory: true)
        guard FileManager.default.fileExists(atPath: project.path) else { throw SessionError.projectMissing }
        guard runningCount < Self.maxRunning else { throw SessionError.tooMany }
        let session = try AgentSession(agent: agent, project: project, task: task)
        var tools: (config: String, token: String)?
        if agent.isCoordinator {
            guard let config = bridge.mcpConfig else { session.end(); throw SessionError.toolsNotReady }
            // An own token per session: the tool server then knows which coordinator is asking.
            tools = (config, bridge.grant(to: session.id))
        }
        let team = agents.agents(in: project).filter { !$0.isCoordinator && $0.id != agent.id && mayReach(agent, $0) }
            .map { "\($0.name) (\($0.jobTitle))" }
        let spec = SessionSpec(agent: agent, project: project, task: task, sessionID: session.id, owner: settings.value.owner,
                               team: team, parentChat: parentChat)
        session.onPost = { [weak self, weak session] to, text in
            guard let self, let session else { return "Session ended." }
            return self.deliver(from: session, to: to, text: text)
        }
        session.onJournal = { [weak self] path in self?.agents.remember(journal: path, for: agent.id) }
        do { try session.launch(spec: spec, tools: tools) } catch {
            bridge.revoke(session: session.id)
            session.end()
            throw error
        }
        agents.update(agent.id) { $0.lastTask = task; $0.lastLine = nil; $0.updated = Date() }
        sessions.append(session)
        return session
    }

    /// Restarts an agent's session so that a changed model or changed rights apply at once. Claude agents continue
    /// in the same chat. Messages that were waiting for the old session go to the new one.
    func restart(_ agent: Agent) {
        if let live = liveSession(for: agent.id) { close(live, keepWaiting: true) }
        // Only Claude agents continue their chat; Codex begins a new one.
        let task = RelayedMessage.postPrefix + AppPaths.appName + ": Your settings were just changed (model \(agent.model), access \(agent.access.rawValue)). Confirm that briefly in one sentence"
            + (agent.provider == .claude ? " and then carry on where we were." : ".")
        do { try launch(agent, task: task, parentChat: resumableChat(for: agent)) } catch { notice = error.localizedDescription }
    }

    /// After a change to the agent: if it now has fewer rights than its running session, that session ends at once.
    func settle(_ agent: Agent) {
        guard let live = liveSession(for: agent.id) else { return }
        let lessAccess = agent.access.rank < live.access.rank, noComputer = live.computerUse && agent.computerUse != true
        guard lessAccess || noComputer else { return }
        close(live)
        notice = t("\(agent.name)'s running session was ended so that the reduced rights apply at once.",
                   "Die laufende Sitzung von \(agent.name) wurde beendet, damit die geringeren Rechte sofort gelten.")
    }

    /// Ends and forgets a session. Messages still waiting for it are not dropped silently: the user is told,
    /// unless `keepWaiting` says that a new session of the same agent takes them over.
    func close(_ session: AgentSession, keepWaiting: Bool = false) {
        if !keepWaiting {
            let lost = waiting.filter { $0.session == session.id }
            waiting.removeAll { $0.session == session.id }
            if !lost.isEmpty, let agent = agents.agent(session.agentID) {
                let text = t("\(lost.count == 1 ? "A message" : "\(lost.count) messages") for \(agent.name) had not been delivered yet when the session was closed. Send \(lost.count == 1 ? "it" : "them") again if still needed.",
                             "\(lost.count == 1 ? "Eine Nachricht" : "\(lost.count) Nachrichten") an \(agent.name) \(lost.count == 1 ? "war" : "waren") noch nicht zugestellt, als die Sitzung geschlossen wurde. Schick sie bei Bedarf noch einmal.")
                if lost.contains(where: { RelayedMessage.parseTeam($0.message) != nil }) { team.notice(text, project: agent.project) } else { notice = text }
            }
        }
        feeds[session.id] = nil
        pinned.remove(session.id)
        bridge.revoke(session: session.id)
        session.end()
        sessions.removeAll { $0.id == session.id }
    }

    /// Closes every session that was started with the given ChatGPT subscription, whatever its agent is set to now.
    func closeSessions(using account: String) {
        sessions.filter { $0.account == account }.forEach { close($0) }
    }

    /// Keeps macOS from throttling the hidden app while sessions are open, and keeps the Mac from falling asleep
    /// while an agent is working or the user chose to keep it awake. The display may still turn off.
    private var activity: NSObjectProtocol?
    private var activityLevel = AwakeLevel.none
    enum AwakeLevel { case none, appOnly, wholeMac }

    nonisolated static func awakeLevel(open: Int, working: Bool, always: Bool) -> AwakeLevel {
        if working || always { return .wholeMac }
        return open > 0 ? .appOnly : .none
    }

    func keepAwake() {
        let level = Self.awakeLevel(open: runningCount, working: sessions.contains { $0.isRunning && $0.working },
                                    always: settings.value.alwaysAwake == true)
        guard level != activityLevel else { return }
        if let held = activity { ProcessInfo.processInfo.endActivity(held); activity = nil }
        switch level {
        case .none: break
        case .appOnly: activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep], reason: "Agent sessions are open")
        case .wholeMac: activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated], reason: "Agents are working")
        }
        activityLevel = level
    }

    /// Releases ended sessions after a short while, unless the interface is showing them.
    private func prune() {
        keepAwake()
        let stale = sessions.filter { s in
            !s.isRunning && !pinned.contains(s.id) && (s.endedAt.map { Date().timeIntervalSince($0) > 20 } ?? false)
        }
        stale.forEach { close($0, keepWaiting: true) }
    }

    /// Chat id of a Claude agent's latest history, to continue there.
    /// Agents whose conversation is being summarised right now.
    @Published private(set) var compacting = Set<UUID>()

    /// The newest conversation of an agent that a person had (not a routine run), as a history file.
    func latestConversation(of agent: Agent) -> String? {
        agent.journals.reversed().first { !(agent.routineJournals ?? []).contains($0) && FileManager.default.fileExists(atPath: $0) }
    }

    /// "Tidy up": the agent's long conversation is summarised and the agent goes on in a fresh session that starts
    /// with the summary. The old conversation stays under "More chats". Returns an error text, or nil on success.
    func compact(_ agent: Agent) async -> String? {
        guard !compacting.contains(agent.id) else { return nil }
        if let live = latestSession(for: agent.id), live.isRunning, live.working {
            return t("\(agent.name) is working right now. Tidy up once the answer is there.", "\(agent.name) arbeitet gerade. Räum auf, sobald die Antwort da ist.")
        }
        guard let journal = latestConversation(of: agent) else {
            return t("There is no conversation to tidy up yet.", "Es gibt noch keinen Verlauf zum Aufräumen.")
        }
        compacting.insert(agent.id)
        defer { compacting.remove(agent.id) }
        struct Result: Decodable { let summary: String?; let error: String? }
        let args = [agent.provider.rawValue, journal, agent.provider == .codex ? (agent.account ?? "") : "", agent.provider == .codex ? agent.model : ""]
        guard let result = try? await PythonTool.run("compact", args, as: Result.self) else {
            return t("The summary could not be made.", "Die Zusammenfassung ließ sich nicht erstellen.")
        }
        guard let summary = result.summary, !summary.isEmpty else { return result.error ?? t("The summary is empty.", "Die Zusammenfassung ist leer.") }
        // The agent may have been changed or removed while the summary was being written.
        guard let current = agents.agent(agent.id) else { return nil }
        if let live = latestSession(for: agent.id), live.isRunning { close(live) }
        do {
            _ = try launch(current, task: Self.compactTask(summary))
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    nonisolated static let compactMark = "[Summary of our earlier conversation]"
    nonisolated static func compactTask(_ summary: String) -> String {
        compactMark + "\n" + summary + "\n\nThis fresh session continues from that summary; the full earlier conversation is "
            + "no longer in your context. Reply with one short sentence that you have the summary, then wait for my next message."
    }

    func resumableChat(for agent: Agent) -> String? {
        guard agent.provider == .claude else { return nil }
        // Only Claude Code histories can be continued; after a provider switch the list holds Codex histories too.
        // A routine's run is no conversation to pick up: the chat continues from the last real session.
        return agent.journals.reversed().lazy
            .filter { !(agent.routineJournals ?? []).contains($0) && FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
            .first { UUID(uuidString: $0) != nil }
    }

    // MARK: Agent post

    /// How long a relayed message waits for a busy agent before it is delivered anyway.
    nonisolated static let patience: TimeInterval = 900

    /// Should a relayed message wait? While an agent is in the middle of an answer, a message slipped in would
    /// be read as part of that turn: the rest of a private answer would then land in the team chat, or a team
    /// answer would stop halfway. So it waits until the agent is idle, but not forever.
    nonisolated static func shouldHold(working: Bool, waited: TimeInterval) -> Bool { working && waited < patience }

    /// Hands a message from an agent or the team chat to an agent's running session, or starts the agent with it.
    func hand(_ message: String, to agent: Agent) -> Handover {
        if let live = liveSession(for: agent.id) {
            if !Self.shouldHold(working: live.working, waited: 0), live.send(message) { return .delivered(live) }
            waiting.append(WaitingPost(session: live.id, agent: agent.id, message: message, since: Date()))
            return .queued(live)
        }
        do { return .started(try launch(agent, task: message, parentChat: resumableChat(for: agent))) }
        catch { return .failed(error.localizedDescription) }
    }

    /// Who wrote to whom last (recipient → sender → time), so that answers always stay possible.
    private var contacts = [UUID: [UUID: Date]]()

    /// May `sender` address `target` on its own? An agent with full access or computer use takes tasks only from
    /// colleagues with the same rights; otherwise a restricted agent could trigger more through it than it may itself.
    /// Answers to someone who wrote within the last half hour always go through.
    func mayReach(_ sender: Agent, _ target: Agent, replies: Bool = true) -> Bool {
        if replies, let asked = contacts[sender.id]?[target.id], Date().timeIntervalSince(asked) < 1800 { return true }
        // What counts is what the sender's running session may do, not what is configured by now.
        let live = liveSession(for: sender.id)
        let senderFull = sender.access == .full && (live.map { $0.access == .full } ?? true)
        let senderComputer = sender.computerUse == true && (live.map(\.computerUse) ?? true)
        let full = target.access != .full || senderFull
        let computer = target.computerUse != true || senderComputer || senderFull
        return full && computer
    }

    private func sameName(_ a: String, _ b: String) -> Bool { a.compare(b, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }

    /// Message from one agent to another named agent of the same project. The receipts are read by agents
    /// and therefore always in English.
    /// Mochi Memory, where agents save lasting facts through `post remember`.
    var memory: MemoryStore?

    func deliver(from origin: AgentSession, to name: String, text: String) -> String {
        if name == "@memory" || name == "@memory-me" {
            guard let memory else { return "Mochi Memory is not available right now." }
            let author = agents.agent(origin.agentID)?.name ?? "Agent"
            do {
                let note = try memory.remember(text, project: name == "@memory" ? origin.project.path : nil, author: author)
                return "Saved in Mochi Memory (\(note.title))."
            } catch {
                return "Not saved: " + (error.localizedDescription)
            }
        }
        // The coordinator cannot be reached by agents: through its tools they could trigger more than they may themselves.
        let sender = agents.agent(origin.agentID)
        let colleagues = agents.agents(in: origin.project).filter { !$0.isCoordinator && $0.id != origin.agentID }
        let people = colleagues.filter { other in sender.map { mayReach($0, other) } ?? false }
        if let blocked = colleagues.first(where: { sameName($0.name, name) }), !people.contains(blocked) {
            return "\(blocked.name) has full access or operates the computer and cannot be reached by you directly. Ask \(settings.value.owner) to pass the message on."
        }
        let roster = people.map { "\($0.name) (\($0.jobTitle))" }.joined(separator: ", ")
        if name == "?" { return roster.isEmpty ? "No other agents in this project." : "Reachable: " + roster }
        guard let target = people.first(where: { sameName($0.name, name) }) else {
            return "No agent named \"\(name)\". Reachable: " + roster
        }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return "The message is empty." }
        guard allowRelays(1, project: origin.project.path) else {
            return "The limit of \(Self.relayLimit) agent messages per half hour is reached. Summarise the state in the chat."
        }
        contacts[target.id, default: [:]][origin.agentID] = Date()
        let message = RelayedMessage.postPrefix + (sender?.name ?? "Agent") + " (" + (sender?.jobTitle ?? "") + "): " + String(body.prefix(12_000))
        switch hand(message, to: target) {
        case .delivered: return "Delivered to \(target.name). The answer will appear as a new message in your chat."
        case .queued: return "\(target.name) is busy. The message will be delivered as soon as the input is free; if the session is closed before that, it is lost."
        case .started: return "\(target.name) was started with your message."
        case .failed(let reason): return reason
        }
    }

    /// Relays are limited per project so that a talkative team does not slow other projects down.
    private func allowRelays(_ count: Int, project: String) -> Bool {
        let now = Date()
        var log = (relays[project] ?? []).filter { now.timeIntervalSince($0) <= Self.relayWindow }
        defer { relays[project] = log }
        guard log.count + count <= Self.relayLimit else { return false }
        log.append(contentsOf: Array(repeating: now, count: count))
        return true
    }

    /// Deliver waiting messages as soon as the recipient's input is free.
    private func retryWaiting() {
        guard !waiting.isEmpty else { return }
        let pending = waiting
        waiting = []
        for item in pending {
            let agent = agents.agent(item.agent)
            let forTeam = RelayedMessage.parseTeam(item.message) != nil
            func tell(_ text: String) {
                if forTeam, let agent { team.notice(text, project: agent.project) } else { notice = text }
            }
            let waited = Date().timeIntervalSince(item.since)
            if let live = sessions.first(where: { $0.id == item.session }), live.isRunning {
                // First the agent finishes what it is saying; after a quarter of an hour the message goes in regardless.
                if Self.shouldHold(working: live.working, waited: waited) { waiting.append(item); continue }
                if live.send(item.message) { continue }
                if waited <= Self.patience + 300 { waiting.append(item); continue }
                // The input stayed blocked (for example by an unanswered question of the client): give up and say so.
                feeds[item.session]?.answered = true
                tell(t("A message for \(agent?.name ?? "an agent") could not be delivered for 20 minutes.",
                       "Eine Nachricht an \(agent?.name ?? "einen Agenten") konnte 20 Minuten lang nicht zugestellt werden."))
            } else if let agent {
                // The session is gone (ended or restarted): the agent's current or a fresh session takes the message.
                let result = hand(item.message, to: agent)
                if forTeam { track(result, agent: agent) } else if case .failed(let reason) = result { tell(agent.name + ": " + reason) }
            }
        }
    }

    // MARK: Team chat

    /// A message of the user to the team. `via` names the messenger it arrived through, nil for the app itself.
    func isCoordinator(_ id: UUID?) -> Bool {
        guard let id else { return false }
        return agents.agents.first { $0.id == id }?.isCoordinator == true
    }

    func sendToTeam(_ text: String, project: URL, via: String? = nil) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        team.append(TeamLine(kind: .user, text: body, via: via), project: project.path)
        relay(body, from: nil, project: project, remote: via != nil)
    }

    /// Passes a team message on to everyone addressed with @name. `origin` is the writing agent, nil for the user.
    /// `remote` marks a message of the user that came in through a messenger.
    @discardableResult
    private func relay(_ text: String, from origin: Agent?, project: URL, skip: Set<UUID> = [], remote: Bool = false) -> Set<UUID> {
        // Only the user calls the coordinator; agents do not reach it in the team chat either (see deliver).
        // An agent without the same rights does not call colleagues with full access or computer use.
        let everyone = agents.agents(in: project)
        let people = everyone.filter { other in
            guard let origin else { return true }
            return other.id != origin.id && !other.isCoordinator && mayReach(origin, other)
        }
        if let origin {
            let dropped = everyone.filter { $0.id != origin.id && !$0.isCoordinator && !people.contains($0) && Mention.contains(text, $0.name) }
            if !dropped.isEmpty {
                let names = dropped.map(\.name).joined(separator: ", ")
                team.notice(t("\(origin.name) cannot bring in \(names) on its own (full access or computer use). Address them with @name if needed.",
                              "\(origin.name) kann \(names) nicht selbst dazuholen (Vollzugriff oder Computer-Nutzung). Sprich sie bei Bedarf mit @Name an."),
                            project: project.path)
            }
        }
        var targets = people.filter { Mention.contains(text, $0.name) && !skip.contains($0.id) }
        if remote {
            // From a messenger the user talks to the coordinator and to nobody else: it knows every chat and
            // process and hands work on itself. That holds whatever rights the coordinator has, because only the
            // paired account of the user gets this far.
            targets = everyone.filter(\.isCoordinator)
            guard !targets.isEmpty else {
                team.notice(t("This project has no coordinator yet. Open Mochi Squad on your Mac once.",
                              "Dieses Projekt hat noch keinen Koordinator. Öffne Mochi Squad einmal auf deinem Mac."), project: project.path)
                return []
            }
        } else if origin == nil {
            // @all really means everyone, the coordinator included. Without a mention the coordinator answers, every time.
            if Mention.addressesEveryone(text) { targets = people }
            if targets.isEmpty { targets = people.filter(\.isCoordinator) }
            guard !targets.isEmpty else {
                team.notice(t("Address an agent with @name.", "Sprich einen Agenten mit @Name an."), project: project.path)
                return []
            }
        } else {
            guard !targets.isEmpty else { return [] }
            guard allowRelays(targets.count, project: project.path) else {
                team.notice(t("Pause: the agents reached the limit of \(Self.relayLimit) relays per half hour.",
                              "Pause: Die Agenten haben das Limit von \(Self.relayLimit) Weitergaben je halbe Stunde erreicht."), project: project.path)
                return []
            }
        }
        if text.count > Self.teamTextLimit {
            team.notice(t("That message is very long. The agents received its first \(Self.teamTextLimit) characters; put longer material into a file in the project.",
                          "Diese Nachricht ist sehr lang. Die Agenten haben die ersten \(Self.teamTextLimit) Zeichen bekommen; längeres Material gehört als Datei ins Projekt."),
                        project: project.path)
        }
        let sender = origin?.name ?? settings.value.owner
        for target in targets {
            if let origin { contacts[target.id, default: [:]][origin.id] = Date() }
            // The context holds only voices that could address this recipient directly; the coordinator sees only the user.
            let voices = everyone.filter { $0.id == target.id || (!target.isCoordinator && mayReach($0, target, replies: false)) }
            let message = RelayedMessage.teamPrefix + sender + ": " + String(text.prefix(Self.teamTextLimit))
                + team.context(project: project.path, owner: settings.value.owner, voices: voices) + RelayedMessage.teamHint
                + (remote ? "The user wrote this from their phone and reads your answer there. Answer yourself, briefly and in plain sentences. Use your tools to look up the state of agents and processes or to hand out work; do not mention anyone with @name."
                          : "Answer briefly for everyone in the team chat. With @name you bring in a colleague when their role is needed; otherwise mention nobody.")
            track(hand(message, to: target), agent: target)
        }
        return Set(targets.map(\.id))
    }

    private func track(_ result: Handover, agent: Agent) {
        switch result {
        case .delivered(let s), .queued(let s):
            if var feed = feeds[s.id] {
                feed.answered = false; feed.asked = Date()
                feeds[s.id] = feed
            } else {
                let size = s.usage.historyPath.flatMap { (try? FileManager.default.attributesOfItem(atPath: $0)[.size] as? NSNumber)?.intValue } ?? 0
                feeds[s.id] = TeamFeed(offset: size, since: Date(), open: false)
            }
        case .started(let s):
            feeds[s.id] = TeamFeed(offset: 0, since: Date().addingTimeInterval(-2), open: true)
        case .failed(let reason):
            team.notice(agent.name + ": " + reason, project: agent.project)
        }
    }

    /// Reads new answers of the team sessions from their histories and puts them into the team chat.
    private func pumpTeam() async {
        for session in sessions {
            guard let before = feeds[session.id], let path = session.usage.historyPath,
                  let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue,
                  size != before.offset else { continue }
            let from = size < before.offset ? 0 : before.offset
            guard let page = try? await PythonTool.run("history", ["read", path, session.provider.rawValue, String(from), "4000"], as: ChatPage.self),
                  var feed = feeds[session.id], feed.offset == before.offset, let agent = agents.agent(session.agentID) else { continue }
            var replies = [(String, Date)]()
            for line in page.messages {
                let date = Timestamp.date(line.timestamp)
                if line.role == "user" { feed.open = RelayedMessage.parseTeam(line.text) != nil; feed.called = []; continue }
                guard feed.open, date.map({ $0 >= feed.since }) ?? true else { continue }
                feed.answered = true
                replies.append((line.text, date ?? Date()))
            }
            feed.offset = page.position
            feeds[session.id] = feed
            for (text, date) in replies {
                team.append(TeamLine(kind: .agent, from: agent.name, agent: agent.id, text: text, date: date), project: agent.project)
                let called = relay(text, from: agent, project: session.project, skip: feeds[session.id]?.called ?? [])
                feeds[session.id]?.called.formUnion(called)
            }
        }
        feeds = feeds.filter { id, _ in sessions.contains { $0.id == id } }
        // A team question that gets no more answers counts as done after two quiet minutes; otherwise later work would show "is typing".
        for session in sessions where !session.working {
            if let feed = feeds[session.id], !feed.answered, Date().timeIntervalSince(feed.asked) > 120 { feeds[session.id]?.answered = true }
        }
        updateTyping()
    }

    private func updateTyping() {
        var typing = [String: [String]]()
        for session in sessions {
            guard let feed = feeds[session.id], session.isRunning, session.prompt == nil else { continue }
            let fresh = !feed.answered && (session.working || Date().timeIntervalSince(feed.asked) < 120)
            guard fresh || (feed.open && session.working), let agent = agents.agent(session.agentID) else { continue }
            typing[agent.project, default: []].append(agent.name)
        }
        if typing != teamTyping { teamTyping = typing }
    }

    /// Team sessions of a project whose client is waiting for an answer in the console right now.
    func teamPrompts(project: URL) -> [AgentSession] {
        sessions.filter { feeds[$0.id] != nil && $0.isRunning && $0.prompt != nil && $0.project == project }
    }

    // MARK: The coordinator's tools

    /// Answers a tool call. `caller` is the session that made it; every decision about rights is based on that
    /// session and its agent, never on the coordinator of the project the call is about. Texts are read by agents: English.
    func tool(_ name: String, _ args: [String: String], caller: UUID?) async -> [String: Any] {
        guard let session = sessions.first(where: { $0.id == caller && $0.isRunning }),
              let lead = agents.agent(session.agentID), lead.isCoordinator else {
            return ["error": "Only a running coordinator session may use these tools."]
        }
        switch name {
        case "list_projects":
            return ["projects": settings.projects.map { ["path": $0.path, "name": $0.lastPathComponent] }]
        case "overview":
            return ["projects": settings.projects.map(overview)]
        case "list_jobs":
            return ["jobs": sessions.map { s -> [String: String] in
                ["id": s.id.uuidString, "agent": agents.agent(s.agentID)?.name ?? "", "project": s.project.path,
                 "provider": s.provider.title, "state": s.isRunning ? "running" : (s.failed ? "interrupted" : "finished"),
                 "working": s.working ? "yes" : "no", "task": String(s.task.prefix(300))]
            }]
        default: break
        }
        guard let project = settings.projects.first(where: { $0.path == args["project"] }) else {
            return ["error": "Unknown project. Use a path from list_projects."]
        }
        let team = agents.agents(in: project).filter { !$0.isCoordinator }
        switch name {
        case "list_agents":
            return ["agents": team.map { ["id": $0.id.uuidString, "name": $0.name, "job": $0.jobTitle, "provider": $0.provider.title,
                                          "instructions": String($0.instructions.prefix(400))] }]
        case "start_named_agent":
            guard let agent = team.first(where: { $0.id.uuidString == args["agent"] }), let task = args["task"] else {
                return ["error": "Agent not found."]
            }
            // The coordinator reads histories and tasks of other agents. It therefore tasks agents with full access or
            // computer use only if the calling session may do the same; otherwise that stays with the user.
            guard mayReach(lead, agent, replies: false) else {
                return ["error": "\(agent.name) has full access or operates the computer. Only \(settings.value.owner) gives such tasks; ask them to write to \(agent.name) directly."]
            }
            guard allowRelays(1, project: project.path) else { return ["error": "Limit reached: at most \(Self.relayLimit) tasks per half hour."] }
            // Marked as the coordinator's message so that the task does not look typed by the user in the chat.
            let from = lead.project == project.path ? lead.name : "\(lead.name), \(URL(fileURLWithPath: lead.project).lastPathComponent)"
            switch hand(RelayedMessage.postPrefix + from + " (coordinator): " + task, to: agent) {
            case .delivered(let s), .queued(let s), .started(let s): return ["session": s.id.uuidString, "state": s.isRunning ? "running" : "starting"]
            case .failed(let reason): return ["error": reason]
            }
        case "list_chats", "read_chat":
            guard let rows = try? await PythonTool.run("history", ["list", project.path], as: [ChatEntry].self) else {
                return ["error": "The histories cannot be read."]
            }
            if name == "list_chats" { return ["chats": rows.prefix(50).map { ["id": $0.id, "provider": $0.provider, "title": $0.title] }] }
            guard let chat = rows.first(where: { $0.id == args["chat"] }),
                  let page = try? await PythonTool.run("history", ["read", chat.path, chat.provider, "0", "16"], as: ChatPage.self) else {
                return ["error": "Chat not found."]
            }
            return ["older": page.older, "messages": page.messages.map { ["role": $0.role, "text": String($0.text.prefix(6000))] }]
        default:
            return ["error": "Unknown tool."]
        }
    }

    private func overview(_ project: URL) -> [String: Any] {
        let people = agents.agents(in: project).filter { !$0.isCoordinator }
        return [
            "name": project.lastPathComponent, "path": project.path,
            "agents": people.map { agent -> [String: Any] in
                ["name": agent.name, "job": agent.jobTitle, "provider": agent.provider.title,
                 "working": sessions.contains { $0.agentID == agent.id && $0.working },
                 "session_open": liveSession(for: agent.id) != nil,
                 "last_task": String(agent.lastTask.prefix(200)),
                 "last_update": agent.updated.map(Timestamp.string) ?? ""]
            },
            "routines": routines.routines.filter { $0.project == project.path }.map { routine -> [String: Any] in
                ["agent": routine.agent.name, "time": routine.time, "days": routine.days.isEmpty ? "daily" : routine.days.map(String.init).joined(separator: ","),
                 "active": routine.active, "task": String(routine.task.prefix(200))]
            },
            "recent_routine_runs": routines.runs.filter { $0.project == project.path }.suffix(3).map { run -> [String: Any] in
                ["agent": run.name ?? "", "start": run.start, "ok": run.code == 0, "summary": String((run.output ?? "").suffix(600))]
            },
        ]
    }
}

enum SessionError: LocalizedError {
    case projectMissing, tooMany, toolsNotReady
    var errorDescription: String? {
        switch self {
        case .toolsNotReady: return t("The coordinator's tools are still starting. Try again in a few seconds.",
                                      "Die Werkzeuge des Koordinators starten noch. Versuch es in ein paar Sekunden noch einmal.")
        case .projectMissing: return t("The project folder cannot be reached.", "Der Projektordner ist nicht erreichbar.")
        case .tooMany: return t("\(SessionManager.maxRunning) sessions are already running. End one of them first.",
                                "Es laufen schon \(SessionManager.maxRunning) Sitzungen. Beende zuerst eine davon.")
        }
    }
}

/// Where a team session stands in its history and whether its answers belong in the team chat.
struct TeamFeed {
    var offset: Int
    var since: Date
    var open = true
    var answered = false
    var asked = Date()
    /// Colleagues the agent has already brought in during the current answer.
    var called = Set<UUID>()
}

struct WaitingPost {
    let session: UUID
    let agent: UUID
    let message: String
    let since: Date
}
