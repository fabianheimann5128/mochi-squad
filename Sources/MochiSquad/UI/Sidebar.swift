import SwiftUI

/// Seitenleiste: Projekt, Team-Chat, Agenten, frühere Chats.
struct Sidebar: View {
    let project: URL
    @Binding var selection: Selection?
    @Binding var showProcesses: Bool
    let chooseProject: (URL) -> Void
    let addProject: () -> Void
    let removeProject: (URL) -> Void
    let newAgent: () -> Void
    let hide: () -> Void
    let openSettings: () -> Void
    let openConnectors: () -> Void

    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var agents: AgentStore
    @EnvironmentObject private var team: TeamLog
    @EnvironmentObject private var transcript: TranscriptStore
    @EnvironmentObject private var manager: SessionManager
    @State private var search = ""
    @State private var searching = false
    @State private var showArchive = false
    @State private var hovered: UUID?

    private var members: [Agent] { agents.agents(in: project) }
    private var crew: [Agent] { members.filter { !$0.isCoordinator } }
    private func matches(_ text: String) -> Bool { search.isEmpty || text.localizedCaseInsensitiveContains(search) }
    /// Chats, die keinem Agenten gehören (z. B. direkt im Terminal geführt).
    private var archive: [ChatEntry] {
        let known = Set(members.flatMap(\.journals))
        return transcript.entries.filter { !known.contains($0.path) && matches($0.title) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
                Spacer()
                tool("magnifyingglass", "Suchen", active: searching) { searching.toggle(); if !searching { search = "" } }
                tool("sidebar.left", "Seitenleiste ausblenden", action: hide)
                tool("plus", "Neuer Agent", action: newAgent).keyboardShortcut("n")
            }.padding(.horizontal, 12).frame(height: 52)
            if searching {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12.5)).foregroundStyle(Desk.dim)
                    TextField("Suchen", text: $search).textFieldStyle(.plain).font(.system(size: 13.5))
                }.padding(.horizontal, 11).frame(height: 34).field().padding(.horizontal, 12).padding(.bottom, 8)
            }
            Button { showProcesses = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "waveform.path.ecg").font(.system(size: 13.5)).frame(width: 20).foregroundStyle(showProcesses ? Desk.text : Desk.dim)
                    Text("Prozesse").font(.system(size: 13.5, weight: showProcesses ? .semibold : .regular))
                    Spacer()
                    if manager.runningCount > 0 {
                        Text("\(manager.runningCount)").font(.system(size: 11, weight: .bold).monospacedDigit()).foregroundStyle(.white)
                            .padding(.horizontal, 6).frame(minWidth: 18, minHeight: 18).background(Desk.accent, in: Capsule())
                    }
                }.padding(.horizontal, 10).frame(height: 32)
                    .background { if showProcesses { RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Desk.selected) } }
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).padding(.horizontal, 10)
            projectMenu.padding(.leading, 20).padding(.trailing, 14).padding(.top, 18).padding(.bottom, 6)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if !crew.isEmpty, matches("Team") {
                        Button { selection = .team; showProcesses = false } label: {
                            row(name: "Team", job: nil, time: team.lines.last?.date, preview: teamPreview,
                                chosen: selection == .team && !showProcesses, hoverID: nil) {
                                GroupAvatar(keys: crew.prefix(3).map(\.avatar), size: 38)
                            }
                        }.buttonStyle(.plain)
                    }
                    ForEach(members.filter { matches($0.name + " " + $0.jobTitle) }) { agent in
                        Button { selection = .agent(agent.id); showProcesses = false } label: {
                            AgentRow(agent: agent, session: manager.liveSession(for: agent.id),
                                     chosen: selection == .agent(agent.id) && !showProcesses, hovered: hovered == agent.id)
                        }.buttonStyle(.plain)
                            .onHover { inside in hovered = inside ? agent.id : (hovered == agent.id ? nil : hovered) }
                    }
                    if crew.isEmpty && search.isEmpty {
                        Button(action: newAgent) {
                            Label("Agent anlegen", systemImage: "plus").font(.system(size: 13, weight: .medium))
                                .frame(maxWidth: .infinity).frame(height: 40)
                                .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Desk.edge) }
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).padding(.top, 8)
                        Text("Dein Koordinator ist startklar. Lege Agenten für die Aufgaben an, die du abgeben willst.")
                            .font(.system(size: 12.5)).foregroundStyle(Desk.dim).padding(.horizontal, 4).padding(.top, 8)
                    }
                    if !archive.isEmpty {
                        Button { showArchive.toggle() } label: {
                            HStack(spacing: 6) {
                                Text("Weitere Chats").font(.system(size: 12.5, weight: .medium))
                                Image(systemName: showArchive ? "chevron.down" : "chevron.right").font(.system(size: 9.5, weight: .semibold))
                            }.foregroundStyle(Desk.dim).contentShape(Rectangle())
                        }.buttonStyle(.plain).padding(.horizontal, 10).padding(.top, 16).padding(.bottom, 6)
                        if showArchive || !search.isEmpty {
                            ForEach(archive.prefix(60)) { entry in
                                Button { selection = .archive(entry); showProcesses = false } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "bubble.left").frame(width: 16).foregroundStyle(Desk.dim)
                                        Text(entry.title).lineLimit(2).multilineTextAlignment(.leading)
                                        Spacer(minLength: 0)
                                    }.font(.system(size: 13)).padding(.horizontal, 10).frame(minHeight: 40)
                                        .background { if selection == .archive(entry) { RoundedRectangle(cornerRadius: 10).fill(Desk.selected) } }
                                        .contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }.padding(.horizontal, 10).padding(.bottom, 14)
            }
            HStack(spacing: 8) {
                Button(action: openSettings) {
                    Text(String(settings.value.owner.prefix(1)).uppercased()).font(.system(size: 14, weight: .semibold))
                        .frame(width: 38, height: 38).background(Color(white: 0.96).opacity(0.04), in: Circle()).contentShape(Circle())
                }.buttonStyle(.plain).help("Einstellungen").accessibilityLabel("Einstellungen")
                Button(action: openConnectors) {
                    HStack {
                        Text("Konnektoren").font(.system(size: 13.5, weight: .medium))
                        Spacer()
                        Image(systemName: "puzzlepiece.extension").font(.system(size: 12)).foregroundStyle(Desk.dim)
                    }.padding(.horizontal, 14).frame(height: 38)
                        .background(Desk.glass, in: Capsule()).overlay { Capsule().strokeBorder(Desk.glassStroke) }.contentShape(Capsule())
                }.buttonStyle(.plain).help("Dienste, die deine Agenten nutzen dürfen")
            }.padding(.leading, 12).padding(.trailing, 10).padding(.vertical, 12)
        }.frame(maxHeight: .infinity, alignment: .top).background(Desk.canvas)
    }

    private var teamPreview: String {
        if let typing = manager.teamTyping[project.path], !typing.isEmpty {
            return typing.joined(separator: ", ") + (typing.count == 1 ? " schreibt …" : " schreiben …")
        }
        guard let last = team.lines.last else { return "Agenten per @Name dazuholen" }
        return (last.kind == .agent ? last.from + ": " : "") + last.text.replacingOccurrences(of: "\n", with: " ")
    }

    private var projectMenu: some View {
        HStack(spacing: 4) {
            Menu {
                ForEach(settings.projects, id: \.path) { folder in
                    Button { chooseProject(folder) } label: {
                        if folder == project { Label(folder.lastPathComponent, systemImage: "checkmark") } else { Text(folder.lastPathComponent) }
                    }
                }
                Divider()
                Button("Projektordner hinzufügen …", action: addProject)
            } label: {
                HStack(spacing: 5) {
                    Text(project.lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                }.foregroundStyle(Desk.text.opacity(0.75)).contentShape(Rectangle())
            }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            Spacer()
            Menu {
                Button("Im Finder öffnen") { NSWorkspace.shared.open(project) }
                if settings.projects.count > 1 {
                    Button("Projekt aus Mochi Squad entfernen", role: .destructive) { removeProject(project) }
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 13)).foregroundStyle(Desk.dim).frame(width: 26, height: 22).contentShape(Rectangle())
            }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().accessibilityLabel("Projektaktionen")
        }
    }

    private func tool(_ icon: String, _ label: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 15)).foregroundStyle(active ? Desk.text : Color(white: 0.78))
                .frame(width: 30, height: 30)
                .background { if active { RoundedRectangle(cornerRadius: 8).fill(Desk.selected) } }
                .contentShape(Rectangle())
        }.buttonStyle(.plain).help(label).accessibilityLabel(label)
    }
}

