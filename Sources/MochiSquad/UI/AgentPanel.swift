import AppKit
import SwiftUI

/// Rechte Spalte: Computer des Agenten, seine Routinen und der Kontext der Sitzung.
struct AgentPanel: View {
    let agent: Agent
    @Binding var tab: PanelTab
    let openProcesses: () -> Void
    let openConnectors: () -> Void
    let close: () -> Void
    @EnvironmentObject private var manager: SessionManager

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(PanelTab.allCases) { item in
                    Button { tab = item } label: {
                        Text(item.rawValue).font(.system(size: 12.5, weight: tab == item ? .semibold : .regular))
                            .foregroundStyle(tab == item ? Desk.text : Desk.dim)
                            .padding(.horizontal, 11).frame(height: 28)
                            .background { if tab == item { Capsule().fill(Desk.selected) } }
                            .contentShape(Capsule())
                    }.buttonStyle(.plain)
                }
                Spacer(minLength: 4)
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .medium)).foregroundStyle(Desk.dim)
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }.buttonStyle(.plain).help("Spalte ausblenden")
            }.padding(.horizontal, 14).frame(height: 60)
            ScrollView {
                Group {
                    switch tab {
                    case .computer: ComputerView(agent: agent, session: manager.latestSession(for: agent.id), openProcesses: openProcesses)
                    case .routines: RoutinePanel(agent: agent)
                    case .context: ContextView(agent: agent, session: manager.latestSession(for: agent.id), openConnectors: openConnectors)
                    }
                }.padding(.horizontal, 16).padding(.bottom, 20)
            }
        }.frame(maxHeight: .infinity, alignment: .top).background(Desk.canvas)
    }
}

// MARK: Computer

/// Ein Bildschirmfenster, in dem man dem Agenten bei der Arbeit zusieht.
private struct ComputerView: View {
    let agent: Agent
    let session: AgentSession?
    let openProcesses: () -> Void

    var body: some View {
        if let session { Live(agent: agent, session: session, openProcesses: openProcesses).id(session.id) }
        else {
            VStack(alignment: .leading, spacing: 16) {
                Screen(title: "Computer von " + agent.name, status: ("schläft", Desk.dim)) {
                    VStack(spacing: 8) {
                        Image(systemName: "moon.zzz").font(.system(size: 24, weight: .light)).foregroundStyle(Desk.dim)
                        Text("Schläft").font(.system(size: 13, weight: .semibold))
                        Text("Wacht auf, sobald \(agent.name) einen Auftrag bekommt.").font(.system(size: 11.5)).foregroundStyle(Desk.dim)
                            .multilineTextAlignment(.center).padding(.horizontal, 20)
                    }
                }
                Facts(agent: agent, extra: nil)
            }
        }
    }

