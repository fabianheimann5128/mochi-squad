import SwiftUI

/// Narrow bar on the far left with round buttons. Top: new agent, processes, connectors, skills.
/// Bottom: what's new, suggest a feature, report a bug, and the user's initial for the settings.
/// While the chat list is hidden, the middle shows the agents so every chat stays one click away.
struct IconRail: View {
    static let width: CGFloat = 76

    let project: URL
    @Binding var selection: Selection?
    @Binding var showProcesses: Bool
    let showsAgents: Bool
    let newAgent: () -> Void
    let openSettings: () -> Void
    let openConnectors: () -> Void
    let openSkills: () -> Void

    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var agents: AgentStore
    @EnvironmentObject private var manager: SessionManager
    @State private var showNews = false

    private var members: [Agent] { agents.agents(in: project) }

    var body: some View {
        VStack(spacing: 10) {
            RailButton(label: t("New agent", "Neuer Agent"), action: newAgent) { Image(systemName: "plus") }
                .keyboardShortcut("n")
            RailButton(label: t("Processes", "Prozesse"), active: showProcesses, action: { showProcesses = true }) {
                Image(systemName: "waveform.path.ecg")
            }
            .overlay(alignment: .topTrailing) {
                if manager.runningCount > 0 {
                    Text("\(manager.runningCount)").font(.system(size: 10, weight: .bold).monospacedDigit()).foregroundStyle(.white)
                        .padding(.horizontal, 4).frame(minWidth: 16, minHeight: 16).background(Desk.accent, in: Capsule())
                        .offset(x: 3, y: -3).allowsHitTesting(false)
                }
            }
            RailButton(label: t("Connectors: services your agents may use", "Konnektoren: Dienste, die deine Agenten nutzen dürfen"), action: openConnectors) {
                Image(systemName: "puzzlepiece.extension")
            }
            RailButton(label: t("Skills: what your agents know how to do", "Skills: was deine Agenten können"), action: openSkills) {
                Image(systemName: "wand.and.stars")
            }
            if showsAgents {
                Rectangle().fill(Desk.rule).frame(width: 28, height: 1).padding(.vertical, 2)
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 8) {
                        if members.count > 1 {
                            Button { selection = .team; showProcesses = false } label: {
                                GroupAvatar(keys: members.prefix(3).map(\.avatar), size: 40, round: true).avatarRing(selection == .team && !showProcesses)
                            }.buttonStyle(.plain).help("Team").accessibilityLabel("Team")
                        }
                        ForEach(members) { agent in
                            Button { selection = .agent(agent.id); showProcesses = false } label: {
                                MochiAvatar(key: agent.avatar, size: 40, round: true).avatarRing(selection == .agent(agent.id) && !showProcesses)
                            }.buttonStyle(.plain).help(agent.name + " · " + agent.jobTitle).accessibilityLabel(agent.name)
                        }
                    }.padding(.vertical, 2)
                }
            } else {
                Spacer(minLength: 0)
            }
            RailButton(label: t("What's new?", "Was ist neu?"), action: { showNews = true }) { RocketGlyph().frame(width: 17, height: 17) }
            RailButton(label: t("Suggest a feature", "Funktion vorschlagen"), action: { NSWorkspace.shared.open(Feedback.url(.idea)) }) {
                Image(systemName: "lightbulb")
            }
            RailButton(label: t("Report a bug", "Fehler melden"), action: { NSWorkspace.shared.open(Feedback.url(.bug)) }) {
                Image(systemName: "ladybug")
            }
            RailButton(label: t("Settings", "Einstellungen"), action: openSettings) {
                Text(String(settings.value.owner.prefix(1)).uppercased()).font(.system(size: 14, weight: .semibold)).foregroundStyle(Desk.text)
            }
        }
        // The window's close, minimise and zoom buttons sit above the first button.
        .padding(.top, 52).padding(.bottom, 14)
        .frame(width: Self.width).frame(maxHeight: .infinity).background(Desk.canvas)
        .sheet(isPresented: $showNews) { WhatsNew().dialogStyle() }
    }
}

/// Round button of the icon rail.
private struct RailButton<Glyph: View>: View {
    let label: String
    var active = false
    let action: () -> Void
    @ViewBuilder let glyph: () -> Glyph
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            glyph().font(.system(size: 15, weight: .medium)).foregroundStyle(active ? Desk.text : Desk.dim)
                .frame(width: 40, height: 40)
                .background(Color(white: 0.96).opacity(active ? 0.14 : hovered ? 0.09 : 0.05), in: Circle())
                .overlay { Circle().strokeBorder(Color(white: 0.96).opacity(active ? 0.18 : 0.06)) }
                .contentShape(Circle())
        }
        .buttonStyle(.plain).help(label).accessibilityLabel(label).onHover { hovered = $0 }
    }
}

