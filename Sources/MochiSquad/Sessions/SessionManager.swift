import Foundation

/// Verwaltet alle laufenden Sitzungen und die Zusammenarbeit der Agenten: Agenten-Post, Team-Chat,
/// wartende Nachrichten und die Werkzeuge des Koordinators. Die Oberfläche beobachtet nur.
@MainActor final class SessionManager: ObservableObject {
    enum Handover { case delivered(AgentSession), queued(AgentSession), started(AgentSession), failed(String) }

    nonisolated static let maxRunning = 8
    nonisolated static let relayLimit = 24
    nonisolated static let relayWindow: TimeInterval = 1800

    @Published private(set) var sessions = [AgentSession]()
    /// Wer im Team-Chat eines Projekts gerade schreibt (Namen).
    @Published private(set) var teamTyping = [String: [String]]()
    /// Fehlermeldung für den Nutzer.
    @Published var notice: String?
    /// Sitzungen, die die Oberfläche gerade zeigt, werden nicht aufgeräumt.
    var pinned = Set<UUID>()

    let agents: AgentStore
    let settings: SettingsStore
    let routines: RoutineStore
    let team: TeamLog
    let bridge = ToolBridge()

    private var feeds = [UUID: TeamFeed]()
    private var waiting = [WaitingPost]()
    private var relays = [String: [Date]]()
    private var lastTeamTargets = [String: [UUID]]()
    private var loops = [Task<Void, Never>]()

    init(agents: AgentStore, settings: SettingsStore, routines: RoutineStore, team: TeamLog) {
        self.agents = agents
        self.settings = settings
        self.routines = routines
        self.team = team
    }

