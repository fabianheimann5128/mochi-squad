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

    func addProject(_ folder: URL) {
        let path = folder.standardizedFileURL.resolvingSymlinksInPath().path
        if !value.projects.contains(path) { value.projects.append(path) }
    }

    func removeProject(_ folder: URL) {
        value.projects.removeAll { $0 == folder.path }
    }

    private func save() {
        try? JSONFile.save(value, to: file)
    }
}
