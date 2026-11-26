import AppKit
import Foundation

/// Dateien, die der Nutzer einer Nachricht anhängt. Sie werden ins Projekt kopiert, weil Agenten nur dort lesen dürfen.
enum Attachments {
    static let folder = ".mochi-squad/anhaenge"
    static let maxBytes = 100 * 1024 * 1024

    enum Failure: LocalizedError {
        case tooLarge(String), unreadable(String), unsafeFolder
        var errorDescription: String? {
            switch self {
            case .tooLarge(let name): return "„\(name)“ ist größer als 100 MB und wurde nicht angehängt."
            case .unreadable(let name): return "„\(name)“ konnte nicht kopiert werden."
            case .unsafeFolder: return "Der Anhang-Ordner des Projekts verweist nach außen. Die Dateien wurden nicht angehängt."
            }
        }
    }

    /// Kopiert die Dateien nach `<Projekt>/.mochi-squad/anhaenge` und liefert ihre Pfade relativ zum Projekt.
    static func stage(_ files: [URL], in project: URL) throws -> [String] {
        let target = project.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        // Ein Agent könnte den Ordner durch einen Verweis ersetzt haben; kopiert wird nur innerhalb des Projekts.
        guard inside(target, project) else { throw Failure.unsafeFolder }
        return try files.map { file in
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { throw Failure.unreadable(file.lastPathComponent) }
            guard (values?.fileSize ?? 0) <= maxBytes else { throw Failure.tooLarge(file.lastPathComponent) }
            let copy = freeName(for: file.lastPathComponent, in: target)
            do { try FileManager.default.copyItem(at: file, to: copy) } catch { throw Failure.unreadable(file.lastPathComponent) }
            return folder + "/" + copy.lastPathComponent
        }
    }

    /// Nachricht mit Verweis auf die angehängten Dateien.
    static func message(_ text: String, files: [String]) -> String {
        guard !files.isEmpty else { return text }
        let list = files.map { "- " + $0 }.joined(separator: "\n")
        return (text.isEmpty ? "Sieh dir bitte die angehängten Dateien an." : text) + marker + list
    }

    static let marker = "\n\n[Anhänge im Projektordner]\n"

    /// Zerlegt eine gesendete Nachricht wieder in Text und angehängte Dateien (Pfade relativ zum Projekt).
    static func split(_ message: String) -> (text: String, files: [String]) {
        guard let cut = message.range(of: marker, options: .backwards) else { return (message, []) }
        let rows = message[cut.upperBound...].split(separator: "\n").map(String.init)
        guard !rows.isEmpty, rows.allSatisfy({ $0.hasPrefix("- ") }) else { return (message, []) }
        return (String(message[..<cut.lowerBound]), rows.map { String($0.dropFirst(2)) })
    }

    /// Liegt `file` nach dem Auflösen aller Verweise in `folder`?
    static func inside(_ file: URL, _ folder: URL) -> Bool {
        let base = folder.standardizedFileURL.resolvingSymlinksInPath().path
        return file.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(base + "/")
    }

    /// Datei eines Anhangs im Projekt. nil für alles, was nicht wirklich im Anhang-Ordner liegt:
    /// Die Pfade stammen aus Nachrichtentext und sind damit nicht vertrauenswürdig.
    static func resolve(_ relative: String, in project: URL) -> URL? {
        guard relative.hasPrefix(folder + "/"), !relative.contains("..") else { return nil }
        let file = project.appendingPathComponent(relative)
        return inside(file, project.appendingPathComponent(folder, isDirectory: true)) ? file : nil
    }

    static func isImage(_ file: URL) -> Bool {
        ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp"].contains(file.pathExtension.lowercased())
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