    private struct Live: View {
        let agent: Agent
        @ObservedObject var session: AgentSession
        let openProcesses: () -> Void
        @State private var events = [ActivityEvent]()

        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                Screen(title: "Computer von " + agent.name, status: status) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("~/" + session.project.lastPathComponent + " · " + session.provider.title)
                            .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Color.white.opacity(0.38)).lineLimit(1)
                        if events.isEmpty { Text("› " + session.task.replacingOccurrences(of: "\n", with: " ")).lineLimit(3) }
                        ForEach(events.suffix(7)) { Text("› " + $0.text.replacingOccurrences(of: "\n", with: " ")).lineLimit(2) }
                        Spacer(minLength: 0)
                    }.font(.system(size: 11, design: .monospaced)).foregroundStyle(Color(white: 0.86))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(12)
                }
                HStack(spacing: 8) {
                    Button { NSWorkspace.shared.open(session.project) } label: { Label("Im Finder", systemImage: "folder") }.buttonStyle(.pill)
                    Button(action: openProcesses) { Label("Prozesse", systemImage: "list.bullet.rectangle") }.buttonStyle(.pill)
                }
                TimelineView(.periodic(from: session.started, by: 1)) { moment in
                    Facts(agent: agent, extra: session.isRunning ? ("Läuft seit", clock(moment.date.timeIntervalSince(session.started))) : ("Status", session.status))
                }
                if !files.isEmpty {
                    Text("Zuletzt bearbeitet").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Desk.dim)
                    ForEach(files, id: \.path) { url in
                        Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "doc.text").font(.system(size: 13)).foregroundStyle(Desk.dim)
                                    .frame(width: 28, height: 28).background(Desk.selected, in: RoundedRectangle(cornerRadius: 7))
                                Text(url.lastPathComponent).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 0)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain).help("Im Finder zeigen")
                    }
                }
            }
            .task(id: session.usage.historyPath) {
                guard let path = session.usage.historyPath else { return }
                var lastSize = -1
                while !Task.isCancelled {
                    let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? -1
                    if size != lastSize, let next = try? await PythonTool.run("history", ["activity", path, session.provider.rawValue], as: [ActivityEvent].self) {
                        lastSize = size
                        events = next
                        files = recentFiles(next)
                    }
                    try? await Task.sleep(for: .seconds(3))
                }
            }
        }

        @State private var files = [URL]()

        private var status: (String, Color) {
            if !session.isRunning { return (session.status.lowercased(), Desk.dim) }
            if session.prompt != nil { return ("wartet auf dich", Desk.warning) }
            return session.working ? ("arbeitet", Desk.success) : ("bereit", Desk.dim)
        }

        private func recentFiles(_ events: [ActivityEvent]) -> [URL] {
            var seen = Set<String>(), result = [URL]()
            for event in events.reversed() {
                guard let file = event.file else { continue }
                let url = URL(fileURLWithPath: file, relativeTo: session.project).standardizedFileURL
                guard url.path.hasPrefix(session.project.path + "/"), FileManager.default.fileExists(atPath: url.path),
                      seen.insert(url.path).inserted else { continue }
                result.append(url)
                if result.count == 4 { break }
            }
            return result
        }
    }

    private struct Screen<Content: View>: View {
        let title: String
        let status: (String, Color)
        @ViewBuilder let content: () -> Content
        var body: some View {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { _ in Circle().fill(Color.white.opacity(0.16)).frame(width: 8, height: 8) }
                    Text(title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Desk.dim).lineLimit(1).padding(.leading, 6)
                    Spacer(minLength: 4)
                    Circle().fill(status.1).frame(width: 6, height: 6)
                    Text(status.0).font(.system(size: 11, weight: .medium)).foregroundStyle(status.1)
                }.padding(.horizontal, 11).frame(height: 30).background(Desk.dialog)
                ZStack { Color.black; content() }.aspectRatio(16 / 10, contentMode: .fit).clipped()
            }.clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Desk.edge) }
        }
    }

    private struct Facts: View {
        let agent: Agent
        let extra: (String, String)?
        var body: some View {
            VStack(alignment: .leading, spacing: 9) {
                line("Arbeitsordner", URL(fileURLWithPath: agent.project).lastPathComponent)
                line("Anbieter", agent.provider.title)
                line("Modell", agent.model.isEmpty ? "Standard" : agent.model)
                line("Dateien ändern", agent.canEdit ? "im Projekt erlaubt" : "nur lesen")
                if let extra { line(extra.0, extra.1) }
            }.padding(14).background(Desk.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        private func line(_ name: String, _ value: String) -> some View {
            HStack {
                Text(name).foregroundStyle(Desk.dim)
                Spacer(minLength: 6)
                Text(value).lineLimit(1).truncationMode(.middle)
            }.font(.system(size: 12.5))
        }
    }
}

func clock(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds))
    return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
        : String(format: "%02d:%02d", total / 60, total % 60)
}

// MARK: Kontext

private struct ContextView: View {
    let agent: Agent
    let session: AgentSession?
    let openConnectors: () -> Void
    @EnvironmentObject private var transcript: TranscriptStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Kontext von " + agent.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Desk.dim)
            if let session { Live(session: session, fallback: transcript.usage) } else { UsageNumbers(usage: transcript.usage) }
            Button(action: openConnectors) { Label("Konnektoren verwalten", systemImage: "puzzlepiece.extension") }.buttonStyle(.pill).padding(.top, 6)
            Text("Konnektoren sind Dienste (MCP-Server), die deine Agenten nutzen dürfen. Sie werden im jeweiligen Client eingerichtet.")
                .font(.system(size: 12)).foregroundStyle(Desk.dim).fixedSize(horizontal: false, vertical: true)
        }
    }

    private struct Live: View {
        @ObservedObject var session: AgentSession
        let fallback: Usage
        var body: some View { UsageNumbers(usage: session.usage.used != nil ? session.usage : fallback) }
    }
}