private extension View {
    /// Ring around the avatar of the open chat.
    func avatarRing(_ chosen: Bool) -> some View {
        padding(3).overlay { Circle().strokeBorder(chosen ? Desk.accent : .clear, lineWidth: 2) }
    }
}

/// A small rocket for "What's new?" (the system symbols have none).
struct RocketGlyph: View {
    var body: some View {
        Canvas { context, size in
            let s = min(size.width, size.height) / 24
            context.translateBy(x: size.width / 2, y: size.height / 2)
            context.rotate(by: .degrees(45))
            context.scaleBy(x: s, y: s)
            var body = Path()
            body.move(to: CGPoint(x: 0, y: -11))
            body.addCurve(to: CGPoint(x: 4.2, y: 4), control1: CGPoint(x: 4.6, y: -6.5), control2: CGPoint(x: 4.6, y: -0.5))
            body.addLine(to: CGPoint(x: -4.2, y: 4))
            body.addCurve(to: CGPoint(x: 0, y: -11), control1: CGPoint(x: -4.6, y: -0.5), control2: CGPoint(x: -4.6, y: -6.5))
            var fins = Path()
            fins.move(to: CGPoint(x: -4.2, y: -0.5)); fins.addLine(to: CGPoint(x: -8, y: 6)); fins.addLine(to: CGPoint(x: -4.2, y: 4.4))
            fins.move(to: CGPoint(x: 4.2, y: -0.5)); fins.addLine(to: CGPoint(x: 8, y: 6)); fins.addLine(to: CGPoint(x: 4.2, y: 4.4))
            var flame = Path()
            flame.move(to: CGPoint(x: -2, y: 6.5)); flame.addQuadCurve(to: CGPoint(x: 2, y: 6.5), control: CGPoint(x: 0, y: 13))
            let line = StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round)
            context.stroke(body, with: .foreground, style: line)
            context.stroke(fins, with: .foreground, style: line)
            context.stroke(flame, with: .foreground, style: line)
            context.stroke(Path(ellipseIn: CGRect(x: -1.6, y: -5.2, width: 3.2, height: 3.2)), with: .foreground, lineWidth: 1.5)
        }.accessibilityHidden(true)
    }
}

/// Chat list: project, team chat, agents, earlier chats.
struct Sidebar: View {
    let project: URL
    @Binding var selection: Selection?
    @Binding var showProcesses: Bool
    let chooseProject: (URL) -> Void
    let addProject: () -> Void
    let removeProject: (URL) -> Void
    let newAgent: () -> Void
    let hide: () -> Void

    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var agents: AgentStore
    @EnvironmentObject private var team: TeamLog
    @EnvironmentObject private var chats: ChatIndex
    @EnvironmentObject private var manager: SessionManager
    @State private var search = ""
    @State private var searching = false
    @State private var showArchive = false
    @State private var hovered: UUID?
    @State private var confirmRemoval = false

