import Foundation

/// The supported agent programs. Sign-in happens in the client itself, with the user's own subscription.
enum Provider: String, Codable, CaseIterable, Identifiable {
    case claude, codex
    var id: String { rawValue }
    var title: String { self == .claude ? "Claude Code" : "Codex" }
    var vendor: String { self == .claude ? "Anthropic" : "OpenAI" }

    /// Models to choose from. `account` is an extra ChatGPT subscription whose plan may offer a different list.
    func models(account: String? = nil) -> [String] {
        self == .claude ? ClaudeModels.all.map(\.id) : CodexCatalog.models(account: account).map(\.slug)
    }

    /// The model a new agent gets, and the fallback for an agent whose model is no longer offered.
    func defaultModel(account: String? = nil) -> String {
        self == .claude ? ClaudeModels.standard : models(account: account).first ?? ""
    }

    /// Name of a model as people know it ("Opus 5.5", "GPT-6.2-Sol"); unknown ids are shown as they are.
    func label(for model: String, account: String? = nil) -> String {
        switch self {
        case .claude: return ClaudeModels.all.first { $0.id == model }?.label ?? model
        case .codex: return CodexCatalog.models(account: account).first { $0.slug == model }?.display_name ?? model
        }
    }

    func efforts(for model: String, account: String? = nil) -> [String] {
        switch self {
        case .claude: return model.contains("haiku") ? [] : ["low", "medium", "high", "xhigh", "max"]
        case .codex:
            let all = CodexCatalog.models(account: account)
            let entry = all.first { $0.slug == model } ?? all.first
            return entry?.supported_reasoning_levels.map(\.effort) ?? ["low", "medium", "high"]
        }
    }
}

/// The Claude models an agent can work with. Claude Code takes the exact ids; the short names always mean the
/// newest model of a family and stay available for agents that were created with them.
enum ClaudeModels {
    struct Model { let id: String, label: String }
    static let standard = "claude-opus-5-5"
    static var all: [Model] {
        [Model(id: "claude-fable-5-2", label: "Fable 5.2"),
         Model(id: "claude-opus-5-5", label: "Opus 5.5"),
         Model(id: "claude-sonnet-5-5", label: "Sonnet 5.5"),
         Model(id: "claude-haiku-5-5", label: "Haiku 5.5"),
         Model(id: "opus", label: t("Opus · always the newest", "Opus · immer das neueste")),
         Model(id: "sonnet", label: t("Sonnet · always the newest", "Sonnet · immer das neueste")),
         Model(id: "haiku", label: t("Haiku · always the newest", "Haiku · immer das neueste"))]
    }
}

/// Model list that Codex caches itself (models_cache.json in its home folder).
enum CodexCatalog {
    struct Model: Decodable {
        struct Level: Decodable { let effort: String }
        let slug: String
        let display_name: String?
        let visibility: String
        let supported_reasoning_levels: [Level]
    }

    private static let lock = NSLock()
    private static var cache = [String: (stamp: Date, models: [Model])]()

    /// The list of the given subscription, or the standard one while that subscription has none yet.
    static func models(account: String? = nil) -> [Model] {
        let standard = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex")
        let homes = [account.flatMap(AppPaths.accountHome), standard].compactMap { $0 }
        return homes.lazy.map { load($0.appendingPathComponent("models_cache.json")) }.first { !$0.isEmpty } ?? []
    }

    /// Re-read only when the file changed: Codex refreshes it after sign-in and plan changes.
    private static func load(_ file: URL) -> [Model] {
        struct Cache: Decodable { let models: [Model] }
        let stamp = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date) ?? .distantPast
        lock.lock(); defer { lock.unlock() }
        if let known = cache[file.path], known.stamp == stamp { return known.models }
        let models = (JSONFile.load(Cache.self, from: file)?.models ?? []).filter { $0.visibility == "list" }
        cache[file.path] = (stamp, models)
        return models
    }
}

