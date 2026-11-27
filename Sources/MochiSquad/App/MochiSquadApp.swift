import AppKit
import SwiftUI

/// All state of the app in one place; views get the individual stores through the environment.
@MainActor final class AppState: ObservableObject {
    static let shared = AppState()
    let settings = SettingsStore()
    let agents = AgentStore()
    let routines = RoutineStore()
    let team = TeamLog()
    let transcript = TranscriptStore()
    let chats = ChatIndex()
    let skills = SkillStore()
    let limits = LimitStore()
    let memory: MemoryStore
    let navigation = Navigation()
    let manager: SessionManager
    let messengers: MessengerHub

    private init() {
        manager = SessionManager(agents: agents, settings: settings, routines: routines, team: team)
        memory = MemoryStore(folder: MemoryStore.folder(chosen: settings.value.memoryFolder))
        manager.memory = memory
        messengers = MessengerHub(manager: manager, settings: settings, team: team)
        messengers.routines = routines
    }
}

@main
struct MochiSquadApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let state = AppState.shared

    var body: some Scene {
        Window(AppPaths.appName, id: "main") {
            RootView()
                .environmentObject(state.settings)
                .environmentObject(state.agents)
                .environmentObject(state.routines)
                .environmentObject(state.team)
                .environmentObject(state.transcript)
                .environmentObject(state.chats)
                .environmentObject(state.skills)
                .environmentObject(state.limits)
                .environmentObject(state.memory)
                .environmentObject(state.navigation)
                .environmentObject(state.manager)
                .environmentObject(state.messengers)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: min(1500, NSScreen.main?.visibleFrame.width ?? 1200),
                     height: min(960, NSScreen.main?.visibleFrame.height ?? 760))
        .windowResizability(.contentMinSize)
        .commands { CommandGroup(after: .appInfo) { UpdateMenuItem() } }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // A helper process that ended must not take the app down through a write to its pipe.
        signal(SIGPIPE, SIG_IGN)
        // Two instances would delete each other's session folders: bring the running one to the front and quit this one.
        if let id = Bundle.main.bundleIdentifier,
           let other = NSRunningApplication.runningApplications(withBundleIdentifier: id).first(where: { $0 != .current }) {
            other.activate()
            exit(0)
        }
        AppPaths.prepareRuntime()
        _ = Updates.shared
        let state = AppState.shared
        SaveGuard.report = { [weak manager = state.manager] text in manager?.notice = text }
        state.manager.start()
        if state.agents.loadFailed {
            // Routines carry a description of their agent: those agents come back with their ids, so every routine keeps its owner.
            let restored = state.agents.restore(from: state.routines.routines)
            state.manager.notice = t("The list of your agents was damaged and has been backed up. Your routines are untouched\(restored > 0 ? ", and \(restored == 1 ? "the agent" : "the \(restored) agents") they belong to \(restored == 1 ? "was" : "were") restored" : ""). Please create the remaining agents again.",
                                     "Die Liste deiner Agenten war beschädigt und wurde gesichert. Deine Routinen sind unverändert\(restored > 0 ? ", und \(restored == 1 ? "der zugehörige Agent wurde" : "die \(restored) zugehörigen Agenten wurden") wiederhergestellt" : ""). Lege die übrigen Agenten bitte neu an.")
        }
        state.routines.sync(with: state.agents.agents)
        state.routines.installAll()
        // Skills from Claude Code and Codex are linked from the first launch on, without a click.
        state.skills.sync()
        // Plan usage: warnings appear in the app and reach the phone, so a limit never comes as a surprise.
        state.limits.accountName = { [weak settings = state.settings] id in settings?.accounts.first { $0.id == id }?.name }
        state.limits.onWarning = { [weak manager = state.manager, weak messengers = state.messengers] text in
            manager?.notice = text
            messengers?.announce(text)
        }
        state.limits.start()
        // Routine results come to the user: as a Mac notification and on the phone. Quiet routines only when there is news.
        state.routines.onFinished = { [weak messengers = state.messengers, weak settings = state.settings] run in
            guard run.silent != true, run.code != 75 else { return }
            // The phone hears about the messenger's own project, as with its team chat; the Mac about every project.
            let toPhone = run.project != nil && run.project == settings?.messengerProject?.path
            let who = run.name ?? t("Routine", "Routine")
            let body = run.code == 0 ? Notifier.summary(of: run.output ?? "")
                                     : t("The routine failed: ", "Die Routine ist fehlgeschlagen: ") + Notifier.summary(of: run.output ?? "", limit: 160)
            Notifier.post(title: who, body: body.isEmpty ? t("Done.", "Fertig.") : body)
            if toPhone, let project = run.project { messengers?.announce(who + ": " + (body.isEmpty ? t("Done.", "Fertig.") : body), project: project) }
        }
        state.routines.deliverMissed()
        state.messengers.start()
    }

    /// Back in the app, for example after signing in to a client or installing a skill there: link what is new.
    /// At most once a minute, since the check walks the skill folders.
    private var skillsChecked = Date()
    func applicationDidBecomeActive(_ notification: Notification) {
        guard Date().timeIntervalSince(skillsChecked) > 60 else { return }
        skillsChecked = Date()
        AppState.shared.skills.sync()
    }

    /// Start links of routines (mochisquad://run?routine=…&key=…). A wrong or unknown link does nothing.
    func application(_ application: NSApplication, open urls: [URL]) {
        let routines = AppState.shared.routines
        for url in urls {
            if let routine = routines.open(link: url), routine.quiet != true {
                Notifier.post(title: routine.agent.name, body: t("Routine started from its link.", "Routine über ihren Link gestartet."))
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let manager = AppState.shared.manager
        if manager.runningCount > 0 {
            let count = manager.runningCount
            let alert = NSAlert()
            alert.messageText = count == 1 ? t("One session is still open", "Eine Sitzung ist noch offen") : t("\(count) sessions are still open", "\(count) Sitzungen sind noch offen")
            alert.informativeText = t("Should your agents keep running in the background? Mochi Squad then stays open and is only hidden; you bring it back through the Dock. Quitting closes the sessions; the chat histories are kept.",
                                      "Sollen deine Agenten im Hintergrund weiterlaufen? Mochi Squad bleibt dann geöffnet und ist nur ausgeblendet; über das Dock holst du es zurück. Beim Beenden werden die Sitzungen geschlossen, die Verläufe bleiben erhalten.")
            alert.addButton(withTitle: t("Keep running in the background", "Im Hintergrund weiterlaufen"))
            alert.addButton(withTitle: t("Quit", "Beenden"))
            alert.addButton(withTitle: t("Cancel", "Abbrechen"))
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                // The sessions belong to the app; running in the background therefore means: hide instead of quit.
                NSApp.hide(nil)
                return .terminateCancel
            case .alertSecondButtonReturn: break
            default: return .terminateCancel
            }
        }
        AppState.shared.messengers.stop()
        manager.shutdown()
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Click on the Dock icon: bring back the hidden app together with its window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        sender.unhide(nil)
        if !hasVisibleWindows { sender.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil) }
        return true
    }
}