    func start() {
        guard loops.isEmpty else { return }
        bridge.start { [weak self] name, args in await self?.tool(name, args) ?? ["error": "Mochi Squad wird beendet."] }
        loops = [
            Task { [weak self] in await self?.every(.seconds(2)) { await $0.pumpTeam() } },
            Task { [weak self] in await self?.every(.seconds(3)) { $0.retryWaiting() } },
            Task { [weak self] in await self?.every(.seconds(10)) { $0.prune() } },
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

    // MARK: Sitzungen

    func liveSession(for agent: UUID) -> AgentSession? { sessions.last { $0.agentID == agent && $0.isRunning } }
    func latestSession(for agent: UUID) -> AgentSession? { sessions.last { $0.agentID == agent } }
    var runningCount: Int { sessions.filter(\.isRunning).count }

    @discardableResult
    func launch(_ agent: Agent, task: String, parentChat: String? = nil) throws -> AgentSession {
        let project = URL(fileURLWithPath: agent.project, isDirectory: true)
        guard FileManager.default.fileExists(atPath: project.path) else { throw SessionError.projectMissing }
        guard runningCount < Self.maxRunning else { throw SessionError.tooMany }
        var tools: (config: String, token: String)?
        if agent.isCoordinator {
            guard let config = bridge.mcpConfig else { throw SessionError.toolsNotReady }
            tools = (config, bridge.token)
        }
        let session = try AgentSession(agent: agent, project: project, task: task)
        let team = agents.agents(in: project).filter { !$0.isCoordinator && $0.id != agent.id }.map { "\($0.name) (\($0.jobTitle))" }
        let spec = SessionSpec(agent: agent, project: project, task: task, sessionID: session.id, owner: settings.value.owner,
                               team: team, parentChat: parentChat)
        session.onPost = { [weak self, weak session] to, text in
            guard let self, let session else { return "Sitzung beendet." }
            return self.deliver(from: session, to: to, text: text)
        }
        session.onJournal = { [weak self] path in self?.agents.remember(journal: path, for: agent.id) }
        do { try session.launch(spec: spec, tools: tools) } catch {
            session.end()
            throw error
        }
        agents.update(agent.id) { $0.lastTask = task; $0.lastLine = nil; $0.updated = Date() }
        sessions.append(session)
        return session
    }

    func close(_ session: AgentSession) {
        waiting.removeAll { $0.session == session.id }
        feeds[session.id] = nil
        pinned.remove(session.id)
        session.end()
        sessions.removeAll { $0.id == session.id }
    }

    /// Beendete Sitzungen nach kurzer Zeit freigeben, sofern die Oberfläche sie nicht zeigt.
    private func prune() {
        let stale = sessions.filter { s in
            !s.isRunning && !pinned.contains(s.id) && (s.endedAt.map { Date().timeIntervalSince($0) > 20 } ?? false)
        }
        stale.forEach(close)
    }

    /// Chat-ID des letzten Verlaufs eines Claude-Agenten, um dort weiterzumachen.
    func resumableChat(for agent: Agent) -> String? {
        guard agent.provider == .claude else { return nil }
        return agent.journals.reversed().first { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
    }

    // MARK: Agenten-Post

    /// Übergibt eine Nachricht an die laufende Sitzung eines Agenten oder startet ihn damit.
    func hand(_ message: String, to agent: Agent) -> Handover {
        if let live = liveSession(for: agent.id) {
            if live.send(message) { return .delivered(live) }
            waiting.append(WaitingPost(session: live.id, agent: agent.id, message: message, since: Date()))
            return .queued(live)
        }
        do { return .started(try launch(agent, task: message, parentChat: resumableChat(for: agent))) }
        catch { return .failed(error.localizedDescription) }
    }

    /// Nachricht eines Agenten an einen anderen benannten Agenten desselben Projekts.
    func deliver(from origin: AgentSession, to name: String, text: String) -> String {
        let people = agents.agents(in: origin.project).filter { !$0.isCoordinator && $0.id != origin.agentID }
        let roster = people.map { "\($0.name) (\($0.jobTitle))" }.joined(separator: ", ")
        if name == "?" { return roster.isEmpty ? "Keine weiteren Agenten in diesem Projekt." : "Erreichbar: " + roster }
        guard let target = people.first(where: { $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) else {
            return "Kein Agent namens „\(name)“. Erreichbar: " + roster
        }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return "Die Nachricht ist leer." }
        guard allowRelays(1, project: origin.project.path) else { return "Das Limit von \(Self.relayLimit) Agenten-Nachrichten je halbe Stunde ist erreicht. Fasse den Stand im Chat zusammen." }
        let sender = agents.agent(origin.agentID)
        let message = RelayedMessage.postPrefix + (sender?.name ?? "Agent") + " (" + (sender?.jobTitle ?? "") + "): " + String(body.prefix(12_000))
        switch hand(message, to: target) {
        case .delivered: return "Zugestellt an \(target.name). Die Antwort erscheint als neue Nachricht in deinem Chat."
        case .queued: return "\(target.name) arbeitet gerade. Die Nachricht wird zugestellt, sobald die Eingabe frei ist."
        case .started: return "\(target.name) wurde mit deiner Nachricht gestartet."
        case .failed(let reason): return reason
        }
    }

    /// Weitergaben sind je Projekt begrenzt, damit ein gesprächiges Team andere Projekte nicht ausbremst.
    private func allowRelays(_ count: Int, project: String) -> Bool {
        let now = Date()
        var log = (relays[project] ?? []).filter { now.timeIntervalSince($0) <= Self.relayWindow }
        defer { relays[project] = log }
        guard log.count + count <= Self.relayLimit else { return false }
        log.append(contentsOf: Array(repeating: now, count: count))
        return true
    }

    /// Wartende Nachrichten zustellen, sobald die Eingabe des Empfängers frei ist.
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
            if Date().timeIntervalSince(item.since) > 900 {
                feeds[item.session]?.answered = true
                tell("Eine Nachricht an \(agent?.name ?? "einen Agenten") konnte 15 Minuten lang nicht zugestellt werden.")
            } else if let live = sessions.first(where: { $0.id == item.session }), live.isRunning {
                if !live.send(item.message) { waiting.append(item) }
            } else if let agent {
                let result = hand(item.message, to: agent)
                if forTeam { track(result, agent: agent) } else if case .failed(let reason) = result { tell(agent.name + ": " + reason) }
            }
        }
    }

    // MARK: Team-Chat

    func sendToTeam(_ text: String, project: URL) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        team.append(TeamLine(kind: .user, text: body), project: project.path)
        relay(body, from: nil, project: project)
    }

