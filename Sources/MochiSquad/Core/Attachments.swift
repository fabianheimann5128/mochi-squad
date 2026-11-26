import AppKit
import Foundation

/// Dateien, die der Nutzer einer Nachricht anhängt. Sie werden ins Projekt kopiert, weil Agenten nur dort lesen dürfen.
enum Attachments {
    static let folder = ".mochi-squad/anhaenge"
    static let maxBytes = 100 * 1024 * 1024

    enum Failure: LocalizedError {
        case tooLarge(String), unreadable(String)
        var errorDescription: String? {
            switch self {
            case .tooLarge(let name): return "„\(name)“ ist größer als 100 MB und wurde nicht angehängt."
            case .unreadable(let name): return "„\(name)“ konnte nicht kopiert werden."
            }
        }
    }

    /// Kopiert die Dateien nach `<Projekt>/.mochi-squad/anhaenge` und liefert ihre Pfade relativ zum Projekt.
    static func stage(_ files: [URL], in project: URL) throws -> [String] {
        let target = project.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return try files.map { file in
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= maxBytes else { throw Failure.tooLarge(file.lastPathComponent) }
            let copy = freeName(for: file.lastPathComponent, in: target)
            do { try FileManager.default.copyItem(at: file, to: copy) } catch { throw Failure.unreadable(file.lastPathComponent) }
            return folder + "/" + copy.lastPathComponent
        }
    }

    /// Nachricht mit Verweis auf die angehängten Dateien.
    static func message(_ text: String, files: [String]) -> String {
        guard !files.isEmpty else { return text }
        let list = files.map { "- " + $0 }.joined(separator: "\n")
        return (text.isEmpty ? "Sieh dir bitte die angehängten Dateien an." : text) + "\n\n[Anhänge im Projektordner]\n" + list
    }

    /// Erster freier Dateiname: „bild.png“, „bild-2.png“, …
    static func freeName(for name: String, in folder: URL) -> URL {
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name), counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent(base + "-\(counter)" + (ext.isEmpty ? "" : "." + ext))
            counter += 1
        }
        return candidate
    }

    /// Dateiauswahl für Anhänge.
    @MainActor static func choose() -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        panel.prompt = "Anhängen"
        return panel.runModal() == .OK ? panel.urls : []
    }
}

/// Diktat von macOS im gerade aktiven Eingabefeld (wie die Diktiertaste).
enum Dictation {
    @MainActor static func start() { NSApp.sendAction(Selector(("startDictation:")), to: nil, from: nil) }
}
