import Foundation

/// A task an agent carries out at fixed times. macOS (launchd) starts it even when the app is closed.
struct Routine: Codable, Identifiable, Equatable {
    /// What routine.py needs to know about the agent. Always taken from the agent as it is when saving.
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
    /// 1 = Monday … 7 = Sunday; empty = daily.
    var days: [Int] = []
    var active = false
    var allowWeb = false
    /// What starts the routine; nil means a fixed time.
    var trigger: Trigger?
    /// For `.hours`: every how many hours.
    var every: Int?
    /// For `.folder`: the folder whose changes start the routine.
    var folder: String?
    /// Tell the user only when there is something new; otherwise the run stays silent.
    var quiet: Bool?

    enum Trigger: String, Codable, CaseIterable { case time, hours, folder }
    static let hourChoices = [1, 2, 3, 4, 6, 12]
    var kind: Trigger { trigger ?? .time }
    var hours: Int { Self.hourChoices.contains(every ?? 0) ? every! : 1 }

    init(agent: Agent) {
        project = agent.project; agentID = agent.id; provider = agent.provider.rawValue; self.agent = AgentSnapshot(agent)
    }

    /// The part the user edits. Two routines that agree here differ at most in what the app keeps current itself.
    var plan: [String] {
        [task, "\(hour)", "\(minute)", days.map(String.init).joined(separator: ","), "\(active)", "\(allowWeb)",
         kind.rawValue, "\(hours)", folder ?? "", "\(quiet == true)"]
    }

    /// One line for lists: "daily at 08:00", "every 2 hours", "when Downloads changes".
    var summary: String {
        switch kind {
        case .time: return rhythm + t(" at ", " um ") + time
        case .hours: return hours == 1 ? t("every hour", "jede Stunde") : t("every \(hours) hours", "alle \(hours) Stunden")
        case .folder: return t("when “\(folderName)” changes", "wenn sich „\(folderName)“ ändert")
        }
    }
    var folderName: String { folder.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "–" }

    static var dayNames: [String] {
        L10n.language == .en ? ["", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"] : ["", "Mo", "Di", "Mi", "Do", "Fr", "Sa", "So"]
    }

    var time: String { String(format: "%02d:%02d", hour, minute) }
    var rhythm: String {
        if days.isEmpty { return t("daily", "täglich") }
        if days.sorted() == [1, 2, 3, 4, 5] { return t("Mon–Fri", "Mo–Fr") }
        return days.sorted().filter { (1...7).contains($0) }.map { Self.dayNames[$0] }.joined(separator: ", ")
    }
}

/// One run of a routine from routine-runs.jsonl.
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
    /// A quiet routine found nothing new.
    let silent: Bool?
    var id: String { routine + start }
}

@MainActor final class RoutineStore: ObservableObject {
    @Published private(set) var routines: [Routine]
    @Published private(set) var runs = [RoutineRun]()
    /// Routines whose macOS schedule could not be set up, with the reason. "Active" alone proves nothing.
    @Published private(set) var scheduleIssues = [String: String]()
    /// Routines whose test run, started from the app, is still going.
    @Published private(set) var testing = Set<String>()
    /// Called for every run that finished while the app was open (not for those read at launch).
    var onFinished: ((RoutineRun) -> Void)?
    private var runsLoaded = false
    private let file: URL
    private let runFile: URL
    private var runOffset = 0
    private var label: String { (Bundle.main.bundleIdentifier ?? "mochisquad") + ".routine." }

    init(file: URL = AppPaths.file("routines.json"), runFile: URL = AppPaths.file("routine-runs.jsonl")) {
        self.file = file
        self.runFile = runFile
        routines = JSONFile.load([Routine].self, from: file) ?? []
        readRuns()
        runsLoaded = true
    }

    func routines(for agent: UUID) -> [Routine] { routines.filter { $0.agentID == agent } }
    func runs(for routine: String) -> [RoutineRun] { runs.filter { $0.routine == routine } }

    /// Stores task and schedule. Rights, model and subscription always come from `agent` as it is now:
    /// a form that was open for a while must not bring back what the user has changed since.
    func save(_ routine: Routine, agent: Agent) {
        var routine = routine
        routine.agent = Routine.AgentSnapshot(agent)
        routine.provider = agent.provider.rawValue
        routine.project = agent.project
        if let index = routines.firstIndex(where: { $0.id == routine.id }) { routines[index] = routine } else { routines.append(routine) }
        persist()
        install(routine)
    }

    func remove(_ routine: Routine) {
        routines.removeAll { $0.id == routine.id }
        persist()
        uninstall(routine.id)
    }

