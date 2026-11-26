import Foundation

/// Ein weiteres ChatGPT-Abo mit eigener Anmeldung. Die Kennung benennt seinen Ordner in den App-Daten.
struct Account: Codable, Equatable, Identifiable, Hashable {
    let id: String
    var name: String

    /// Kennung aus dem Namen: Kleinbuchstaben, Ziffern und Bindestriche, mit Zufallsteil gegen Doppelte.
    static func makeID(from name: String) -> String {
        let slug = name.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "-" }
        let base = String(String(slug).split(separator: "-").joined(separator: "-").prefix(24))
        return (base.isEmpty ? "abo" : base) + "-" + String(UUID().uuidString.prefix(4)).lowercased()
    }
}

/// Einstellungen des Nutzers. Liegen in settings.json; die Python-Helfer lesen davon nur den Namen.
struct AppSettings: Codable, Equatable {
    var ownerName = ""
    var coordinatorName = "Mochi"
    var projects: [String] = []
    var onboarded = false
    /// Weitere ChatGPT-Abos; nil, solange keines angelegt wurde.
    var accounts: [Account]?

    /// Anzeigename des Nutzers in Briefings; leer, solange die Einrichtung fehlt.
    var owner: String { ownerName.trimmingCharacters(in: .whitespaces).isEmpty ? "dem Nutzer" : ownerName }
}

@MainActor final class SettingsStore: ObservableObject {
    @Published var value: AppSettings { didSet { if value != oldValue { save() } } }
    private let file: URL

    init(file: URL = AppPaths.file("settings.json")) {
        self.file = file
        value = JSONFile.load(AppSettings.self, from: file) ?? AppSettings()
    }

    /// Registrierte Projektordner, die es noch gibt.
    var projects: [URL] {
        value.projects.map { URL(fileURLWithPath: $0, isDirectory: true) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static let refusedProject = "Dieser Ordner geht als Projekt nicht: Agenten könnten sonst an Zugangsdaten und Systemdateien. Wähle einen Ordner unterhalb deines Benutzerordners."

    /// Wie common.project_allowed: nie der Benutzerordner selbst, nichts darüber und nichts in ~/Library.
    static func projectAllowed(_ folder: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let path = folder.standardizedFileURL.resolvingSymlinksInPath().path
        let home = home.standardizedFileURL.resolvingSymlinksInPath().path
        if path == home || (home + "/").hasPrefix(path == "/" ? "/" : path + "/") { return false }
        // Im Benutzerordner sind ~/Library, ~/Applications und versteckte Ordner wie ~/.ssh, ~/.claude oder ~/.codex tabu.
        guard path.hasPrefix(home + "/"), let first = path.dropFirst(home.count + 1).split(separator: "/").first else { return true }
        return first != "Library" && first != "Applications" && !first.hasPrefix(".")
    }

    /// Nimmt den Ordner als Projekt auf. `false`, wenn er als Projekt nicht erlaubt ist.
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

    /// Entfernt das Abo samt seiner Anmeldung auf diesem Mac.
    func removeAccount(_ account: Account) {
        value.accounts = accounts.filter { $0.id != account.id }
        if let home = AppPaths.accountHome(account.id) { try? FileManager.default.removeItem(at: home) }
    }

    func removeProject(_ folder: URL) {
        value.projects.removeAll { $0 == folder.path }
    }

    private func save() {
        try? JSONFile.save(value, to: file)
    }
}
