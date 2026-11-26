import SwiftUI

/// Alle laufenden Sitzungen auf einen Blick, über alle Projekte.
struct ProcessesView: View {
    let project: URL
    let open: (AgentSession) -> Void
    @EnvironmentObject private var agents: AgentStore
    @EnvironmentObject private var manager: SessionManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Prozesse").font(.system(size: 22, weight: .semibold)).padding(.top, 40).padding(.bottom, 6)
                if manager.sessions.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "moon.zzz").font(.system(size: 34, weight: .light)).foregroundStyle(Desk.dim)
                        Text("Gerade läuft nichts").font(.system(size: 17, weight: .semibold))
                        Text("Sobald ein Agent einen Auftrag bearbeitet, erscheint er hier.").font(.system(size: 13.5)).foregroundStyle(Desk.dim)
                    }.frame(maxWidth: .infinity).padding(.vertical, 70)
                }
                ForEach(manager.sessions.reversed()) { session in
                    if let agent = agents.agent(session.agentID) {
                        Row(agent: agent, session: session, sameProject: session.project == project, open: { open(session) }, stop: { manager.close(session) })
                    }
                }
            }.frame(maxWidth: 860, alignment: .leading).padding(.horizontal, 24).padding(.bottom, 28).frame(maxWidth: .infinity)
        }.background(Desk.canvas)
    }

    private struct Row: View {
        let agent: Agent
        @ObservedObject var session: AgentSession
        let sameProject: Bool
        let open: () -> Void
        let stop: () -> Void

        var body: some View {
            HStack(spacing: 14) {
                MochiAvatar(key: agent.avatar, size: 40, working: session.working)
                VStack(alignment: .leading, spacing: 3) {
                    Text(agent.name + " · " + agent.jobTitle + (sameProject ? "" : " · " + session.project.lastPathComponent))
                        .font(.system(size: 15, weight: .medium)).lineLimit(1)
                    Text(session.task.replacingOccurrences(of: "\n", with: " ")).font(.system(size: 13)).foregroundStyle(Desk.dim).lineLimit(1)
                }
                Spacer(minLength: 10)
                TimelineView(.periodic(from: session.started, by: 1)) { moment in
                    Text(session.isRunning ? clock(moment.date.timeIntervalSince(session.started)) : session.status)
                        .font(.system(size: 14).monospacedDigit()).foregroundStyle(session.prompt != nil ? Desk.warning : Desk.dim)
                }
                if sameProject { Button("Öffnen", action: open).buttonStyle(.pill) }
                Button(action: stop) { Image(systemName: "xmark") }.buttonStyle(.pill).help(session.isRunning ? "Sitzung beenden" : "Schließen")
            }.padding(.horizontal, 16).frame(height: 66).background(Desk.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

/// Konnektoren (MCP-Server) der Clients ansehen, anmelden und hinzufügen.
struct ConnectorsView: View {
    let project: URL
    @Environment(\.dismiss) private var dismiss
    @State private var provider = Provider.claude
    @State private var rows = [Row]()
    @State private var name = ""
    @State private var address = ""
    @State private var notice = ""
    @State private var busy = false

    struct Row: Decodable {
        let name, state: String
        var label: String { ["ok": "verbunden", "login": "Anmeldung nötig", "off": "abgeschaltet"][state] ?? "nicht erreichbar" }
        var color: SwiftUI.Color { state == "ok" ? Desk.success : state == "off" ? Desk.faint : Desk.warning }
    }
    private struct Result: Decodable { let rows: [Row]?; let message, error: String? }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Konnektoren").font(.system(size: 22, weight: .semibold))
                Spacer()
                Button("Fertig") { dismiss() }.buttonStyle(.primaryPill).keyboardShortcut(.cancelAction)
            }
            Text("Dienste (MCP-Server), die im jeweiligen Programm eingerichtet sind; sie gelten auch außerhalb von Mochi Squad. Claude-Agenten können sie nutzen und fragen vorher nach. Codex-Agenten bekommen sie nur mit Vollzugriff, der Koordinator arbeitet mit seinen eigenen Werkzeugen.")
                .font(.system(size: 12.5)).foregroundStyle(Desk.dim).fixedSize(horizontal: false, vertical: true)
            PillPicker(selection: $provider, options: Provider.allCases.map { ($0, $0.title) }).disabled(busy)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(rows, id: \.name) { row in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.name).font(.system(size: 13.5, weight: .medium))
                                HStack(spacing: 5) {
                                    Circle().fill(row.color).frame(width: 6, height: 6)
                                    Text(row.label).font(.system(size: 12)).foregroundStyle(Desk.dim)
                                }
                            }
                            Spacer()
                            if row.state == "login" { Button("Anmelden") { Task { await perform("login", [row.name]) } }.buttonStyle(.pill).disabled(busy) }
                        }.padding(.horizontal, 12).frame(height: 48).background(Desk.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    if rows.isEmpty {
                        if busy { ProgressView().controlSize(.small).padding(.top, 40) }
                        else { Text("Noch keine Konnektoren eingerichtet.").font(.system(size: 12.5)).foregroundStyle(Desk.dim).padding(.vertical, 12) }
                    }
                }.frame(maxWidth: .infinity)
            }.frame(height: 264)
            Text("Server hinzufügen").font(.system(size: 13, weight: .semibold)).foregroundStyle(Desk.dim)
            HStack(spacing: 8) {
                TextField("Name", text: $name).textFieldStyle(.plain).padding(.horizontal, 12).frame(width: 130, height: 32).field(8)
                TextField("https://…", text: $address).textFieldStyle(.plain).padding(.horizontal, 12).frame(height: 32).field(8)
                Button("Hinzufügen") { Task { await perform("add", [name, address]) } }.buttonStyle(.pill).disabled(name.isEmpty || address.isEmpty || busy)
            }
            if !notice.isEmpty { Text(notice).font(.system(size: 12.5)).foregroundStyle(Desk.dim) }
        }
        .font(.system(size: 13.5)).padding(22).frame(width: 520)
        .task(id: provider) { rows = []; await perform("list", []) }
    }

    private func perform(_ action: String, _ args: [String]) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let base = [provider.rawValue, project.path]
        guard let result = try? await PythonTool.run("connectors", [action] + base + args, as: Result.self) else {
            notice = "Die Konnektoren konnten nicht geladen werden."
            return
        }
        notice = result.error ?? result.message ?? ""
        if let list = result.rows { rows = list }
        if action != "list", result.error == nil {
            if action == "add" { name = ""; address = "" }
            rows = (try? await PythonTool.run("connectors", ["list"] + base, as: Result.self))?.rows ?? rows
        }
    }
}
