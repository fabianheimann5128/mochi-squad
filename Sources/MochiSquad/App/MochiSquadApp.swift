import AppKit
import SwiftUI

/// Alle Zustände der App an einem Ort; Views bekommen die einzelnen Stores über die Umgebung.
@MainActor final class AppState: ObservableObject {
    static let shared = AppState()
    let settings = SettingsStore()
    let agents = AgentStore()
    let routines = RoutineStore()
    let team = TeamLog()
    let transcript = TranscriptStore()
    let chats = ChatIndex()
    let manager: SessionManager

    private init() {
        manager = SessionManager(agents: agents, settings: settings, routines: routines, team: team)
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
                .environmentObject(state.manager)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: min(1500, NSScreen.main?.visibleFrame.width ?? 1200),
                     height: min(960, NSScreen.main?.visibleFrame.height ?? 760))
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ein beendeter Hilfsprozess darf die App nicht über ein Schreiben in seine Pipe mitreißen.
        signal(SIGPIPE, SIG_IGN)
        AppPaths.prepareRuntime()
        let state = AppState.shared
        state.manager.start()
        if state.agents.loadFailed {
            state.manager.notice = "Die Liste deiner Agenten war beschädigt und wurde gesichert. Routinen bleiben erhalten; lege die Agenten bitte neu an."
        } else {
            state.routines.sync(with: state.agents.agents)
        }
        state.routines.installAll()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let manager = AppState.shared.manager
        if manager.runningCount > 0 {
            let alert = NSAlert()
            alert.messageText = "Mochi Squad beenden?"
            let count = manager.runningCount
            alert.informativeText = (count == 1 ? "Es läuft noch eine Sitzung. Sie wird beendet" : "Es laufen noch \(count) Sitzungen. Sie werden beendet")
                + "; die Verläufe bleiben erhalten."
            alert.addButton(withTitle: "Weiterarbeiten")
            alert.addButton(withTitle: "Beenden")
            if alert.runModal() != .alertSecondButtonReturn { return .terminateCancel }
        }
        manager.shutdown()
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Zeigt die Ersteinrichtung, bis sie abgeschlossen ist, danach den Arbeitsbereich.
struct RootView: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Group {
            if settings.value.onboarded, !settings.projects.isEmpty { Workspace() } else { Onboarding() }
        }
        .frame(minWidth: 900, minHeight: 560)
        .preferredColorScheme(.dark).foregroundStyle(Desk.text).tint(Desk.accent)
        .background(Desk.canvas)
        .background(WindowChrome())
        .ignoresSafeArea(.container, edges: .top)
    }
}

/// Durchsichtige Titelleiste; die Ampelknöpfe sitzen in der Seitenleiste.
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

/// Die App im Dock behalten (wie „Optionen › Im Dock behalten“).
enum Dock {
    static var containsApp: Bool {
        let apps = UserDefaults(suiteName: "com.apple.dock")?.array(forKey: "persistent-apps") as? [[String: Any]] ?? []
        return apps.contains { entry in
            let data = (entry["tile-data"] as? [String: Any])?["file-data"] as? [String: Any]
            return (data?["_CFURLString"] as? String)?.removingPercentEncoding?.contains(Bundle.main.bundleURL.lastPathComponent) == true
        }
    }

    /// Trägt die App ins Dock ein und lädt das Dock neu. Tut nichts, wenn sie schon dort liegt.
    static func keepApp() {
        guard !containsApp, Bundle.main.bundleURL.pathExtension == "app" else { return }
        let entry = entry(for: Bundle.main.bundleURL)
        DispatchQueue.global(qos: .utility).async {
            run("/usr/bin/defaults", ["write", "com.apple.dock", "persistent-apps", "-array-add", entry])
            run("/usr/bin/killall", ["Dock"])
        }
    }

    /// Dock-Eintrag einer App als Property-List-Text für `defaults write … -array-add`.
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