    /// Leitet eine Team-Nachricht an alle mit @Name Angesprochenen weiter. `origin` ist der schreibende Agent, nil für den Nutzer.
    @discardableResult
    private func relay(_ text: String, from origin: Agent?, project: URL, skip: Set<UUID> = []) -> Set<UUID> {
        let people = agents.agents(in: project).filter { !$0.isCoordinator && $0.id != origin?.id }
        var targets = people.filter { Mention.contains(text, $0.name) && !skip.contains($0.id) }
        if origin == nil {
            if Mention.contains(text, "alle") || Mention.contains(text, "team") { targets = people }
            if targets.isEmpty { targets = people.filter { (lastTeamTargets[project.path] ?? []).contains($0.id) } }
            guard !targets.isEmpty else {
                team.notice(people.isEmpty ? "Lege zuerst einen Agenten an, dann kannst du ihn hier mit @Name ansprechen."
                            : "Sprich einen Agenten mit @Name an, zum Beispiel @" + people[0].name + ".", project: project.path)
                return []
            }
            lastTeamTargets[project.path] = targets.map(\.id)
        } else {
            guard !targets.isEmpty else { return [] }
            guard allowRelays(targets.count, project: project.path) else {
                team.notice("Pause: Die Agenten haben das Limit von \(Self.relayLimit) Weitergaben je halbe Stunde erreicht.", project: project.path)
                return []
            }
        }
        let sender = origin?.name ?? settings.value.owner
        let message = RelayedMessage.teamPrefix + sender + ": " + String(text.prefix(8000))
            + team.context(project: project.path, owner: settings.value.owner) + RelayedMessage.teamHint
            + "Antworte kurz für alle im Team-Chat. Mit @Name holst du einen Kollegen dazu, wenn seine Rolle gefragt ist; sonst erwähne niemanden."
        for target in targets { track(hand(message, to: target), agent: target) }
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

    /// Liest neue Antworten der Team-Sitzungen aus ihren Verläufen und stellt sie in den Team-Chat.
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
                team.append(TeamLine(kind: .agent, from: agent.name, text: text, date: date), project: agent.project)
                let called = relay(text, from: agent, project: session.project, skip: feeds[session.id]?.called ?? [])
                feeds[session.id]?.called.formUnion(called)
            }
        }
        feeds = feeds.filter { id, _ in sessions.contains { $0.id == id } }
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

    /// Team-Sitzungen eines Projekts, deren Client gerade auf eine Antwort in der Konsole wartet.
    func teamPrompts(project: URL) -> [AgentSession] {
        sessions.filter { feeds[$0.id] != nil && $0.isRunning && $0.prompt != nil && $0.project == project }
    }

    // MARK: Werkzeuge des Koordinators

    private func tool(_ name: String, _ args: [String: String]) async -> [String: Any] {
        switch name {
        case "list_projects":
            return ["projects": settings.projects.map { ["path": $0.path, "name": $0.lastPathComponent] }]
        case "overview":
            return ["projects": settings.projects.map(overview)]
        case "list_jobs":
            return ["jobs": sessions.map { s -> [String: String] in
                ["id": s.id.uuidString, "agent": agents.agent(s.agentID)?.name ?? "", "project": s.project.path,
                 "provider": s.provider.title, "state": s.status, "working": s.working ? "yes" : "no", "task": String(s.task.prefix(300))]
            }]
        default: break
        }
        guard let project = settings.projects.first(where: { $0.path == args["project"] }) else {
            return ["error": "Unbekanntes Projekt. Nutze einen Pfad aus list_projects."]
        }
        let team = agents.agents(in: project).filter { !$0.isCoordinator }
        switch name {
        case "list_agents":
            return ["agents": team.map { ["id": $0.id.uuidString, "name": $0.name, "job": $0.jobTitle, "provider": $0.provider.title,
                                          "instructions": String($0.instructions.prefix(400))] }]
        case "start_named_agent":
            guard let agent = team.first(where: { $0.id.uuidString == args["agent"] }), let task = args["task"] else {
                return ["error": "Agent nicht gefunden."]
            }
            guard allowRelays(1, project: project.path) else { return ["error": "Limit erreicht: höchstens \(Self.relayLimit) Aufträge je halbe Stunde."] }
            switch hand(task, to: agent) {
            case .delivered(let s), .queued(let s), .started(let s): return ["session": s.id.uuidString, "state": s.status]
            case .failed(let reason): return ["error": reason]
            }
        case "list_chats", "read_chat":
            guard let rows = try? await PythonTool.run("history", ["list", project.path], as: [ChatEntry].self) else {
                return ["error": "Die Verläufe sind nicht lesbar."]
            }
            if name == "list_chats" { return ["chats": rows.prefix(50).map { ["id": $0.id, "provider": $0.provider, "title": $0.title] }] }
            guard let chat = rows.first(where: { $0.id == args["chat"] }),
                  let page = try? await PythonTool.run("history", ["read", chat.path, chat.provider, "0", "16"], as: ChatPage.self) else {
                return ["error": "Chat nicht gefunden."]
            }
            return ["older": page.older, "messages": page.messages.map { ["role": $0.role, "text": String($0.text.prefix(6000))] }]
        default:
            return ["error": "Unbekanntes Werkzeug."]
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
                ["agent": routine.agent.name, "time": routine.time, "days": routine.rhythm, "active": routine.active,
                 "task": String(routine.task.prefix(200))]
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
        case .toolsNotReady: return "Die Werkzeuge des Koordinators starten noch. Versuch es in ein paar Sekunden noch einmal."
        case .projectMissing: return "Der Projektordner ist nicht erreichbar."
        case .tooMany: return "Es laufen schon \(SessionManager.maxRunning) Sitzungen. Beende zuerst eine davon."
        }
    }
}

/// Wo eine Team-Sitzung in ihrem Verlauf steht und ob ihre Antworten in den Team-Chat gehören.
struct TeamFeed {
    var offset: Int
    var since: Date
    var open = true
    var answered = false
    var asked = Date()
    /// Kollegen, die der Agent in der laufenden Antwort schon dazugeholt hat.
    var called = Set<UUID>()
}

struct WaitingPost {
    let session: UUID
    let agent: UUID
    let message: String
    let since: Date
}
