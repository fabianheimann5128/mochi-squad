import AppKit
import SwiftUI

enum Selection: Hashable { case agent(UUID), team, archive(ChatEntry) }
enum PanelTab: String, CaseIterable, Identifiable {
    case computer, routines, context
    var id: String { rawValue }
    var title: String {
        switch self {
        case .computer: return "Computer"
        case .routines: return t("Routines", "Routinen")
        case .context: return t("Context", "Kontext")
        }
    }
}

/// Main window: icon rail, chat list, chat or processes, right column.
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

    /// Below this window width the chat list gives way to the chat; the icon rail then shows the agents.
    private static let listFrom: CGFloat = 760

    /// The chosen project. If the last folder vanishes, RootView switches to setup; until then the placeholder serves.
    private var current: URL { project.flatMap { p in settings.projects.first { $0 == p } } ?? settings.projects.first ?? Self.placeholder }
    private static let placeholder = URL(fileURLWithPath: "/var/empty", isDirectory: true)
    private var selectedAgent: Agent? {
        if case .agent(let id) = selection { return agents.agent(id) }
        return nil
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let list = showRail && width >= Self.listFrom
            HStack(spacing: 0) {
                IconRail(project: current, selection: $selection, showProcesses: $showProcesses, showsAgents: !list,
                         newAgent: newAgent, openSettings: { showSettings = true }, openConnectors: { showConnectors = true })
                if list {
                    Sidebar(project: current, selection: $selection, showProcesses: $showProcesses,
                            chooseProject: choose, addProject: addProject, removeProject: removeProject, newAgent: newAgent,
                            hide: { withAnimation(.easeInOut(duration: 0.2)) { showRail = false } })
                        .frame(width: Desk.railWidth(width))
                }
                Rectangle().fill(Desk.rule).frame(width: 1)
                content(listShown: list || width < Self.listFrom).frame(maxWidth: .infinity, maxHeight: .infinity)
                if showPanel, !showProcesses, let agent = selectedAgent, width >= 1100 {
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
                // Keeps "More chats" current as well, for example after an agent was removed.
                if let project { await chats.refresh(project) }
                try? await Task.sleep(for: .seconds(20))
            }
        }
        .onChange(of: agents.agents) { _, list in routines.sync(with: list) }
        .sheet(item: $editing) { agent in
            let store: (Agent) -> Void = { saved in
                agents.save(saved)
                manager.settle(saved)
                selection = .agent(saved.id); showProcesses = false
            }
            if agents.agent(agent.id) == nil {
                AgentWizard(agent: agent, save: store).dialogStyle()
            } else {
                AgentEditor(agent: agent, save: store) {
                    if let live = manager.liveSession(for: agent.id) { manager.close(live) }
                    routines.removeRoutines(of: [agent.id])
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

    /// `listShown` is false only when the user hid the chat list on a wide window; the chat header then offers to bring it back.
    @ViewBuilder private func content(listShown: Bool) -> some View {
        let rail = Binding(get: { listShown }, set: { showRail = $0 })
        if showProcesses {
            ProcessesView(project: current, back: { showProcesses = false }) { session in
                selection = .agent(session.agentID); showProcesses = false
            }
        } else {
            switch selection {
            case .agent(let id):
                if let agent = agents.agent(id) {
                    AgentChat(agent: agent, showRail: rail, showPanel: $showPanel, panelTab: $panelTab, edit: { editing = agent })
                        .id(id)
                }
            case .team:
                TeamChat(project: current, showRail: rail)
            case .archive(let entry):
                ArchiveChat(entry: entry, showRail: rail).id(entry.id)
            case nil:
                Color.clear
            }
        }
    }

    private func newAgent() { editing = Agent(name: "", job: "", project: current.path) }

    /// Runs of routines belong in the chat of their agent.
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
        // Asking the clients takes a moment, so it happens only when a coordinator really has to be created.
        if agents.coordinator(in: folder) == nil {
            agents.ensureCoordinator(in: folder, name: settings.value.coordinatorName, provider: await Self.coordinatorProvider())
        }
        team.open(folder.path)
        if selectedAgent?.project != folder.path { selection = agents.coordinator(in: folder).map { .agent($0.id) } }
        await chats.refresh(folder)
    }

    /// A new coordinator runs with Claude Code where that is installed, otherwise with Codex.
    static func coordinatorProvider() async -> Provider {
        guard let status = await ClientStatus.load() else { return .claude }
        return !status.claude.installed && status.codex.installed ? .codex : .claude
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
        panel.prompt = t("Add project", "Projekt hinzufügen")
        guard panel.runModal() == .OK, let folder = panel.url?.standardizedFileURL.resolvingSymlinksInPath() else { return }
        guard settings.addProject(folder) else { manager.notice = SettingsStore.refusedProject; return }
        choose(folder)
    }

    private func removeProject(_ folder: URL) {
        guard settings.projects.count > 1 else { return }
        manager.sessions.filter { $0.project == folder }.forEach { manager.close($0) }
        routines.removeRoutines(of: agents.agents(in: folder).map(\.id))
        agents.removeProject(folder)
        settings.removeProject(folder)
        project = settings.projects.first
    }
}