    /// Keeps the agent details in all its routines current. Nothing is deleted here: a routine whose agent is
    /// missing (for example after a damaged agents file) stays until the user removes the agent or the project.
    func sync(with agents: [Agent]) {
        var changed = false
        for (index, routine) in routines.enumerated() {
            guard let agent = agents.first(where: { $0.id == routine.agentID }) else { continue }
            let snapshot = Routine.AgentSnapshot(agent)
            if routine.agent != snapshot || routine.provider != agent.provider.rawValue {
                routines[index].agent = snapshot; routines[index].provider = agent.provider.rawValue; changed = true
                install(routines[index])
            }
        }
        if changed { persist() }
    }

    /// The user removed these agents: their routines and schedules go with them.
    func removeRoutines(of agents: [UUID]) {
        let gone = routines.filter { agents.contains($0.agentID) }
        guard !gone.isEmpty else { return }
        gone.forEach { uninstall($0.id) }
        routines.removeAll { routine in gone.contains { $0.id == routine.id } }
        persist()
    }

    /// Starts the routine right away, even when it is paused. `false` if the helper could not be started.
    @discardableResult
    func runNow(_ routine: Routine) -> Bool {
        guard let script = AppPaths.script("routine") else { return false }
        let process = Process()
        process.executableURL = AppPaths.python
        process.arguments = ["-B", script.path, routine.id, "--now"]
        process.environment = AppPaths.helperEnvironment()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let id = routine.id
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.testing.remove(id)
                self?.readRuns()
            }
        }
        guard (try? process.run()) != nil else { return false }
        testing.insert(id)
        return true
    }

    /// Take over new runs from the position read last.
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
        if runsLoaded { fresh.forEach { onFinished?($0) } }
    }

    /// Sets up the launchd jobs of all routines and checks that macOS really knows them
    /// (for example after an update, when the app's path changed, or when a job got lost).
    func installAll() { routines.forEach(install) }

    private func persist() {
        SaveGuard.save(t("routines", "Routinen")) { [routines, file] in try JSONFile.save(routines, to: file) }
    }

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
        var content: [String: Any] = [
            "Label": label + routine.id,
            "ProgramArguments": [AppPaths.python.path, "-B", script.path, routine.id],
            "StandardErrorPath": AppPaths.file("routine-\(routine.id).log").path,
        ]
        switch routine.kind {
        case .time: content["StartCalendarInterval"] = intervals
        case .hours: content["StartInterval"] = routine.hours * 3600
        case .folder:
            guard let folder = routine.folder else { uninstall(routine.id); return }
            // macOS starts the routine itself when the folder changes; a burst of changes starts it at most every two minutes.
            content["WatchPaths"] = [folder]
            content["ThrottleInterval"] = 120
        }
        let id = routine.id, target = plist(id)
        let failed = t("macOS did not accept the schedule. The routine will not start on its own; save it again or check ~/Library/LaunchAgents.",
                       "macOS hat den Zeitplan nicht angenommen. Die Routine startet nicht von selbst; speichere sie erneut oder prüfe ~/Library/LaunchAgents.")
        guard let data = try? PropertyListSerialization.data(fromPropertyList: content, format: .xml, options: 0) else { return }
        let unchanged = (try? Data(contentsOf: target)) == data
        if !unchanged {
            do {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: target, options: .atomic)
            } catch {
                scheduleIssues[id] = failed
                return
            }
        }
        let domain = "gui/\(getuid())", path = target.path, service = label + id
        Task.detached(priority: .utility) { [weak self] in
            // An unchanged file is no proof that the job is loaded: ask launchd, and load it if it is missing.
            var loaded = unchanged && Self.launchctl(["print", domain + "/" + service])
            if !loaded {
                Self.launchctl(["bootout", domain + "/" + service])
                loaded = Self.launchctl(["bootstrap", domain, path]) && Self.launchctl(["print", domain + "/" + service])
            }
            let ok = loaded
            await self?.noteSchedule(id, issue: ok ? nil : failed)
        }
    }

    private func noteSchedule(_ id: String, issue: String?) { scheduleIssues[id] = issue }

    private func uninstall(_ id: String) {
        scheduleIssues[id] = nil
        let target = plist(id)
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        let domain = "gui/\(getuid())", service = label + id
        try? FileManager.default.removeItem(at: target)
        Task.detached(priority: .utility) { Self.launchctl(["bootout", domain + "/" + service]) }
    }

    /// Runs launchctl; true if it reported success.
    @discardableResult
    nonisolated private static func launchctl(_ args: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