/// Zeile der Seitenleiste: Avatar, Name, Job, Zeit und Vorschau.
@MainActor func row<Leading: View>(name: String, job: String?, time: Date?, preview: String, chosen: Bool, hoverID: Bool?,
                                   @ViewBuilder leading: () -> Leading) -> some View {
    HStack(spacing: 12) {
        leading().frame(width: 38, height: 38)
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                (Text(name).font(.system(size: 13, weight: .medium)).foregroundColor(Desk.text)
                 + Text(job.map { "  " + $0 } ?? "").font(.system(size: 12)).foregroundColor(Desk.faint))
                    .lineLimit(1).layoutPriority(1)
                Spacer(minLength: 4)
                if let time { Text(shortStamp(time)).font(.system(size: 12).monospacedDigit()).foregroundStyle(Desk.faint) }
            }
            Text(preview).font(.system(size: 13)).foregroundStyle(Desk.dim).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
        }
    }.padding(.horizontal, 10).padding(.vertical, 10)
        .background(chosen ? Desk.selected : (hoverID == true ? Desk.selected.opacity(0.6) : .clear),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
}

func shortStamp(_ date: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
    if calendar.isDateInYesterday(date) { return "Gestern" }
    if let days = calendar.dateComponents([.day], from: date, to: Date()).day, days < 7 { return date.formatted(.dateTime.weekday(.abbreviated)) }
    return date.formatted(.dateTime.day().month(.twoDigits))
}

