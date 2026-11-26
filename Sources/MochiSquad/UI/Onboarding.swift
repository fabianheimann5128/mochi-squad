import AppKit
import SwiftTerm
import SwiftUI

/// Zustand der Agent-Programme (aus launcher.py status).
struct ClientStatus: Decodable {
    struct Entry: Decodable { let installed, loggedIn: Bool; let path, detail: String }
    let claude: Entry
    let codex: Entry
    /// Anmeldestand weiterer ChatGPT-Abos, nach Kennung.
    let accounts: [String: Bool]?
    func entry(_ provider: Provider) -> Entry { provider == .claude ? claude : codex }
    var allReady: Bool { claude.loggedIn && codex.loggedIn }
    static func load() async -> ClientStatus? { try? await PythonTool.run("launcher", ["status"], as: ClientStatus.self) }
}

/// Zeile für ein Agent-Programm: Status, Anmeldung mit dem eigenen Abo oder Installationsanleitung.
struct ClientRow: View {
    let provider: Provider
    let entry: ClientStatus.Entry?
    let login: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry?.loggedIn == true ? "checkmark.circle.fill" : entry?.installed == true ? "person.crop.circle.badge.exclamationmark" : "circle.dashed")
                .font(.system(size: 18)).foregroundStyle(entry?.loggedIn == true ? Desk.success : Desk.faint)
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.title).font(.system(size: 14, weight: .medium))
                Text(text).font(.system(size: 12.5)).foregroundStyle(Desk.dim)
            }
            Spacer()
            if let entry {
                if !entry.installed {
                    Button("Anleitung") {
                        NSWorkspace.shared.open(URL(string: provider == .claude ? "https://docs.claude.com/claude-code" : "https://developers.openai.com/codex/cli")!)
                    }.buttonStyle(.pill)
                } else if !entry.loggedIn {
                    Button("Anmelden", action: login).buttonStyle(.primaryPill)
                }
            }
        }.padding(.horizontal, 14).frame(height: 54).field(12)
    }

    private var text: String {
        guard let entry else { return "wird geprüft …" }
        if !entry.installed { return "nicht installiert" }
        return entry.loggedIn ? "angemeldet" : "installiert · mit deinem \(provider == .claude ? "Claude" : "ChatGPT")-Abo anmelden"
    }
}

/// Anmeldung im echten Client: Der Browser öffnet sich, danach schließt sich das Fenster von selbst.
struct LoginSheet: View {
    let provider: Provider
    /// Weiteres ChatGPT-Abo, das angemeldet wird; leer für die normale Anmeldung.
    var account = ""
    let done: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Bei \(provider.title) anmelden").font(.system(size: 17, weight: .semibold))
                Spacer()
                Button("Schließen") { dismiss(); done() }.buttonStyle(.pill).keyboardShortcut(.cancelAction)
            }
            Text("Gleich öffnet sich dein Browser. Bestätige dort die Anmeldung mit deinem Abo; falls ein Code verlangt wird, füge ihn unten ein.")
                .font(.system(size: 12.5)).foregroundStyle(Desk.dim).fixedSize(horizontal: false, vertical: true)
            LoginTerminal(provider: provider, account: account) { dismiss(); done() }
                .frame(width: 640, height: 300).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }.padding(20).dialogStyle()
    }
}

private struct LoginTerminal: NSViewRepresentable {
    let provider: Provider
    let account: String
    let finished: () -> Void

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        let finished: () -> Void
        init(finished: @escaping () -> Void) { self.finished = finished }
        func processTerminated(source: TerminalView, exitCode: Int32?) {
            guard exitCode == 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.finished() }
        }
        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    }

    func makeCoordinator() -> Coordinator { Coordinator(finished: finished) }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 300))
        view.processDelegate = context.coordinator
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.nativeBackgroundColor = NSColor(srgbRed: 0.08, green: 0.08, blue: 0.08, alpha: 1)
        view.nativeForegroundColor = NSColor(white: 0.93, alpha: 1)
        if let launcher = AppPaths.script("launcher") {
            var env = ProcessInfo.processInfo.environment
            env["TERM"] = "xterm-256color"
            env["PATH"] = (env["PATH"] ?? "/usr/bin:/bin") + ":" + NSHomeDirectory() + "/.local/bin:/opt/homebrew/bin:/usr/local/bin"
            view.startProcess(executable: AppPaths.python.path, args: ["-B", launcher.path, "login", provider.rawValue] + (account.isEmpty ? [] : [account]),
                              environment: env.map { $0.key + "=" + $0.value })
        }
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }
    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
    /// Wer das Fenster schließt, bricht auch die Anmeldung ab.
    static func dismantleNSView(_ nsView: LocalProcessTerminalView, coordinator: Coordinator) {
        if nsView.process.running { nsView.terminate() }
    }
}