    private var members: [Agent] { agents.agents(in: project) }
    private var crew: [Agent] { members.filter { !$0.isCoordinator } }
    private func matches(_ text: String) -> Bool { search.isEmpty || text.localizedCaseInsensitiveContains(search) }
    /// Chats that belong to no agent (for example held directly in the terminal).
    private var archive: [ChatEntry] {
        let known = Set(members.flatMap(\.journals))
        return chats.entries.filter { !known.contains($0.path) && matches($0.title) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
                projectMenu
                Spacer(minLength: 6)
                tool("magnifyingglass", t("Search", "Suchen"), active: searching) { searching.toggle(); if !searching { search = "" } }
                tool("sidebar.left", t("Hide chat list", "Chatliste ausblenden"), action: hide)
            }.padding(.leading, 16).padding(.trailing, 10).frame(height: 52)
            if searching {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12.5)).foregroundStyle(Desk.dim)
                    TextField(t("Search", "Suchen"), text: $search).textFieldStyle(.plain).font(.system(size: 13.5))
                }.padding(.horizontal, 11).frame(height: 34).field().padding(.horizontal, 12).padding(.bottom, 8)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if !crew.isEmpty, matches("Team") {
                        Button { selection = .team; showProcesses = false } label: {
                            row(name: "Team", job: nil, time: team.lines.last?.date, preview: teamPreview,
                                chosen: selection == .team && !showProcesses, hoverID: nil) {
                                GroupAvatar(keys: members.prefix(3).map(\.avatar), size: 38)
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
                            Label(t("Create agent", "Agent anlegen"), systemImage: "plus").font(.system(size: 13, weight: .medium))
                                .frame(maxWidth: .infinity).frame(height: 40)
                                .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Desk.edge) }
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).padding(.top, 8)
                        Text(t("Your coordinator is ready. Create agents for the work you want to hand off.",
                               "Dein Koordinator ist startklar. Lege Agenten für die Aufgaben an, die du abgeben willst."))
                            .font(.system(size: 12.5)).foregroundStyle(Desk.dim).padding(.horizontal, 4).padding(.top, 8)
                    }
                    if !archive.isEmpty {
                        Button { showArchive.toggle() } label: {
                            HStack(spacing: 6) {
                                Text(t("More chats", "Weitere Chats")).font(.system(size: 12.5, weight: .medium))
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
        }.frame(maxHeight: .infinity, alignment: .top).background(Desk.canvas)
    }

    private var teamPreview: String {
        if let typing = manager.teamTyping[project.path], !typing.isEmpty { return typingText(typing) }
        guard let last = team.lines.last else { return t("Bring in agents with @name", "Agenten per @Name dazuholen") }
        return (last.kind == .agent ? last.from + ": " : "") + last.text.replacingOccurrences(of: "\n", with: " ")
    }

    /// Project name with the list of projects, and the actions for the open project behind the same menu.
    private var projectMenu: some View {
        Menu {
            ForEach(settings.projects, id: \.path) { folder in
                Button { chooseProject(folder) } label: {
                    if folder == project { Label(folder.lastPathComponent, systemImage: "checkmark") } else { Text(folder.lastPathComponent) }
                }
            }
            Divider()
            Button(t("Add project folder …", "Projektordner hinzufügen …"), action: addProject)
            Button(t("Show in Finder", "Im Finder öffnen")) { NSWorkspace.shared.open(project) }
            if settings.projects.count > 1 {
                Button(t("Remove project from Mochi Squad …", "Projekt aus Mochi Squad entfernen …"), role: .destructive) { confirmRemoval = true }
            }
        } label: {
            HStack(spacing: 5) {
                Text(project.lastPathComponent).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Desk.dim)
            }.foregroundStyle(Desk.text).contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().accessibilityLabel(t("Project", "Projekt"))
        .confirmationDialog(t("Remove “\(project.lastPathComponent)” from Mochi Squad?", "„\(project.lastPathComponent)“ aus Mochi Squad entfernen?"),
                            isPresented: $confirmRemoval) {
            Button(t("Remove project", "Projekt entfernen"), role: .destructive) { removeProject(project) }
            Button(t("Cancel", "Abbrechen"), role: .cancel) {}
        } message: {
            Text(t("The agents of this project and their routines are removed. The folder and the chat histories stay.",
                   "Die Agenten dieses Projekts und ihre Routinen werden entfernt. Der Ordner und die Verläufe bleiben erhalten."))
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

/// "Mira is typing …" for one or several names.
func typingText(_ names: [String]) -> String {
    names.joined(separator: ", ") + (names.count == 1 ? t(" is typing …", " schreibt …") : t(" are typing …", " schreiben …"))
}

/// Row of the chat list: avatar, name, job, time and preview.
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
    let calendar = Calendar.current, locale = L10n.language.locale
    if calendar.isDateInToday(date) { return date.formatted(.dateTime.hour().minute().locale(locale)) }
    if calendar.isDateInYesterday(date) { return t("Yesterday", "Gestern") }
    if let days = calendar.dateComponents([.day], from: date, to: Date()).day, days < 7 { return date.formatted(.dateTime.weekday(.abbreviated).locale(locale)) }
    return date.formatted(.dateTime.day().month(.twoDigits).locale(locale))
}

/// Agent row; observes the running session so that status and animation stay current.
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
            if waiting { return t("✋ needs your answer", "✋ braucht deine Antwort") }
            if working { return t("typing …", "schreibt …") }
            // Attached files appear in the preview as a short note, not as a list of paths.
            let parts = Attachments.split(agent.lastLine ?? agent.lastTask)
            let count = parts.files.count
            let files = count == 1 ? t("attachment", "Anhang") : t("\(count) attachments", "\(count) Anhänge")
            let text = parts.files.isEmpty ? parts.text : (parts.text.isEmpty ? "" : parts.text + " ") + "📎 " + files
            if text.isEmpty {
                return agent.isCoordinator ? t("Keeps an eye on your whole team", "Behält den Überblick über dein Team") : t("No messages yet", "Noch kein Verlauf")
            }
            if let relay = RelayedMessage.parse(text) { return relay.sender + ": " + relay.body }
            return text.replacingOccurrences(of: "\n", with: " ")
        }()
        return row(name: agent.name, job: agent.jobTitle, time: agent.updated, preview: preview, chosen: chosen, hoverID: hovered) {
            MochiAvatar(key: agent.avatar, size: 38, working: working)
                .overlay(alignment: .bottomTrailing) {
                    if running {
                        Circle().fill(Desk.working).frame(width: 9, height: 9)
                            .overlay { Circle().strokeBorder(Desk.canvas, lineWidth: 2) }.accessibilityLabel(t("Session open", "Sitzung offen"))
                    }
                }
        }
    }
}
