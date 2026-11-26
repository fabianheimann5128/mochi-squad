import Foundation

/// Die unterstützten Agent-Programme. Angemeldet wird mit dem eigenen Abo im jeweiligen Client.
enum Provider: String, Codable, CaseIterable, Identifiable {
    case claude, codex
    var id: String { rawValue }
    var title: String { self == .claude ? "Claude Code" : "Codex" }
    var vendor: String { self == .claude ? "Anthropic" : "OpenAI" }

    /// Modelle zur Auswahl; leer bedeutet „Standard des Clients“.
    var models: [String] { self == .claude ? ["opus", "sonnet", "haiku"] : CodexCatalog.models.map(\.slug) }

    func efforts(for model: String) -> [String] {
        switch self {
        case .claude: return model == "haiku" ? [] : ["low", "medium", "high", "xhigh", "max"]
        case .codex:
            let entry = CodexCatalog.models.first { $0.slug == model } ?? CodexCatalog.models.first
            return entry?.supported_reasoning_levels.map(\.effort) ?? ["low", "medium", "high"]
        }
    }
}

/// Modellliste, die Codex selbst zwischenspeichert (~/.codex/models_cache.json).
enum CodexCatalog {
    struct Model: Decodable {
        struct Level: Decodable { let effort: String }
        let slug: String
        let visibility: String
        let supported_reasoning_levels: [Level]
    }
    static let models: [Model] = {
        struct Cache: Decodable { let models: [Model] }
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex"
        guard let cache = JSONFile.load(Cache.self, from: URL(fileURLWithPath: home + "/models_cache.json")) else { return [] }
        return cache.models.filter { $0.visibility == "list" }
    }()
}

/// Ein benannter Agent in einem Projekt.
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
    /// Darf im Projekt Dateien ändern; Befehle laufen dann in der Sandbox des Clients.
    var canEdit = false
    /// Kennung eines weiteren ChatGPT-Abos (nur Codex); nil nutzt die normale Anmeldung.
    var account: String?
    var journals: [String] = []
    var lastTask = ""
    var lastLine: String?
    var updated: Date?

    static let journalLimit = 8

    var jobTitle: String { job.isEmpty ? (isCoordinator ? "Koordinator" : "Agent") : job }

    static func coordinator(name: String, project: String) -> Agent {
        Agent(name: name, job: "Koordinator", provider: .claude, model: "opus", project: project,
              avatar: MochiLook.coordinator.key, isCoordinator: true)
    }
}

/// Vorlagen für neue Agenten. Alles bleibt danach frei änderbar.
struct AgentTemplate: Identifiable {
    let job, instructions, symbol: String
    let canEdit: Bool
    var id: String { job }

    static let all = [
        AgentTemplate(job: "Entwickler", instructions: "Setzt Aufgaben im Code um, schreibt Tests und erklärt Änderungen in wenigen Sätzen.",
                      symbol: "chevron.left.forwardslash.chevron.right", canEdit: true),
        AgentTemplate(job: "Researcher", instructions: "Recherchiert gründlich an Originalquellen und legt Ergebnisse mit Quellenangaben als Datei ab.",
                      symbol: "text.magnifyingglass", canEdit: true),
        AgentTemplate(job: "Reviewer", instructions: "Prüft Code und Texte kritisch und nennt konkrete, priorisierte Verbesserungen. Ändert selbst nichts.",
                      symbol: "checkmark.seal", canEdit: false),
        AgentTemplate(job: "Autor", instructions: "Schreibt und überarbeitet Texte im Projekt klar und verständlich.",
                      symbol: "pencil.line", canEdit: true),
        AgentTemplate(job: "", instructions: "", symbol: "sparkles", canEdit: false)
    ]
}

/// Alle Agenten aller Projekte, gespeichert in agents.json.
@MainActor final class AgentStore: ObservableObject {
    @Published private(set) var agents: [Agent]
    /// Die Datei war da, ließ sich aber nicht lesen. Sie wurde gesichert; abhängige Daten bleiben unangetastet.
    let loadFailed: Bool
    private let file: URL
    private let saver = Debouncer()

    init(file: URL = AppPaths.file("agents.json")) {
        self.file = file
        let loaded = JSONFile.load([Agent].self, from: file)
        loadFailed = loaded == nil && FileManager.default.fileExists(atPath: file.path)
        if loadFailed {
            let backup = file.deletingPathExtension().appendingPathExtension("defekt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: file, to: backup)
        }
        agents = loaded ?? []
    }

    func agents(in project: URL) -> [Agent] { agents.filter { $0.project == project.path } }
    func agent(_ id: UUID?) -> Agent? { id.flatMap { id in agents.first { $0.id == id } } }
    func coordinator(in project: URL) -> Agent? { agents.first { $0.project == project.path && $0.isCoordinator } }

    /// Jedes Projekt hat genau einen Koordinator; weitere Agenten legt der Nutzer selbst an.
    func ensureCoordinator(in project: URL, name: String) {
        guard coordinator(in: project) == nil else { return }
        agents.append(.coordinator(name: name, project: project.path))
        persist()
    }

    /// Agenten eines entfernten Abos arbeiten wieder mit der normalen Anmeldung.
    func releaseAccount(_ id: String) {
        for index in agents.indices where agents[index].account == id { agents[index].account = nil }
        persist()
    }

    func renameCoordinators(to name: String) {
        for index in agents.indices where agents[index].isCoordinator { agents[index].name = name }
        persist()
    }

    func save(_ agent: Agent) {
        if let index = agents.firstIndex(where: { $0.id == agent.id }) { agents[index] = agent } else { agents.append(agent) }
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

    /// Merkt sich einen Verlauf des Agenten, damit sein Chat über mehrere Sitzungen durchgeht.
    func remember(journal: String, for id: UUID) {
        update(id) {
            guard !$0.journals.contains(journal) else { return }
            $0.journals.append(journal)
            // Nur die jüngsten Verläufe zählen für den Chat; ältere bleiben unter „Weitere Chats“.
            if $0.journals.count > Agent.journalLimit { $0.journals.removeFirst($0.journals.count - Agent.journalLimit) }
        }
    }

    /// Sofort schreiben (z. B. beim Beenden der App).
    func flush() { saver.flush { self.write() } }

    private func persist() { saver.run { self.write() } }
    private func write() { try? JSONFile.save(agents, to: file) }
}