/// Ersteinrichtung in drei Schritten: Name, Projekt, Agent-Programme.
struct Onboarding: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var agents: AgentStore
    @State private var step = 0
    @State private var name = ""
    @State private var coordinator = "Mochi"
    @State private var folder: URL?
    @State private var status: ClientStatus?
    @State private var login: Provider?
    @State private var keepInDock = true
    private let toolsMissing = !AppPaths.pythonAvailable
    /// Vorschlag für das erste Projekt, damit niemand erst einen Ordner suchen muss. Angelegt wird er erst am Ende.
    static let starterFolder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Mochi Squad", isDirectory: true)

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 22) {
                MochiCanvas(look: .coordinator).frame(width: 96, height: 96)
                Group {
                    switch step {
                    case 0: welcome
                    case 1: projectStep
                    default: clients
                    }
                }.frame(width: 460)
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { index in
                    Capsule().fill(index == step ? Desk.text : Desk.edge).frame(width: index == step ? 18 : 6, height: 6)
                }
            }.padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Desk.canvas)
        .onAppear {
            // Vorname aus dem macOS-Konto vorschlagen, damit meist ein Klick auf „Weiter“ reicht.
            name = settings.value.ownerName.isEmpty ? String(NSFullUserName().split(separator: " ").first ?? "") : settings.value.ownerName
            coordinator = settings.value.coordinatorName
            folder = settings.projects.first ?? Self.starterFolder
        }
        .task { status = await ClientStatus.load() }
        .sheet(item: $login) { provider in
            LoginSheet(provider: provider) { Task { status = await ClientStatus.load() } }
        }
    }

    private var welcome: some View {
        VStack(spacing: 14) {
            title("Willkommen bei Mochi Squad", "Dein Team aus KI-Agenten auf dem Mac. In einer Minute bist du startklar.")
            if toolsMissing {
                note("Es fehlen die Befehlszeilenwerkzeuge von Apple. Öffne das Terminal, führe „xcode-select --install“ aus und starte Mochi Squad danach neu.", Desk.warning)
            }
            field("Wie heißt du?", "Dein Vorname", $name)
            field("Wie soll dein Koordinator heißen?", "Mochi", $coordinator)
            Button("Weiter") { step = 1 }.buttonStyle(.primaryPill).keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || toolsMissing)
        }
    }

    private var projectStep: some View {
        VStack(spacing: 14) {
            title("Dein erstes Projekt", "Agenten arbeiten immer in einem Ordner: einem Code-Projekt, einer Textsammlung, was du willst. Nimm den Vorschlag oder wähle einen eigenen Ordner. Weitere Projekte kannst du später hinzufügen.")
            Button(action: pickFolder) {
                HStack {
                    Image(systemName: "folder").foregroundStyle(Desk.dim)
                    Text(folder?.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") ?? "Ordner wählen …").lineLimit(1).truncationMode(.head)
                    Spacer()
                    Text(folder.map { FileManager.default.fileExists(atPath: $0.path) } == false ? "wird angelegt" : "Ändern").foregroundStyle(Desk.faint)
                }.font(.system(size: 13.5)).padding(.horizontal, 14).frame(height: 40).field(12).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if folderAllowed { note("Agenten dürfen in diesem Ordner lesen. Schreiben dürfen nur die, denen du es erlaubst.", Desk.dim) }
            else { note(SettingsStore.refusedProject, Desk.warning) }
            HStack(spacing: 10) {
                Button("Zurück") { step = 0 }.buttonStyle(.pill)
                Button("Weiter") { step = 2 }.buttonStyle(.primaryPill).keyboardShortcut(.defaultAction).disabled(!folderAllowed)
            }
        }
    }

    private var clients: some View {
        VStack(spacing: 14) {
            title("Mit deinem Abo anmelden", "Mochi Squad nutzt Claude Code und Codex mit deinem bestehenden Claude- oder ChatGPT-Abo. Dein Koordinator läuft mit Claude Code; weitere Agenten auch mit Codex.")
            ForEach(Provider.allCases) { provider in
                ClientRow(provider: provider, entry: status?.entry(provider)) { login = provider }
            }
            if status.map({ $0.claude.installed && !$0.claude.loggedIn || !$0.claude.installed && $0.codex.installed }) == true {
                note("Ohne Claude Code kann der Koordinator nicht arbeiten. Agenten mit Codex funktionieren trotzdem.", Desk.warning)
            }
            if status.map({ !$0.claude.installed && !$0.codex.installed }) == true {
                note("Installiere mindestens eines der Programme. Mochi Squad erkennt es danach von selbst.", Desk.warning)
            }
            Toggle("Mochi Squad im Dock behalten", isOn: $keepInDock).toggleStyle(.checkbox).font(.system(size: 13.5))
            HStack(spacing: 10) {
                Button("Zurück") { step = 1 }.buttonStyle(.pill)
                Button("Los geht's", action: complete).buttonStyle(.primaryPill).keyboardShortcut(.defaultAction)
            }
        }
        .task {
            // Solange dieser Schritt offen ist, neu installierte oder angemeldete Programme von selbst erkennen.
            while !Task.isCancelled, status?.allReady != true {
                try? await Task.sleep(for: .seconds(5))
                if login == nil { status = await ClientStatus.load() }
            }
        }
    }

    private var folderAllowed: Bool { folder.map { SettingsStore.projectAllowed($0) } ?? false }

    private var coordinatorName: String {
        let trimmed = coordinator.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Mochi" : trimmed
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.prompt = "Ordner wählen"
        if panel.runModal() == .OK { folder = panel.url?.standardizedFileURL.resolvingSymlinksInPath() }
    }

    private func complete() {
        guard let folder, folderAllowed, (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { return }
        settings.value.ownerName = name.trimmingCharacters(in: .whitespaces)
        settings.value.coordinatorName = coordinatorName
        settings.addProject(folder)
        agents.ensureCoordinator(in: folder, name: coordinatorName)
        agents.renameCoordinators(to: coordinatorName)
        if keepInDock { Dock.keepApp() }
        settings.value.onboarded = true
    }

    private func title(_ head: String, _ text: String) -> some View {
        VStack(spacing: 8) {
            Text(head).font(.system(size: 24, weight: .semibold)).multilineTextAlignment(.center)
            Text(text).font(.system(size: 14)).foregroundStyle(Desk.dim).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }.padding(.bottom, 6)
    }

    private func note(_ text: String, _ color: SwiftUI.Color) -> some View {
        Text(text).font(.system(size: 12.5)).foregroundStyle(color).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
    }

    private func field(_ label: String, _ placeholder: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12.5)).foregroundStyle(Desk.dim)
            TextField(placeholder, text: text).textFieldStyle(.plain).font(.system(size: 14)).padding(.horizontal, 14).frame(height: 40).field(12)
        }
    }
}