/// A named agent in a project.
struct Agent: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var job: String
    var instructions = ""
    var persona = ""
    var provider = Provider.claude
    var model = ""
    var effort = ""
    var project: String
    var avatar = MochiLook.random().key
    var isCoordinator = false
    /// May change files in the project; commands then run in the client's sandbox.
    var canEdit = false
    /// Full access to the whole Mac: no sandbox, no confirmations. Only when the user explicitly asks for it.
    var fullAccess: Bool?
    /// May operate the computer: apps and browser with Codex, the Chrome browser with Claude Code.
    var computerUse: Bool?
    /// Id of an extra ChatGPT subscription (Codex only); nil uses the regular sign-in.
    var account: String?
    var journals: [String] = []
    /// History files written by routine runs. They are shown in the chat like any other, but a new message never
    /// continues from one, and one that was dropped from `journals` is not attached a second time.
    var routineJournals: [String]?
    var lastTask = ""
    var lastLine: String?
    var updated: Date?

    static let journalLimit = 8

    /// How far an agent may reach, in three levels.
    enum Access: String, CaseIterable, Identifiable {
        case read, edit, full
        var id: String { rawValue }
        /// The higher, the more the agent may do.
        var rank: Int { ["read": 0, "edit": 1, "full": 2][rawValue]! }
        var title: String {
            switch self {
            case .read: return t("Read only", "Nur lesen")
            case .edit: return t("Edit in project", "Im Projekt ändern")
            case .full: return t("Full access", "Vollzugriff")
            }
        }
        var note: String {
            switch self {
            case .read: return t("Reads in the project and asks you in the chat when it needs more.",
                                 "Liest im Projekt und fragt dich im Chat, wenn mehr nötig ist.")
            case .edit: return t("Works in a sandbox that may only write inside the project.",
                                 "Arbeitet in einer Sandbox, die nur ins Projekt schreiben darf.")
            case .full: return t("No sandbox and no confirmations: the agent can read, change and delete every file and app on this Mac. Only for agents you trust completely.",
                                 "Ohne Sandbox und ohne Rückfragen: Der Agent kann alle Dateien und Programme dieses Macs lesen, ändern und löschen. Nur für Agenten, denen du voll vertraust.")
            }
        }
    }

    /// Models and reasoning levels on offer for this agent's provider and subscription.
    var models: [String] { provider.models(account: account) }
    var efforts: [String] { provider.efforts(for: model, account: account) }
    var modelLabel: String { provider.label(for: model, account: account) }

    /// Every agent has an explicit model; if it is missing or does not fit the provider, the provider's default applies.
    /// The reasoning depth is checked as well, also when the model stays: another plan or model may not offer it.
    func withModel() -> Agent {
        var copy = self
        if !models.isEmpty, !models.contains(model) { copy.model = provider.defaultModel(account: account) }
        if !copy.effort.isEmpty, !copy.efforts.contains(copy.effort) { copy.effort = "" }
        return copy
    }

    /// Everything that is fixed when a session starts. If it differs later, the session needs a restart.
    var sessionSignature: String {
        [provider.rawValue, model, effort, access.rawValue, account ?? "", computerUse == true ? "cu" : "", name, job, instructions, persona]
            .joined(separator: "\u{1f}")
    }

    var access: Access {
        get { fullAccess == true ? .full : canEdit ? .edit : .read }
        set { canEdit = newValue != .read; fullAccess = newValue == .full ? true : nil }
    }

    /// The coordinator's title follows the interface language; other agents keep what the user typed.
    var jobTitle: String {
        if isCoordinator { return t("Coordinator", "Koordinator") }
        return job.isEmpty ? "Agent" : job
    }

    static func coordinator(name: String, project: String, provider: Provider = .claude) -> Agent {
        Agent(name: name, job: "", provider: provider, model: provider.defaultModel(), project: project,
              avatar: MochiLook.coordinator.key, isCoordinator: true)
    }
}

/// Starting points for new agents. Everything stays editable afterwards.
struct AgentTemplate: Identifiable {
    let job, instructions, symbol: String
    let canEdit: Bool
    var id: String { symbol }

    static var all: [AgentTemplate] {
        [
            AgentTemplate(job: t("Developer", "Entwickler"),
                          instructions: t("Implements tasks in the code, writes tests and explains changes in a few sentences.",
                                          "Setzt Aufgaben im Code um, schreibt Tests und erklärt Änderungen in wenigen Sätzen."),
                          symbol: "chevron.left.forwardslash.chevron.right", canEdit: true),
            AgentTemplate(job: "Researcher",
                          instructions: t("Researches thoroughly from primary sources and saves the results with references as a file.",
                                          "Recherchiert gründlich an Originalquellen und legt Ergebnisse mit Quellenangaben als Datei ab."),
                          symbol: "text.magnifyingglass", canEdit: true),
            AgentTemplate(job: "Reviewer",
                          instructions: t("Reviews code and texts critically and names concrete, prioritised improvements. Changes nothing itself.",
                                          "Prüft Code und Texte kritisch und nennt konkrete, priorisierte Verbesserungen. Ändert selbst nichts."),
                          symbol: "checkmark.seal", canEdit: false),
            AgentTemplate(job: t("Writer", "Autor"),
                          instructions: t("Writes and revises texts in the project, clear and easy to follow.",
                                          "Schreibt und überarbeitet Texte im Projekt klar und verständlich."),
                          symbol: "pencil.line", canEdit: true),
        ]
    }
}

/// All agents of all projects, stored in agents.json.
@MainActor final class AgentStore: ObservableObject {
    @Published private(set) var agents: [Agent]
    /// The file existed but could not be read. It was backed up; dependent data stays untouched.
    let loadFailed: Bool
    private let file: URL
    private let saver = Debouncer()

