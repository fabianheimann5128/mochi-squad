import AppKit
import SwiftTerm
import SwiftUI

/// Zustand der Agent-Programme (aus launcher.py status).
struct ClientStatus: Decodable {
    struct Entry: Decodable { let installed, loggedIn: Bool; let path, detail: String }
    let claude: Entry
    let codex: Entry
    func entry(_ provider: Provider) -> Entry { provider == .claude ? claude : codex }
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
            LoginTerminal(provider: provider) { dismiss(); done() }
                .frame(width: 640, height: 300).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }.padding(20).dialogStyle()
    }
}

private struct LoginTerminal: NSViewRepresentable {
    let provider: Provider
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
            view.startProcess(executable: AppPaths.python.path, args: ["-B", launcher.path, "login", provider.rawValue],
                              environment: env.map { $0.key + "=" + $0.value })
        }
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }
    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
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

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 22) {
                MochiCanvas(look: MochiLook(hex: "FFFFFF")).frame(width: 96, height: 96)
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
            folder = settings.projects.first
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
            title("Dein erstes Projekt", "Agenten arbeiten immer in einem Ordner: einem Code-Projekt, einer Textsammlung, was du willst. Weitere Projekte kannst du später hinzufügen.")
            Button(action: pickFolder) {
                HStack {
                    Image(systemName: "folder").foregroundStyle(Desk.dim)
                    Text(folder?.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") ?? "Ordner wählen …").lineLimit(1).truncationMode(.head)
                    Spacer()
                }.font(.system(size: 13.5)).padding(.horizontal, 14).frame(height: 40).field(12).contentShape(Rectangle())
            }.buttonStyle(.plain)
            note("Agenten dürfen in diesem Ordner lesen. Schreiben dürfen nur die, denen du es erlaubst.", Desk.dim)
            HStack(spacing: 10) {
                Button("Zurück") { step = 0 }.buttonStyle(.pill)
                Button("Weiter") { step = 2 }.buttonStyle(.primaryPill).keyboardShortcut(.defaultAction).disabled(folder == nil)
            }
        }
    }

    private var clients: some View {
        VStack(spacing: 14) {
            title("Mit deinem Abo anmelden", "Mochi Squad nutzt Claude Code und Codex mit deinem bestehenden Claude- oder ChatGPT-Abo. Eines davon genügt.")
            ForEach(Provider.allCases) { provider in
                ClientRow(provider: provider, entry: status?.entry(provider)) { login = provider }
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
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                if login == nil { status = await ClientStatus.load() }
            }
        }
    }

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
        guard let folder else { return }
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
