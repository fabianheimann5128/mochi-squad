import Foundation

/// An extra ChatGPT subscription with its own sign-in. The id names its folder in the app data.
struct Account: Codable, Equatable, Identifiable, Hashable {
    let id: String
    var name: String

    /// Id from the name: lowercase letters, digits and hyphens, with a random part against duplicates.
    static func makeID(from name: String) -> String {
        let slug = name.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "-" }
        let base = String(String(slug).split(separator: "-").joined(separator: "-").prefix(24))
        return (base.isEmpty ? "plan" : base) + "-" + String(UUID().uuidString.prefix(4)).lowercased()
    }
}

/// Messengers through which the user reaches the team chat from the phone. Secrets are not stored here:
/// the Telegram bot token lives in the keychain, the WhatsApp session in the app data.
struct Messengers: Codable, Equatable {
    struct Telegram: Codable, Equatable {
        /// Bot user name without "@".
        var bot: String
        /// The only Telegram account that may talk to the bot; nil until pairing is confirmed.
        var userID: Int64?
        var userName: String?
    }
    struct WhatsApp: Codable, Equatable {
        /// Phone number of the linked account; messages are exchanged in its "Message yourself" chat only.
        var number: String
    }
    var telegram: Telegram?
    var whatsapp: WhatsApp?
    /// Project whose team chat the messengers talk to; nil means the first project.
    var project: String?
}

/// The user's settings. They live in settings.json; the Python helpers read the name and language from it.
struct AppSettings: Codable, Equatable {
    var ownerName = ""
    var coordinatorName = "Mochi"
    var projects: [String] = []
    var onboarded = false
    /// Extra ChatGPT subscriptions; nil until one is added.
    var accounts: [Account]?
    /// Interface language; nil means English.
    var language: Language?
    var messengers: Messengers?
    /// Keeps the Mac from going to sleep on its own while the app is open (for a Mac that serves as the agents' computer).
    var alwaysAwake: Bool?

    /// Display name of the user in briefings; a neutral fallback while setup is missing.
    var owner: String { ownerName.trimmingCharacters(in: .whitespaces).isEmpty ? t("the user", "dem Nutzer") : ownerName }
}

@MainActor final class SettingsStore: ObservableObject {
    @Published var value: AppSettings {
        didSet {
            guard value != oldValue else { return }
            L10n.language = value.language ?? .en
            save()
        }
    }
    private let file: URL

    init(file: URL = AppPaths.file("settings.json")) {
        self.file = file
        value = JSONFile.load(AppSettings.self, from: file) ?? AppSettings()
        L10n.language = value.language ?? .en
    }

    var language: Language { value.language ?? .en }

    /// Registered project folders that still exist.
    var projects: [URL] {
        value.projects.map { URL(fileURLWithPath: $0, isDirectory: true) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static var refusedProject: String {
        t("This folder cannot be a project: agents could otherwise reach credentials and system files. Choose a folder inside your home folder.",
          "Dieser Ordner geht als Projekt nicht: Agenten könnten sonst an Zugangsdaten und Systemdateien. Wähle einen Ordner unterhalb deines Benutzerordners.")
    }

    /// Like common.project_allowed: never the home folder itself, nothing above it and nothing in ~/Library.
    static func projectAllowed(_ folder: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let path = folder.standardizedFileURL.resolvingSymlinksInPath().path
        let home = home.standardizedFileURL.resolvingSymlinksInPath().path
        if path == home || (home + "/").hasPrefix(path == "/" ? "/" : path + "/") { return false }
        // Inside the home folder, ~/Library, ~/Applications and hidden folders such as ~/.ssh, ~/.claude or ~/.codex are off limits.
        guard path.hasPrefix(home + "/"), let first = path.dropFirst(home.count + 1).split(separator: "/").first else { return true }
        return first != "Library" && first != "Applications" && !first.hasPrefix(".")
    }

    /// Adds the folder as a project. `false` if it is not allowed as one.
    @discardableResult
    func addProject(_ folder: URL) -> Bool {
        guard Self.projectAllowed(folder) else { return false }
        let path = folder.standardizedFileURL.resolvingSymlinksInPath().path
        if !value.projects.contains(path) { value.projects.append(path) }
        return true
    }

    var accounts: [Account] { value.accounts ?? [] }

    func addAccount(named name: String) -> Account {
        let account = Account(id: Account.makeID(from: name), name: name)
        value.accounts = accounts + [account]
        return account
    }

    /// Removes the subscription together with its sign-in on this Mac.
    func removeAccount(_ account: Account) {
        value.accounts = accounts.filter { $0.id != account.id }
        if let home = AppPaths.accountHome(account.id) { try? FileManager.default.removeItem(at: home) }
    }

    func removeProject(_ folder: URL) {
        value.projects.removeAll { $0 == folder.path }
    }

    var messengers: Messengers {
        get { value.messengers ?? Messengers() }
        set { value.messengers = newValue == Messengers() ? nil : newValue }
    }

    /// The project the messengers talk to: the chosen one if it still exists, otherwise the first.
    var messengerProject: URL? {
        projects.first { $0.path == messengers.project } ?? projects.first
    }

    private func save() {
        SaveGuard.save(t("settings", "Einstellungen")) { [value, file] in try JSONFile.save(value, to: file) }
    }
}
