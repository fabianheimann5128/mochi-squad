import AppKit
import SwiftTerm
import SwiftUI

/// State of the agent programs (from launcher.py status).
struct ClientStatus: Decodable {
    struct Entry: Decodable { let installed, loggedIn: Bool; let path, detail: String }
    let claude: Entry
    let codex: Entry
    /// Sign-in state of extra ChatGPT subscriptions, by id.
    let accounts: [String: Bool]?
    func entry(_ provider: Provider) -> Entry { provider == .claude ? claude : codex }
    var allReady: Bool { claude.loggedIn && codex.loggedIn }
    static func load() async -> ClientStatus? { try? await PythonTool.run("launcher", ["status"], as: ClientStatus.self) }
}

/// Row for an agent program: status, sign-in with the own subscription, or install guide.
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
                    Button(t("Guide", "Anleitung")) {
                        NSWorkspace.shared.open(URL(string: provider == .claude ? "https://docs.claude.com/claude-code" : "https://developers.openai.com/codex/cli")!)
                    }.buttonStyle(.pill)
                } else if !entry.loggedIn {
                    Button(t("Sign in", "Anmelden"), action: login).buttonStyle(.primaryPill)
                }
            }
        }.padding(.horizontal, 14).frame(height: 54).field(12)
    }

    private var text: String {
        guard let entry else { return t("checking …", "wird geprüft …") }
        if !entry.installed { return t("not installed", "nicht installiert") }
        let plan = provider == .claude ? "Claude" : "ChatGPT"
        return entry.loggedIn ? t("signed in", "angemeldet") : t("installed · sign in with your \(plan) plan", "installiert · mit deinem \(plan)-Abo anmelden")
    }
}

/// Sign-in in the real client: the browser opens, afterwards the window closes by itself.
struct LoginSheet: View {
    let provider: Provider
    /// Extra ChatGPT subscription being signed in; empty for the regular sign-in.
    var account = ""
    let done: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(t("Sign in to \(provider.title)", "Bei \(provider.title) anmelden")).font(.system(size: 17, weight: .semibold))
                Spacer()
                Button(t("Close", "Schließen")) { dismiss(); done() }.buttonStyle(.pill).keyboardShortcut(.cancelAction)
            }
            Text(t("Your browser opens in a moment. Confirm the sign-in with your subscription there; if a code is asked for, paste it below.",
                   "Gleich öffnet sich dein Browser. Bestätige dort die Anmeldung mit deinem Abo; falls ein Code verlangt wird, füge ihn unten ein."))
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
            var env = AppPaths.helperEnvironment()
            env["TERM"] = "xterm-256color"
            env["PATH"] = (env["PATH"] ?? "/usr/bin:/bin") + ":" + NSHomeDirectory() + "/.local/bin:/opt/homebrew/bin:/usr/local/bin"
            view.startProcess(executable: AppPaths.python.path, args: ["-B", launcher.path, "login", provider.rawValue] + (account.isEmpty ? [] : [account]),
                              environment: env.map { $0.key + "=" + $0.value })
        }
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }
    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
    /// Closing the window also cancels the sign-in.
    static func dismantleNSView(_ nsView: LocalProcessTerminalView, coordinator: Coordinator) {
        if nsView.process.running { nsView.terminate() }
    }
}