private struct UsageNumbers: View {
    let usage: Usage
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let percent = usage.percent ?? usage.used.flatMap({ used in usage.limit.map { 100 * Double(used) / Double(max(1, $0)) } }) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(percent.formatted(.number.precision(.fractionLength(0))) + " %").font(.system(size: 26, weight: .semibold).monospacedDigit())
                    Text("genutzt").font(.system(size: 15)).foregroundStyle(Desk.dim)
                }
                GeometryReader { bar in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.08))
                        Capsule().fill(Desk.accent).frame(width: bar.size.width * min(1, max(0, percent / 100)))
                    }
                }.frame(height: 4)
            }
            if let model = usage.model { line("Modell", model) }
            if let used = usage.used { line(usage.limit == nil ? "Letzte Anfrage" : "Token belegt", used.formatted()) }
            if let limit = usage.limit { line("Kontextfenster", limit.formatted()) }
            if let five = usage.five { line("5-Stunden-Limit", five.formatted(.number.precision(.fractionLength(0))) + " %") }
            if let week = usage.week { line("Wochenlimit", week.formatted(.number.precision(.fractionLength(0))) + " %") }
            if usage.used == nil && usage.model == nil {
                Text("Die Auslastung erscheint mit der ersten Antwort des Agenten.").font(.system(size: 12.5)).foregroundStyle(Desk.dim)
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Desk.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
    private func line(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name).foregroundStyle(Desk.dim)
            Spacer(minLength: 6)
            Text(value).font(.system(size: 12, design: .monospaced)).lineLimit(1)
        }.font(.system(size: 12.5))
    }
}

// MARK: Routinen

/// Routinen eines Agenten: Auftrag, Zeitpunkt, Testlauf und Ablaufprotokoll.
private struct RoutinePanel: View {
    let agent: Agent
    @EnvironmentObject private var store: RoutineStore
    @State private var draft: Routine?
    @State private var confirmDelete = false
    private let days = [(1, "Mo"), (2, "Di"), (3, "Mi"), (4, "Do"), (5, "Fr"), (6, "Sa"), (7, "So")]

    private var saved: [Routine] { store.routines(for: agent.id) }
    private var isNew: Bool { draft.map { d in !saved.contains { $0.id == d.id } } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if saved.count > 1 {
                VStack(spacing: 2) {
                    ForEach(saved) { routine in
                        Button { draft = routine } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "clock").font(.system(size: 12)).foregroundStyle(Desk.dim)
                                Text(routine.rhythm + " um " + routine.time).font(.system(size: 13, weight: .medium))
                                Spacer()
                                Circle().fill(routine.active ? Desk.success : Desk.faint).frame(width: 6, height: 6)
                            }.padding(.horizontal, 10).frame(height: 36)
                                .background(shown?.id == routine.id ? Desk.selected : .clear, in: RoundedRectangle(cornerRadius: 10))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
            if let shown { form(shown) } else {
                Text("Keine Routine").font(.system(size: 15, weight: .semibold))
                Text("\(agent.name) arbeitet bisher nur auf Zuruf. Eine Routine läuft zur festen Zeit über macOS, auch wenn Mochi Squad geschlossen ist.")
                    .font(.system(size: 12.5)).foregroundStyle(Desk.dim).fixedSize(horizontal: false, vertical: true)
            }
            if !isNew {
                Button { draft = Routine(agent: agent) } label: {
                    Label("Neue Routine", systemImage: "plus").font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity).frame(height: 40)
                        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Desk.edge) }
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
        .onChange(of: agent.id) { _, _ in draft = nil }
    }

    /// Die bearbeitete Routine: der Entwurf, sonst die erste gespeicherte.
    private var shown: Routine? { draft ?? saved.first }