/// Einstellungen: Namen, Agent-Programme, Dock.
struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var agents: AgentStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var coordinator = ""
    @State private var status: ClientStatus?
    @State private var login: Provider?
    @State private var accountLogin: Account?
    @State private var removing: Account?
    @EnvironmentObject private var manager: SessionManager
    @State private var newAccount = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Einstellungen").font(.system(size: 22, weight: .semibold))
                Spacer()
                Button("Fertig") { apply(); dismiss() }.buttonStyle(.primaryPill).keyboardShortcut(.defaultAction)
            }
            line("Dein Name") { TextField("Vorname", text: $name).textFieldStyle(.plain).padding(.horizontal, 12).frame(height: 32).field(8) }
            line("Koordinator") { TextField("Mochi", text: $coordinator).textFieldStyle(.plain).padding(.horizontal, 12).frame(height: 32).field(8) }
            Rectangle().fill(Desk.rule).frame(height: 1)
            Text("Agent-Programme").font(.system(size: 13, weight: .semibold)).foregroundStyle(Desk.dim)
            ForEach(Provider.allCases) { provider in
                ClientRow(provider: provider, entry: status?.entry(provider)) { login = provider }
            }
            Text("Angemeldet wird im jeweiligen Programm mit deinem Abo. Mochi Squad speichert keine Zugangsdaten.")
                .font(.system(size: 12)).foregroundStyle(Desk.dim).fixedSize(horizontal: false, vertical: true)
            Rectangle().fill(Desk.rule).frame(height: 1)
            accountsSection
            Rectangle().fill(Desk.rule).frame(height: 1)
            HStack {
                Button("Im Dock behalten") { Dock.keepApp() }.buttonStyle(.pill).disabled(Dock.containsApp)
                Button("Daten im Finder zeigen") { NSWorkspace.shared.open(AppPaths.support) }.buttonStyle(.pill)
            }
        }
        .font(.system(size: 13.5)).padding(22).frame(width: 460)
        .onAppear { name = settings.value.ownerName; coordinator = settings.value.coordinatorName }
        .task { status = await ClientStatus.load() }
        .sheet(item: $login) { provider in
            LoginSheet(provider: provider) { Task { status = await ClientStatus.load() } }
        }
        .sheet(item: $accountLogin) { account in
            LoginSheet(provider: .codex, account: account.id) { Task { status = await ClientStatus.load() } }
        }
        .confirmationDialog("Abo „\(removing?.name ?? "")“ entfernen?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Abo und seine Verläufe entfernen", role: .destructive) {
                guard let account = removing else { return }
                // Erst die Sitzungen schließen, die noch mit diesem Abo laufen.
                for agent in agents.agents where agent.account == account.id {
                    if let live = manager.liveSession(for: agent.id) { manager.close(live) }
                }
                settings.removeAccount(account)
                agents.releaseAccount(account.id)
                removing = nil
            }
            Button("Abbrechen", role: .cancel) { removing = nil }
        } message: {
            Text("Die Anmeldung und alle Chat-Verläufe dieses Abos werden von diesem Mac gelöscht. Agenten, die es nutzen, arbeiten danach mit dem Haupt-Abo.")
        }
    }

    /// Weitere ChatGPT-Abos: jedes mit eigener Anmeldung, je Agent wählbar.
    private var accountsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Weitere ChatGPT-Abos").font(.system(size: 13, weight: .semibold)).foregroundStyle(Desk.dim)
            ForEach(settings.accounts) { account in
                let ready = status?.accounts?[account.id] == true
                HStack(spacing: 10) {
                    Image(systemName: ready ? "checkmark.circle.fill" : "person.crop.circle.badge.exclamationmark")
                        .font(.system(size: 16)).foregroundStyle(ready ? Desk.success : Desk.faint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(account.name).font(.system(size: 13.5, weight: .medium))
                        Text(ready ? "angemeldet" : "noch nicht angemeldet").font(.system(size: 12)).foregroundStyle(Desk.dim)
                    }
                    Spacer()
                    if !ready { Button("Anmelden") { accountLogin = account }.buttonStyle(.primaryPill) }
                    Button { removing = account } label: { Image(systemName: "trash") }.buttonStyle(.pill).help("Abo entfernen")
                }.padding(.horizontal, 12).frame(height: 48).field(12)
            }
            HStack(spacing: 8) {
                TextField("Name, z. B. Arbeit", text: $newAccount).textFieldStyle(.plain).padding(.horizontal, 12).frame(height: 32).field(8)
                    .onSubmit(addAccount)
                Button("Abo hinzufügen", action: addAccount).buttonStyle(.pill)
                    .disabled(newAccount.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("Lege hier ein zweites oder drittes ChatGPT-Abo an und wähle beim Agenten, mit welchem er arbeitet. So verteilst du die Nutzung auf mehrere Abos.")
                .font(.system(size: 12)).foregroundStyle(Desk.dim).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func addAccount() {
        let name = newAccount.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        newAccount = ""
        accountLogin = settings.addAccount(named: name)
    }

    private func apply() {
        let owner = name.trimmingCharacters(in: .whitespaces), lead = coordinator.trimmingCharacters(in: .whitespaces)
        if !owner.isEmpty { settings.value.ownerName = owner }
        if !lead.isEmpty, lead != settings.value.coordinatorName {
            settings.value.coordinatorName = lead
            agents.renameCoordinators(to: lead)
        }
    }

    private func line<Field: View>(_ title: String, @ViewBuilder _ field: () -> Field) -> some View {
        HStack {
            Text(title).foregroundStyle(Desk.dim).frame(width: 100, alignment: .leading)
            field()
        }
    }
}
