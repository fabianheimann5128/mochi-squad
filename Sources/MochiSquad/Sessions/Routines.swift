import Foundation

/// Ein Auftrag, den ein Agent zu festen Zeiten erledigt. macOS (launchd) startet ihn auch bei geschlossener App.
struct Routine: Codable, Identifiable, Equatable {
    /// Was routine.py über den Agenten wissen muss (Stand beim Speichern).
    struct AgentSnapshot: Codable, Equatable {
        var id: String, name: String, job: String, instructions: String, persona: String
        var model: String, effort: String, canEdit: Bool, isCoordinator: Bool
        var account: String?
        init(_ agent: Agent) {
            id = agent.id.uuidString; name = agent.name; job = agent.jobTitle; instructions = agent.instructions
            persona = agent.persona; model = agent.model; effort = agent.effort; canEdit = agent.canEdit; isCoordinator = agent.isCoordinator
            account = agent.provider == .codex ? agent.account : nil
        }
    }

    var id = String(UUID().uuidString.prefix(8)).lowercased()
    var project: String
    var agentID: UUID
    var provider: String
    var agent: AgentSnapshot
    var task = ""
    var hour = 8
    var minute = 0
    /// 1 = Montag … 7 = Sonntag; leer = täglich.
    var days: [Int] = []
    var active = false
    var allowWeb = false

    init(agent: Agent) {
        project = agent.project; agentID = agent.id; provider = agent.provider.rawValue; self.agent = AgentSnapshot(agent)
    }

    var time: String { String(format: "%02d:%02d", hour, minute) }
    var rhythm: String {
        if days.isEmpty { return "täglich" }
        if days.sorted() == [1, 2, 3, 4, 5] { return "Mo–Fr" }
        let names = ["", "Mo", "Di", "Mi", "Do", "Fr", "Sa", "So"]
        return days.sorted().filter { (1...7).contains($0) }.map { names[$0] }.joined(separator: ", ")
    }
}

/// Ein Lauf einer Routine aus routine-runs.jsonl.
struct RoutineRun: Decodable, Identifiable {
    let routine: String
    let project: String?
    let agent: String?
    let name: String?
    let start: String
    let end: String?
    let code: Int?
    let output: String?
    let journal: String?
    var id: String { routine + start }
}

@MainActor final class RoutineStore: ObservableObject {
    @Published private(set) var routines: [Routine]
    @Published private(set) var runs = [RoutineRun]()
    private let file = AppPaths.file("routines.json")
    private let runFile = AppPaths.file("routine-runs.jsonl")
    private var runOffset = 0
    private var label: String { (Bundle.main.bundleIdentifier ?? "mochisquad") + ".routine." }

    init() {
        routines = JSONFile.load([Routine].self, from: AppPaths.file("routines.json")) ?? []
        readRuns()
    }

    func routines(for agent: UUID) -> [Routine] { routines.filter { $0.agentID == agent } }
    func runs(for routine: String) -> [RoutineRun] { runs.filter { $0.routine == routine } }

    func save(_ routine: Routine) {
        if let index = routines.firstIndex(where: { $0.id == routine.id }) { routines[index] = routine } else { routines.append(routine) }
        persist()
        install(routine)
    }

    func remove(_ routine: Routine) {
        routines.removeAll { $0.id == routine.id }
        persist()
        uninstall(routine.id)
    }

    /// Hält die Angaben zum Agenten in allen seinen Routinen aktuell; entfernt Routinen gelöschter Agenten.
    func sync(with agents: [Agent]) {
        var changed = false
        for (index, routine) in routines.enumerated() {
            guard let agent = agents.first(where: { $0.id == routine.agentID }) else { continue }
            let snapshot = Routine.AgentSnapshot(agent)
            if routine.agent != snapshot || routine.provider != agent.provider.rawValue {
                routines[index].agent = snapshot; routines[index].provider = agent.provider.rawValue; changed = true
            }
        }
        let orphans = routines.filter { routine in !agents.contains { $0.id == routine.agentID } }
        orphans.forEach { uninstall($0.id) }
        routines.removeAll { routine in orphans.contains { $0.id == routine.id } }
        if changed || !orphans.isEmpty { persist() }
    }

    /// Einmal sofort ausführen, auch wenn die Routine pausiert ist.
    func runNow(_ routine: Routine) {
        guard let script = AppPaths.script("routine") else { return }
        let process = Process()
        process.executableURL = AppPaths.python
        process.arguments = ["-B", script.path, routine.id, "--now"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    /// Neue Läufe ab der zuletzt gelesenen Stelle übernehmen.
    func readRuns() {
        guard let handle = try? FileHandle(forReadingFrom: runFile) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()).map(Int.init) ?? 0
        if size < runOffset { runOffset = 0; runs = [] }
        guard size > runOffset else { return }
        try? handle.seek(toOffset: UInt64(runOffset))
        guard let data = try? handle.readToEnd(), let end = data.lastIndex(of: 10) else { return }
        let complete = data[...end]
        runOffset += complete.count
        let fresh = complete.split(separator: 10).compactMap { try? JSONDecoder().decode(RoutineRun.self, from: Data($0)) }
        runs = Array((runs + fresh).suffix(500))
    }

    /// Richtet die launchd-Aufträge aller Routinen ein (z. B. nach einem Update, wenn sich der App-Pfad geändert hat).
    func installAll() { routines.forEach(install) }

    private func persist() { try? JSONFile.save(routines, to: file) }

    private func plist(_ id: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label)\(id).plist")
    }

    private func install(_ routine: Routine) {
        guard routine.active, let script = AppPaths.script("routine") else { uninstall(routine.id); return }
        let valid = routine.days.filter { (1...7).contains($0) }
        let weekdays = valid.isEmpty ? [nil] : valid.map { Optional($0 % 7) }
        let intervals: [[String: Int]] = weekdays.map { day in
            var entry = ["Hour": routine.hour, "Minute": routine.minute]
            if let day { entry["Weekday"] = day }
            return entry
        }
        let content: [String: Any] = [
            "Label": label + routine.id,
            "ProgramArguments": [AppPaths.python.path, "-B", script.path, routine.id],
            "StartCalendarInterval": intervals,
            "StandardErrorPath": AppPaths.file("routine-\(routine.id).log").path,
        ]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: content, format: .xml, options: 0) else { return }
        let target = plist(routine.id)
        if (try? Data(contentsOf: target)) == data { return }
        try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: target, options: .atomic)
        let domain = "gui/\(getuid())", path = target.path, service = label + routine.id
        Task.detached(priority: .utility) {
            Self.launchctl(["bootout", domain + "/" + service])
            Self.launchctl(["bootstrap", domain, path])
        }
    }

    private func uninstall(_ id: String) {
        let target = plist(id)
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        let domain = "gui/\(getuid())", service = label + id
        try? FileManager.default.removeItem(at: target)
        Task.detached(priority: .utility) { Self.launchctl(["bootout", domain + "/" + service]) }
    }

    nonisolated private static func launchctl(_ args: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        process.waitUntilExit()
    }
}