/// First setup in three steps: language and name, project, agent programs.
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
    /// Suggestion for the first project so nobody has to look for a folder first. It is created only at the end.
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
            // Suggest the first name from the macOS account so that one click on "Continue" is usually enough.
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
            // The language comes first; switching rebuilds the window, so what was typed is kept in the settings.
            PillPicker(selection: Binding(get: { settings.language }, set: { chosen in
                settings.value.ownerName = name.trimmingCharacters(in: .whitespaces)
                settings.value.coordinatorName = coordinatorName
                settings.value.language = chosen == .en ? nil : chosen
            }), options: Language.allCases.map { ($0, $0.title) })
            title(t("Welcome to Mochi Squad", "Willkommen bei Mochi Squad"),
                  t("Your team of AI agents on the Mac. You will be ready in a minute.", "Dein Team aus KI-Agenten auf dem Mac. In einer Minute bist du startklar."))
            if toolsMissing {
                note(t("Apple's command line tools are missing. Open Terminal, run “xcode-select --install” and then restart Mochi Squad.",
                       "Es fehlen die Befehlszeilenwerkzeuge von Apple. Öffne das Terminal, führe „xcode-select --install“ aus und starte Mochi Squad danach neu."), Desk.warning)
            }
            field(t("What is your name?", "Wie heißt du?"), t("Your first name", "Dein Vorname"), $name)
            field(t("What should your coordinator be called?", "Wie soll dein Koordinator heißen?"), "Mochi", $coordinator)
            Button(t("Continue", "Weiter")) { step = 1 }.buttonStyle(.primaryPill).keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || toolsMissing)
        }
    }

    private var projectStep: some View {
        VStack(spacing: 14) {
            title(t("Your first project", "Dein erstes Projekt"),
                  t("Agents always work in a folder: a code project, a collection of texts, whatever you like. Take the suggestion or choose your own folder. You can add more projects later.",
                    "Agenten arbeiten immer in einem Ordner: einem Code-Projekt, einer Textsammlung, was du willst. Nimm den Vorschlag oder wähle einen eigenen Ordner. Weitere Projekte kannst du später hinzufügen."))
            Button(action: pickFolder) {
                HStack {
                    Image(systemName: "folder").foregroundStyle(Desk.dim)
                    Text(folder?.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") ?? t("Choose folder …", "Ordner wählen …")).lineLimit(1).truncationMode(.head)
                    Spacer()
                    Text(folder.map { FileManager.default.fileExists(atPath: $0.path) } == false ? t("will be created", "wird angelegt") : t("Change", "Ändern")).foregroundStyle(Desk.faint)
                }.font(.system(size: 13.5)).padding(.horizontal, 14).frame(height: 40).field(12).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if folderAllowed { note(t("Agents may read in this folder. Only those you allow may write.", "Agenten dürfen in diesem Ordner lesen. Schreiben dürfen nur die, denen du es erlaubst."), Desk.dim) }
            else { note(SettingsStore.refusedProject, Desk.warning) }
            HStack(spacing: 10) {
                Button(t("Back", "Zurück")) { step = 0 }.buttonStyle(.pill)
                Button(t("Continue", "Weiter")) { step = 2 }.buttonStyle(.primaryPill).keyboardShortcut(.defaultAction).disabled(!folderAllowed)
            }
        }
    }

    private var clients: some View {
        VStack(spacing: 14) {
            title(t("Sign in with your subscription", "Mit deinem Abo anmelden"),
                  t("Mochi Squad uses Claude Code and Codex with your existing Claude or ChatGPT subscription. One of the two is enough; every agent, the coordinator included, can run on either.",
                    "Mochi Squad nutzt Claude Code und Codex mit deinem bestehenden Claude- oder ChatGPT-Abo. Eines von beiden genügt; jeder Agent, auch der Koordinator, kann mit beiden laufen."))
            ForEach(Provider.allCases) { provider in
                ClientRow(provider: provider, entry: status?.entry(provider)) { login = provider }
            }
            if status.map({ !$0.claude.installed && $0.codex.installed }) == true {
                note(t("Claude Code is not installed, so your coordinator will run with Codex.", "Claude Code ist nicht installiert, dein Koordinator läuft deshalb mit Codex."), Desk.dim)
            }
            if status.map({ !$0.claude.installed && !$0.codex.installed }) == true {
                note(t("Install at least one of the programs. Mochi Squad will then detect it by itself.", "Installiere mindestens eines der Programme. Mochi Squad erkennt es danach von selbst."), Desk.warning)
            }
            Toggle(t("Keep Mochi Squad in the Dock", "Mochi Squad im Dock behalten"), isOn: $keepInDock).toggleStyle(.checkbox).font(.system(size: 13.5))
            HStack(spacing: 10) {
                Button(t("Back", "Zurück")) { step = 1 }.buttonStyle(.pill)
                Button(t("Let's go", "Los geht's"), action: complete).buttonStyle(.primaryPill).keyboardShortcut(.defaultAction)
            }
        }
        .task {
            // While this step is open, detect newly installed or signed-in programs by itself.
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
        panel.prompt = t("Choose folder", "Ordner wählen")
        if panel.runModal() == .OK { folder = panel.url?.standardizedFileURL.resolvingSymlinksInPath() }
    }

    private func complete() {
        guard let folder, folderAllowed, (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { return }
        settings.value.ownerName = name.trimmingCharacters(in: .whitespaces)
        settings.value.coordinatorName = coordinatorName
        settings.addProject(folder)
        if keepInDock { Dock.keepApp() }
        // The workspace creates the coordinator when it opens the project, with the program that is really installed.
        agents.renameCoordinators(to: coordinatorName)
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

/// Settings: names, language, agent programs, subscriptions, messengers, Dock.
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
        ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(t("Settings", "Einstellungen")).font(.system(size: 22, weight: .semibold))
                Spacer()
                Button(t("Done", "Fertig")) { apply(); dismiss() }.buttonStyle(.primaryPill).keyboardShortcut(.defaultAction)
            }
            line(t("Your name", "Dein Name")) { TextField(t("First name", "Vorname"), text: $name).textFieldStyle(.plain).padding(.horizontal, 12).frame(height: 32).field(8) }
            line(t("Coordinator", "Koordinator")) { TextField("Mochi", text: $coordinator).textFieldStyle(.plain).padding(.horizontal, 12).frame(height: 32).field(8) }
            line(t("Language", "Sprache")) {
                PillPicker(selection: Binding(get: { settings.language }, set: { chosen in apply(); settings.value.language = chosen == .en ? nil : chosen }),
                           options: Language.allCases.map { ($0, $0.title) }).frame(maxWidth: .infinity, alignment: .leading)
            }
            Rectangle().fill(Desk.rule).frame(height: 1)
            Text(t("Agent programs", "Agent-Programme")).font(.system(size: 13, weight: .semibold)).foregroundStyle(Desk.dim)
            ForEach(Provider.allCases) { provider in
                ClientRow(provider: provider, entry: status?.entry(provider)) { login = provider }
            }
            Text(t("You sign in inside the respective program with your subscription. Mochi Squad stores no credentials.",
                   "Angemeldet wird im jeweiligen Programm mit deinem Abo. Mochi Squad speichert keine Zugangsdaten."))
                .font(.system(size: 12)).foregroundStyle(Desk.dim).fixedSize(horizontal: false, vertical: true)
            Rectangle().fill(Desk.rule).frame(height: 1)
            accountsSection
            Rectangle().fill(Desk.rule).frame(height: 1)
            MessengerSection()
            Rectangle().fill(Desk.rule).frame(height: 1)
            HStack {
                Button(t("Keep in Dock", "Im Dock behalten")) { Dock.keepApp() }.buttonStyle(.pill).disabled(Dock.containsApp)
                Button(t("Show data in Finder", "Daten im Finder zeigen")) { NSWorkspace.shared.open(AppPaths.support) }.buttonStyle(.pill)
            }
        }
        .font(.system(size: 13.5)).padding(22).frame(width: 480)
        }.frame(width: 480).frame(maxHeight: 760)
        .onAppear { name = settings.value.ownerName; coordinator = settings.value.coordinatorName }
        .task { status = await ClientStatus.load() }
        .sheet(item: $login) { provider in
            LoginSheet(provider: provider) { Task { status = await ClientStatus.load() } }
        }
        .sheet(item: $accountLogin) { account in
            LoginSheet(provider: .codex, account: account.id) { Task { status = await ClientStatus.load() } }
        }
        .confirmationDialog(t("Remove plan “\(removing?.name ?? "")”?", "Abo „\(removing?.name ?? "")“ entfernen?"),
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button(t("Remove plan and its chat histories", "Abo und seine Verläufe entfernen"), role: .destructive) {
                guard let account = removing else { return }
                // First close the sessions that were started with this plan, whatever their agent is set to now.
                manager.closeSessions(using: account.id)
                settings.removeAccount(account)
                agents.releaseAccount(account.id)
                removing = nil
            }
            Button(t("Cancel", "Abbrechen"), role: .cancel) { removing = nil }
        } message: {
            Text(t("The sign-in and all chat histories of this plan are deleted from this Mac. Agents that use it then work with the main plan.",
                   "Die Anmeldung und alle Chat-Verläufe dieses Abos werden von diesem Mac gelöscht. Agenten, die es nutzen, arbeiten danach mit dem Haupt-Abo."))
        }
    }

    /// Extra ChatGPT subscriptions: each with its own sign-in, selectable per agent.
    private var accountsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(t("More ChatGPT plans", "Weitere ChatGPT-Abos")).font(.system(size: 13, weight: .semibold)).foregroundStyle(Desk.dim)
            ForEach(settings.accounts) { account in
                let ready = status?.accounts?[account.id] == true
                HStack(spacing: 10) {
                    Image(systemName: ready ? "checkmark.circle.fill" : "person.crop.circle.badge.exclamationmark")
                        .font(.system(size: 16)).foregroundStyle(ready ? Desk.success : Desk.faint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(account.name).font(.system(size: 13.5, weight: .medium))
                        Text(ready ? t("signed in", "angemeldet") : t("not signed in yet", "noch nicht angemeldet")).font(.system(size: 12)).foregroundStyle(Desk.dim)
                    }
                    Spacer()
                    if !ready { Button(t("Sign in", "Anmelden")) { accountLogin = account }.buttonStyle(.primaryPill) }
                    Button { removing = account } label: { Image(systemName: "trash") }.buttonStyle(.pill).help(t("Remove plan", "Abo entfernen"))
                }.padding(.horizontal, 12).frame(height: 48).field(12)
            }
            HStack(spacing: 8) {
                TextField(t("Name, e.g. Work", "Name, z. B. Arbeit"), text: $newAccount).textFieldStyle(.plain).padding(.horizontal, 12).frame(height: 32).field(8)
                    .onSubmit(addAccount)
                Button(t("Add plan", "Abo hinzufügen"), action: addAccount).buttonStyle(.pill)
                    .disabled(newAccount.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text(t("Add a second or third ChatGPT plan here and choose per agent which one it works with. That spreads the usage across several plans.",
                   "Lege hier ein zweites oder drittes ChatGPT-Abo an und wähle beim Agenten, mit welchem er arbeitet. So verteilst du die Nutzung auf mehrere Abos."))
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