/// Shows the first setup until it is finished, then the workspace.
struct RootView: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Group {
            if settings.value.onboarded, !settings.projects.isEmpty { Workspace() } else { Onboarding() }
        }
        // A new language rebuilds everything, so every text is read again.
        .id(settings.language)
        .environment(\.locale, settings.language.locale)
        .frame(minWidth: 640, minHeight: 480)
        .preferredColorScheme(.dark).foregroundStyle(Desk.text).tint(Desk.accent)
        .background(Desk.canvas)
        .background(WindowChrome())
        .ignoresSafeArea(.container, edges: .top)
    }
}

/// Transparent title bar; the window buttons sit above the icon rail.
struct WindowChrome: NSViewRepresentable {
    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.titlebarAppearsTransparent = true
            window?.titleVisibility = .hidden
            window?.backgroundColor = NSColor(srgbRed: 10 / 255, green: 10 / 255, blue: 10 / 255, alpha: 1)
        }
    }
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ nsView: Probe, context: Context) {}
}

/// Keep the app in the Dock (like "Options › Keep in Dock").
enum Dock {
    static var containsApp: Bool {
        let apps = UserDefaults(suiteName: "com.apple.dock")?.array(forKey: "persistent-apps") as? [[String: Any]] ?? []
        return apps.contains { entry in
            let data = (entry["tile-data"] as? [String: Any])?["file-data"] as? [String: Any]
            return (data?["_CFURLString"] as? String)?.removingPercentEncoding?.contains(Bundle.main.bundleURL.lastPathComponent) == true
        }
    }

    /// Adds the app to the Dock and reloads the Dock. Does nothing if it is already there.
    static func keepApp() {
        guard !containsApp, Bundle.main.bundleURL.pathExtension == "app" else { return }
        let entry = entry(for: Bundle.main.bundleURL)
        DispatchQueue.global(qos: .utility).async {
            run("/usr/bin/defaults", ["write", "com.apple.dock", "persistent-apps", "-array-add", entry])
            run("/usr/bin/killall", ["Dock"])
        }
    }

    /// Dock entry of an app as property list text for `defaults write … -array-add`.
    static func entry(for app: URL) -> String {
        let path = app.path
            .replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        return "<dict><key>tile-data</key><dict><key>file-data</key><dict><key>_CFURLString</key><string>" + path
            + "</string><key>_CFURLStringType</key><integer>0</integer></dict></dict></dict>"
    }

    private static func run(_ tool: String, _ args: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        guard (try? process.run()) != nil else { return }
        process.waitUntilExit()
    }
}