/// Agentenzeile; beobachtet die laufende Sitzung, damit Status und Animation aktuell bleiben.
private struct AgentRow: View {
    let agent: Agent
    let session: AgentSession?
    let chosen: Bool
    let hovered: Bool

    var body: some View {
        if let session { Live(agent: agent, session: session, chosen: chosen, hovered: hovered) }
        else { content(working: false, running: false, waiting: false) }
    }

    private struct Live: View {
        let agent: Agent
        @ObservedObject var session: AgentSession
        let chosen: Bool
        let hovered: Bool
        var body: some View {
            AgentRow(agent: agent, session: nil, chosen: chosen, hovered: hovered)
                .content(working: session.working, running: session.isRunning, waiting: session.prompt != nil)
        }
    }

    fileprivate func content(working: Bool, running: Bool, waiting: Bool) -> some View {
        let preview: String = {
            if waiting { return "✋ braucht deine Antwort" }
            if working { return "schreibt …" }
            let text = agent.lastLine ?? agent.lastTask
            if text.isEmpty { return agent.isCoordinator ? "Behält den Überblick über dein Team" : "Noch kein Verlauf" }
            if let relay = RelayedMessage.parse(text) { return relay.sender + ": " + relay.body }
            return text.replacingOccurrences(of: "\n", with: " ")
        }()
        return row(name: agent.name, job: agent.jobTitle, time: agent.updated, preview: preview, chosen: chosen, hoverID: hovered) {
            BotAvatar(key: agent.avatar, size: 38, working: working)
                .overlay(alignment: .bottomTrailing) {
                    if running {
                        Circle().fill(Desk.working).frame(width: 9, height: 9)
                            .overlay { Circle().strokeBorder(Desk.canvas, lineWidth: 2) }.accessibilityLabel("Sitzung offen")
                    }
                }
        }
    }
}
