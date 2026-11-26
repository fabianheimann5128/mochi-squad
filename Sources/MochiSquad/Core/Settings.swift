import Foundation

/// Einstellungen des Nutzers. Liegen in settings.json; die Python-Helfer lesen davon nur den Namen.
struct AppSettings: Codable, Equatable {
    var ownerName = ""
    var coordinatorName = "Mochi"
    var projects: [String] = []
    var onboarded = false

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
        let library = home + "/Library"
        return path != home && !(home + "/").hasPrefix(path == "/" ? "/" : path + "/") && path != library && !path.hasPrefix(library + "/")
    }

    /// Nimmt den Ordner als Projekt auf. `false`, wenn er als Projekt nicht erlaubt ist.
    @discardableResult
    func addProject(_ folder: URL) -> Bool {
        guard Self.projectAllowed(folder) else { return false }
        let path = folder.standardizedFileURL.resolvingSymlinksInPath().path
        if !value.projects.contains(path) { value.projects.append(path) }
        return true
    }

    func removeProject(_ folder: URL) {
        value.projects.removeAll { $0 == folder.path }
    }

    private func save() {
        try? JSONFile.save(value, to: file)
    }
}
