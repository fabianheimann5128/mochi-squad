import AppKit
import SwiftUI

enum Selection: Hashable { case agent(UUID), team, archive(ChatEntry) }
enum PanelTab: String, CaseIterable, Identifiable {
    case computer = "Computer", routines = "Routinen", context = "Kontext"
    var id: String { rawValue }
}

/// Hauptfenster: Seitenleiste, Chat oder Prozesse, rechte Spalte.
struct Workspace: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var agents: AgentStore
    @EnvironmentObject private var routines: RoutineStore
    @EnvironmentObject private var team: TeamLog
    @EnvironmentObject private var chats: ChatIndex
    @EnvironmentObject private var manager: SessionManager

    @State private var project: URL?
    @State private var selection: Selection?
    @State private var showProcesses = false
    @State private var showRail = true
    @State private var showPanel = true
    @State private var panelTab = PanelTab.computer
    @State private var editing: Agent?
    @State private var showSettings = false
    @State private var showConnectors = false

    /// Das gewählte Projekt. Verschwindet der letzte Ordner, wechselt RootView zur Einrichtung; bis dahin dient der Platzhalter.
    private var current: URL { project.flatMap { p in settings.projects.first { $0 == p } } ?? settings.projects.first ?? Self.placeholder }
    private static let placeholder = URL(fileURLWithPath: "/var/empty", isDirectory: true)
    private var selectedAgent: Agent? {
        if case .agent(let id) = selection { return agents.agent(id) }
        return nil
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            HStack(spacing: 0) {
                if showRail && width >= 720 {
                    Sidebar(project: current, selection: $selection, showProcesses: $showProcesses,
                            chooseProject: choose, addProject: addProject, removeProject: removeProject,
                            newAgent: { editing = Agent(name: "", job: "", project: current.path) },
                            hide: { withAnimation(.easeInOut(duration: 0.2)) { showRail = false } },
                            openSettings: { showSettings = true }, openConnectors: { showConnectors = true })
                        .frame(width: Desk.railWidth(width))
                    Rectangle().fill(Desk.rule).frame(width: 1)
                }
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
                if showPanel, !showProcesses, let agent = selectedAgent, width >= 900 {
                    Rectangle().fill(Desk.rule).frame(width: 1)
                    AgentPanel(agent: agent, tab: $panelTab, openProcesses: { showProcesses = true },
                               openConnectors: { showConnectors = true },
                               close: { withAnimation(.easeInOut(duration: 0.2)) { showPanel = false } })
                        .frame(width: Desk.panelWidth(width))
                }
            }
        }
        .background(Desk.canvas)
        .task(id: current) { await open(current) }
        .task {
            while !Task.isCancelled {
                routines.readRuns()
                attachRoutineRuns()
                try? await Task.sleep(for: .seconds(20))
            }
        }
        .onChange(of: agents.agents) { _, list in routines.sync(with: list) }
        .sheet(item: $editing) { agent in
            let store: (Agent) -> Void = { saved in
                agents.save(saved)
                selection = .agent(saved.id); showProcesses = false
            }
            if agents.agent(agent.id) == nil {
                AgentWizard(agent: agent, save: store).dialogStyle()
            } else {
                AgentEditor(agent: agent, save: store) {
                    if let live = manager.liveSession(for: agent.id) { manager.close(live) }
                    agents.remove(agent)
                    selection = agents.coordinator(in: current).map { .agent($0.id) }
                }.dialogStyle()
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView().dialogStyle() }
        .sheet(isPresented: $showConnectors) { ConnectorsView(project: current).dialogStyle() }
        .alert(AppPaths.appName, isPresented: Binding(get: { manager.notice != nil }, set: { if !$0 { manager.notice = nil } })) {
            Button("OK") { manager.notice = nil }
        } message: { Text(manager.notice ?? "") }
    }

    @ViewBuilder private var content: some View {
        if showProcesses {
            ProcessesView(project: current) { session in
                selection = .agent(session.agentID); showProcesses = false
            }
        } else {
            switch selection {
            case .agent(let id):
                if let agent = agents.agent(id) {
                    AgentChat(agent: agent, showRail: $showRail, showPanel: $showPanel, panelTab: $panelTab, edit: { editing = agent })
                        .id(id)
                }
            case .team:
                TeamChat(project: current, showRail: $showRail)
            case .archive(let entry):
                ArchiveChat(entry: entry, showRail: $showRail).id(entry.id)
            case nil:
                Color.clear
            }
        }
    }

    /// Läufe von Routinen gehören in den Chat ihres Agenten.
    private func attachRoutineRuns() {
        for run in routines.runs {
            guard let journal = run.journal, AgentSession.isJournal(journal), FileManager.default.fileExists(atPath: journal),
                  let id = run.agent.flatMap(UUID.init), let agent = agents.agent(id), !agent.journals.contains(journal) else { continue }
            agents.update(id) {
                $0.journals.append(journal)
                $0.lastLine = (run.output ?? "").split(separator: "\n").last.map(String.init)
                $0.updated = Timestamp.date(run.end ?? run.start) ?? Date()
            }
        }
    }

    private func open(_ folder: URL) async {
        guard folder != Self.placeholder else { return }
        agents.ensureCoordinator(in: folder, name: settings.value.coordinatorName)
        team.open(folder.path)
        if selectedAgent?.project != folder.path { selection = agents.coordinator(in: folder).map { .agent($0.id) } }
        await chats.refresh(folder)
    }

    private func choose(_ folder: URL) {
        project = folder
        showProcesses = false
    }

    private func addProject() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Projekt hinzufügen"
        guard panel.runModal() == .OK, let folder = panel.url?.standardizedFileURL.resolvingSymlinksInPath() else { return }
        guard settings.addProject(folder) else { manager.notice = SettingsStore.refusedProject; return }
        choose(folder)
    }

    private func removeProject(_ folder: URL) {
        guard settings.projects.count > 1 else { return }
        manager.sessions.filter { $0.project == folder }.forEach(manager.close)
        agents.removeProject(folder)
        settings.removeProject(folder)
        project = settings.projects.first
    }
}
