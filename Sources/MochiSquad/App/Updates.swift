import Sparkle
import SwiftUI

/// Updates through Sparkle. The app looks for a new version once a day and installs it after asking; every
/// update must carry the signature of the release key whose public half is in Info.plist (SUPublicEDKey).
/// Copies without that key, and test copies with another bundle id, never look.
@MainActor final class Updates: ObservableObject {
    static let shared = Updates()
    @Published private(set) var canCheck = false
    private let controller: SPUStandardUpdaterController?
    private var observation: NSKeyValueObservation?

    private init() {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        guard !key.isEmpty, Bundle.main.bundleIdentifier == "dev.mochisquad.app" else {
            controller = nil
            return
        }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        observation = controller?.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let ready = updater.canCheckForUpdates
            Task { @MainActor in self?.canCheck = ready }
        }
    }

    var available: Bool { controller != nil }
    func check() { controller?.checkForUpdates(nil) }
}

/// "Check for Updates…" in the app menu, right below "About".
struct UpdateMenuItem: View {
    @ObservedObject var updates = Updates.shared

    var body: some View {
        if updates.available {
            Button(t("Check for Updates…", "Nach Updates suchen …")) { updates.check() }.disabled(!updates.canCheck)
        }
    }
}