    init(file: URL = AppPaths.file("agents.json")) {
        self.file = file
        let loaded = JSONFile.load([Agent].self, from: file)
        loadFailed = loaded == nil && FileManager.default.fileExists(atPath: file.path)
        if loadFailed {
            let backup = file.deletingPathExtension().appendingPathExtension("damaged-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: file, to: backup)
        }
        agents = (loaded ?? []).map { $0.withModel() }
    }

    func agents(in project: URL) -> [Agent] { agents.filter { $0.project == project.path } }
    func agent(_ id: UUID?) -> Agent? { id.flatMap { id in agents.first { $0.id == id } } }
    func coordinator(in project: URL) -> Agent? { agents.first { $0.project == project.path && $0.isCoordinator } }

    /// Every project has exactly one coordinator; the user adds further agents.
    func ensureCoordinator(in project: URL, name: String, provider: Provider = .claude) {
        guard coordinator(in: project) == nil else { return }
        agents.append(Agent.coordinator(name: name, project: project.path, provider: provider).withModel())
        persist()
    }

    /// After a damaged agents file: bring back the agents that routines still describe, with their ids,
    /// so those routines keep their owner. Returns how many agents came back.
    @discardableResult
    func restore(from routines: [Routine]) -> Int {
        var restored = 0
        for routine in routines where agent(routine.agentID) == nil {
            guard let provider = Provider(rawValue: routine.provider) else { continue }
            let snapshot = routine.agent
            // One project never gets two coordinators.
            let lead = snapshot.isCoordinator && coordinator(in: URL(fileURLWithPath: routine.project)) == nil
            var agent = Agent(id: routine.agentID, name: snapshot.name, job: lead ? "" : snapshot.job, instructions: snapshot.instructions,
                              persona: snapshot.persona, provider: provider, model: snapshot.model, effort: snapshot.effort,
                              project: routine.project, isCoordinator: lead, canEdit: snapshot.canEdit)
            agent.account = snapshot.account
            if lead { agent.avatar = MochiLook.coordinator.key }
            agents.append(agent.withModel())
            restored += 1
        }
        if restored > 0 { persist() }
        return restored
    }

    /// Agents of a removed subscription work with the regular sign-in again.
    func releaseAccount(_ id: String) {
        for index in agents.indices where agents[index].account == id { agents[index].account = nil }
        persist()
    }

    /// Does another agent in the same project already carry this name? Compared like delivery does: ignoring case and accents.
    func nameTaken(_ name: String, by agent: Agent) -> Bool {
        let wanted = name.trimmingCharacters(in: .whitespaces)
        return agents.contains { $0.project == agent.project && $0.id != agent.id
            && $0.name.compare(wanted, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }

    func renameCoordinators(to name: String) {
        for index in agents.indices where agents[index].isCoordinator { agents[index].name = name }
        persist()
    }

    /// Stores what the user edited. What the app tracks on its own (history files, previews) is kept from the stored
    /// agent: an editor that was open for a while must not write an older state over it.
    func save(_ agent: Agent) {
        var agent = agent.withModel()
        if let index = agents.firstIndex(where: { $0.id == agent.id }) {
            let stored = agents[index]
            agent.journals = stored.journals; agent.routineJournals = stored.routineJournals
            agent.lastTask = stored.lastTask; agent.lastLine = stored.lastLine; agent.updated = stored.updated
            agents[index] = agent
        } else {
            agents.append(agent)
        }
        persist()
    }

    func update(_ id: UUID, _ change: (inout Agent) -> Void) {
        guard let index = agents.firstIndex(where: { $0.id == id }) else { return }
        var copy = agents[index]
        change(&copy)
        if copy != agents[index] { agents[index] = copy; persist() }
    }

    func remove(_ agent: Agent) {
        guard !agent.isCoordinator else { return }
        agents.removeAll { $0.id == agent.id }
        persist()
    }

    func removeProject(_ project: URL) {
        agents.removeAll { $0.project == project.path }
        persist()
    }

    /// Remembers a history file of the agent so its chat continues across sessions.
    func remember(journal: String, for id: UUID) {
        update(id) {
            guard !$0.journals.contains(journal) else { return }
            $0.journals.append(journal)
            // Only the most recent ones count for the chat; older ones stay under "More chats".
            if $0.journals.count > Agent.journalLimit { $0.journals.removeFirst($0.journals.count - Agent.journalLimit) }
        }
    }

    /// The agent's conversations leave its chat and show under "More chats"; routine runs stay attached.
    func archiveConversations(of id: UUID) {
        update(id) { agent in agent.journals = agent.journals.filter { (agent.routineJournals ?? []).contains($0) } }
    }

    /// Adds the history of a routine run to the agent's chat, once. The preview moves only forward in time.
    func attach(routineJournal journal: String, to id: UUID, lastLine: String?, finished: Date) {
        update(id) {
            guard !($0.routineJournals ?? []).contains(journal), !$0.journals.contains(journal) else { return }
            $0.routineJournals = Array((($0.routineJournals ?? []) + [journal]).suffix(60))
            $0.journals.append(journal)
            if $0.journals.count > Agent.journalLimit { $0.journals.removeFirst($0.journals.count - Agent.journalLimit) }
            if finished > ($0.updated ?? .distantPast) { $0.lastLine = lastLine; $0.updated = finished }
        }
    }

    /// Write right away (e.g. when the app quits).
    func flush() { saver.flush { self.write() } }

    private func persist() { saver.run { self.write() } }
    private func write() { SaveGuard.save(t("agents", "Agenten")) { [agents, file] in try JSONFile.save(agents, to: file) } }
}