    @ViewBuilder private func form(_ routine: Routine) -> some View {
        let stored = saved.first { $0.id == routine.id }
        let changed = stored != routine
        let ready = !routine.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { routine.active }, set: { on in
                var copy = routine; copy.active = on
                draft = copy
                if stored != nil, ready { store.save(copy) }
            })).labelsHidden().toggleStyle(.switch).controlSize(.small)
            Text(routine.active ? "Aktiv" : "Pausiert").font(.system(size: 13))
            Spacer()
            if let stored {
                Button("Löschen") { confirmDelete = true }.buttonStyle(.pill)
                    .confirmationDialog("Routine löschen?", isPresented: $confirmDelete) {
                        Button("Routine löschen", role: .destructive) { store.remove(stored); draft = nil }
                        Button("Abbrechen", role: .cancel) {}
                    }
                Button("Testlauf") { store.runNow(stored) }.buttonStyle(.pill).help("Jetzt einmal ausführen")
            }
        }
        label("Auftrag")
        TextEditor(text: Binding(get: { routine.task }, set: { var c = routine; c.task = $0; draft = c }))
            .font(.system(size: 13.5)).scrollContentBackground(.hidden).padding(.horizontal, 7).padding(.vertical, 8)
            .frame(minHeight: 96, maxHeight: 160).field()
            .overlay(alignment: .topLeading) {
                if routine.task.isEmpty {
                    Text("Was soll \(agent.name) jedes Mal tun?").font(.system(size: 13.5)).foregroundStyle(.tertiary)
                        .padding(.horizontal, 12).padding(.vertical, 8).allowsHitTesting(false)
                }
            }
        label("Wann")
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "clock").foregroundStyle(Desk.dim)
                Text(routine.rhythm.prefix(1).uppercased() + routine.rhythm.dropFirst()).font(.system(size: 13.5, weight: .medium))
                Spacer()
                Picker("", selection: Binding(get: { routine.hour }, set: { var c = routine; c.hour = $0; draft = c })) {
                    ForEach(0..<24, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                }.labelsHidden().fixedSize()
                Picker("", selection: Binding(get: { routine.minute }, set: { var c = routine; c.minute = $0; draft = c })) {
                    ForEach(Array(stride(from: 0, to: 60, by: 5)), id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                }.labelsHidden().fixedSize()
            }
            HStack(spacing: 4) {
                ForEach(days, id: \.0) { day in
                    let on = routine.days.isEmpty || routine.days.contains(day.0)
                    Button {
                        var set = Set(routine.days.isEmpty ? Array(1...7) : routine.days)
                        if on { set.remove(day.0) } else { set.insert(day.0) }
                        guard !set.isEmpty else { return }
                        var c = routine; c.days = set.count == 7 ? [] : set.sorted(); draft = c
                    } label: {
                        Text(day.1).font(.system(size: 11.5, weight: on ? .semibold : .regular)).foregroundStyle(on ? Desk.onPrimary : Desk.dim)
                            .frame(maxWidth: .infinity).frame(height: 26).background(on ? Desk.primary : Desk.selected, in: Capsule())
                            .contentShape(Capsule())
                    }.buttonStyle(.plain)
                }
            }
        }.padding(12).overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Desk.edge) }
        Toggle(isOn: Binding(get: { routine.allowWeb }, set: { var c = routine; c.allowWeb = $0; draft = c })) {
            Text("Darf im Internet suchen und Seiten lesen").font(.system(size: 12.5))
        }.toggleStyle(.checkbox)
        HStack {
            Button(stored == nil ? "Routine anlegen" : "Speichern") {
                var copy = routine
                copy.task = copy.task.trimmingCharacters(in: .whitespacesAndNewlines)
                if stored == nil { copy.active = true }
                store.save(copy); draft = copy
            }.buttonStyle(.primaryPill).disabled(!changed || !ready).opacity(changed && ready ? 1 : 0.45)
            if stored == nil { Button("Verwerfen") { draft = nil }.buttonStyle(.pill) }
        }
        if let stored {
            let runs = Array(store.runs(for: stored.id).reversed().prefix(10))
            Text("Ablaufprotokoll").font(.system(size: 15, weight: .semibold)).padding(.top, 10)
            if runs.isEmpty { Text("Noch kein Lauf. „Testlauf“ startet die Routine sofort.").font(.system(size: 12.5)).foregroundStyle(Desk.dim) }
            ForEach(runs) { run in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(Timestamp.date(run.start).map { $0.formatted(.dateTime.day().month(.abbreviated).hour().minute()) } ?? run.start)
                            .font(.system(size: 13).monospacedDigit())
                        Spacer()
                        Text(run.code == 0 ? "fertig" : "Fehler \(run.code ?? -1)").font(.system(size: 12))
                            .foregroundStyle(run.code == 0 ? Desk.dim : Desk.danger)
                    }
                    if let output = run.output, !output.isEmpty {
                        Text(output.trimmingCharacters(in: .whitespacesAndNewlines)).font(.system(size: 12)).foregroundStyle(Desk.dim).lineLimit(3)
                    }
                }.padding(.vertical, 6)
                Rectangle().fill(Desk.rule).frame(height: 1)
            }
        }
    }

    private func label(_ text: String) -> some View { Text(text).font(.system(size: 12.5)).foregroundStyle(Desk.dim) }
}
