import AppKit
import Foundation

/// Files the user attaches to a message. They are copied into the project because agents may only read there.
enum Attachments {
    static let folder = ".mochi-squad/attachments"
    /// Folder used by earlier versions; its files stay readable in old chats.
    static let legacyFolder = ".mochi-squad/anhaenge"
    static let maxBytes = 100 * 1024 * 1024

    enum Failure: LocalizedError {
        case tooLarge(String), unreadable(String), unsafeFolder, readOnly
        var errorDescription: String? {
            switch self {
            case .tooLarge(let name): return t("“\(name)” is larger than 100 MB and was not attached.", "„\(name)“ ist größer als 100 MB und wurde nicht angehängt.")
            case .unreadable(let name): return t("“\(name)” could not be copied.", "„\(name)“ konnte nicht kopiert werden.")
            case .unsafeFolder: return t("The project's attachment folder points outside the project. The files were not attached.",
                                         "Der Anhang-Ordner des Projekts verweist nach außen. Die Dateien wurden nicht angehängt.")
            case .readOnly: return t("This project is read-only, so files cannot be attached. Your text can still be sent.",
                                     "Dieses Projekt ist schreibgeschützt, deshalb lassen sich keine Dateien anhängen. Deinen Text kannst du trotzdem senden.")
            }
        }
    }

    /// Copies the files to `<project>/.mochi-squad/attachments` and returns their paths relative to the project.
    /// Without files nothing is created, so plain text also works in a read-only project. If one file fails,
    /// the copies made so far are removed again: nothing of an unsent message stays in the shared project.
    static func stage(_ files: [URL], in project: URL) throws -> [String] {
        guard !files.isEmpty else { return [] }
        let fm = FileManager.default
        let target = project.appendingPathComponent(folder, isDirectory: true)
        // An agent could have replaced the folder or its parent with a link; check before creating anything through it.
        let parent = target.deletingLastPathComponent()
        if fm.fileExists(atPath: parent.path), !inside(parent, project) { throw Failure.unsafeFolder }
        do { try fm.createDirectory(at: target, withIntermediateDirectories: true) } catch { throw Failure.readOnly }
        guard inside(target, project) else { throw Failure.unsafeFolder }
        var copies = [URL]()
        do {
            return try files.map { file in
                let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values?.isRegularFile == true else { throw Failure.unreadable(file.lastPathComponent) }
                guard (values?.fileSize ?? 0) <= maxBytes else { throw Failure.tooLarge(file.lastPathComponent) }
                let copy = freeName(for: file.lastPathComponent, in: target)
                do { try fm.copyItem(at: file, to: copy) } catch { throw Failure.unreadable(file.lastPathComponent) }
                copies.append(copy)
                return folder + "/" + copy.lastPathComponent
            }
        } catch {
            copies.forEach { try? fm.removeItem(at: $0) }
            throw error
        }
    }

    /// Message with a reference to the attached files.
    static func message(_ text: String, files: [String]) -> String {
        guard !files.isEmpty else { return text }
        let list = files.map { "- " + $0 }.joined(separator: "\n")
        return (text.isEmpty ? t("Please have a look at the attached files.", "Sieh dir bitte die angehängten Dateien an.") : text) + marker + list
    }

    static let marker = "\n\n[Attachments in the project folder]\n"
    static let legacyMarker = "\n\n[Anhänge im Projektordner]\n"

    /// Splits a sent message back into text and attached files (paths relative to the project).
    static func split(_ message: String) -> (text: String, files: [String]) {
        guard let cut = [marker, legacyMarker].lazy.compactMap({ message.range(of: $0, options: .backwards) }).first else { return (message, []) }
        let rows = message[cut.upperBound...].split(separator: "\n").map(String.init)
        guard !rows.isEmpty, rows.allSatisfy({ $0.hasPrefix("- ") }) else { return (message, []) }
        return (String(message[..<cut.lowerBound]), rows.map { String($0.dropFirst(2)) })
    }

    /// Is `file` inside `folder` after resolving all links?
    static func inside(_ file: URL, _ folder: URL) -> Bool {
        let base = folder.standardizedFileURL.resolvingSymlinksInPath().path
        return file.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(base + "/")
    }

    /// File of an attachment in the project. nil for anything that is not really in the attachment folder:
    /// the paths come from message text and are therefore not trustworthy. The folder itself must lie inside the
    /// project too, or a link in its place would make any file on the Mac look like an attachment.
    static func resolve(_ relative: String, in project: URL) -> URL? {
        guard let base = [folder, legacyFolder].first(where: { relative.hasPrefix($0 + "/") }), !relative.contains("..") else { return nil }
        let file = project.appendingPathComponent(relative), home = project.appendingPathComponent(base, isDirectory: true)
        return inside(home, project) && inside(file, home) && inside(file, project) ? file : nil
    }

    static func isImage(_ file: URL) -> Bool {
        ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp"].contains(file.pathExtension.lowercased())
    }

    /// First free file name: "image.png", "image-2.png", …
    static func freeName(for name: String, in folder: URL) -> URL {
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name), counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent(base + "-\(counter)" + (ext.isEmpty ? "" : "." + ext))
            counter += 1
        }
        return candidate
    }

    /// File picker for attachments.
    @MainActor static func choose() -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        panel.prompt = t("Attach", "Anhängen")
        return panel.runModal() == .OK ? panel.urls : []
    }
}
