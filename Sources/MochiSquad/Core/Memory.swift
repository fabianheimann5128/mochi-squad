import Foundation

/// One line of Mochi Memory: a fact, who saved it and when (empty for lines the user wrote).
struct MemoryEntry: Identifiable, Equatable {
    /// Position in its note; stable until the note changes.
    let id: Int
    var text: String
    var author: String?
    var date: String?
}

/// A note of Mochi Memory: the one about the user, or one per project.
struct MemoryNote: Identifiable, Equatable {
    enum Kind: Equatable { case profile, project }
    let url: URL
    let kind: Kind
    let title: String
    /// Project folder for project notes.
    let project: String?
    var entries: [MemoryEntry]
    var id: String { url.path }
}

/// Mochi Memory: plain Markdown notes in a folder the user may open in Obsidian. The app is the only writer on
/// behalf of agents (they ask through their post tool); the user edits freely, in Obsidian or in the app.
@MainActor final class MemoryStore: ObservableObject {
    @Published private(set) var notes = [MemoryNote]()
    @Published private(set) var folder: URL
    static let profileTitle = "About me"

    enum Failure: LocalizedError {
        case empty, tooLong, secret, duplicate, unwritable
        var errorDescription: String? {
            switch self {
            case .empty: return t("There is nothing to remember.", "Es gibt nichts zu merken.")
            case .tooLong: return t("Too long for one entry: save one short sentence.", "Zu lang für einen Eintrag: speichere einen kurzen Satz.")
            case .secret: return t("This looks like a password, key or token. Mochi Memory does not store those.",
                                   "Das sieht nach einem Passwort, Schlüssel oder Token aus. Mochi Memory speichert so etwas nicht.")
            case .duplicate: return t("This is already in memory.", "Das steht schon im Gedächtnis.")
            case .unwritable: return t("The memory folder cannot be written.", "In den Gedächtnis-Ordner kann nicht geschrieben werden.")
            }
        }
    }

    init(folder: URL) {
        self.folder = folder
        reload()
    }

    /// ~/Mochi Memory unless the user chose another folder (for example a folder in their Obsidian vault).
    static func folder(chosen: String?) -> URL {
        if let chosen, chosen.hasPrefix("/") { return URL(fileURLWithPath: chosen, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Mochi Memory", isDirectory: true)
    }

    func use(_ folder: URL) {
        self.folder = folder
        reload()
    }

    func reload() {
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "md" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let fresh = files.compactMap(Self.read)
        if fresh != notes { notes = fresh }
    }

    var profile: MemoryNote? { notes.first { $0.kind == .profile } }
    func note(for project: String) -> MemoryNote? { notes.first { $0.project == project } }

    /// Saves a fact in the project's note, or in the note about the user. Returns the receipt for the agent.
    @discardableResult
    func remember(_ raw: String, project: String?, author: String, date: Date = Date()) throws -> MemoryNote {
        let text = raw.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Failure.empty }
        guard text.count <= 400 else { throw Failure.tooLong }
        guard !Self.looksSecret(text) else { throw Failure.secret }
        let url = try ensureNote(project: project)
        var lines = ((try? String(contentsOf: url, encoding: .utf8)) ?? "").components(separatedBy: "\n")
        let existing = Self.read(url)?.entries ?? []
        guard !existing.contains(where: { $0.text.caseInsensitiveCompare(text) == .orderedSame }) else { throw Failure.duplicate }
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        let day = date.formatted(.iso8601.year().month().day())
        lines.append("- " + text + " · " + author.replacingOccurrences(of: "·", with: "") + " · " + day)
        try write(lines.joined(separator: "\n") + "\n", to: url)
        reload()
        return Self.read(url)!
    }

    /// Changes or removes (nil) one entry; the rest of the note stays exactly as it was.
    func edit(_ entry: MemoryEntry, in note: MemoryNote, to text: String?) throws {
        var lines = ((try? String(contentsOf: note.url, encoding: .utf8)) ?? "").components(separatedBy: "\n")
        guard entry.id < lines.count, Self.parse(line: lines[entry.id], index: entry.id) != nil else { reload(); return }
        if let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            guard !Self.looksSecret(text) else { throw Failure.secret }
            let trailer = [entry.author, entry.date].compactMap { $0 }.joined(separator: " · ")
            lines[entry.id] = "- " + text + (trailer.isEmpty ? "" : " · " + trailer)
        } else {
            lines.remove(at: entry.id)
        }
        try write(lines.joined(separator: "\n"), to: note.url)
        reload()
    }

    /// The note for a project (or the user), created with its properties on first use.
    private func ensureNote(project: String?) throws -> URL {
        if let project, let note = note(for: project) { return note.url }
        if project == nil, let profile { return profile.url }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let title = project.map { URL(fileURLWithPath: $0).lastPathComponent } ?? Self.profileTitle
        var url = folder.appendingPathComponent(Self.fileName(title) + ".md")
        var number = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent(Self.fileName(title) + " \(number).md"); number += 1
        }
        let head = project.map { "---\nmochi: project\nproject: \"\($0)\"\n---\n# \(title)\n\nWhat the team remembers about this project. About the person: [[\(Self.profileTitle)]]\n\n" }
            ?? "---\nmochi: profile\n---\n# \(Self.profileTitle)\n\nWhat your agents remember about you. You can change or delete any line.\n\n"
        try write(head, to: url)
        return url
    }

    private func write(_ text: String, to url: URL) throws {
        do { try Data(text.utf8).write(to: url, options: .atomic) } catch { throw Failure.unwritable }
    }

    static func fileName(_ title: String) -> String {
        let cleaned = title.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|#^[]")).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Project" : String(cleaned.prefix(60))
    }

    /// Passwords, keys and tokens never go into memory.
    static func looksSecret(_ text: String) -> Bool {
        let patterns = [#"(?i)\b(password|passwort|passwd|api[_ -]?key|secret|token)\b\s*[:=]"#,
                        #"\b(sk|pk|rk)-[A-Za-z0-9_-]{16,}"#, #"\bgh[pousr]_[A-Za-z0-9]{20,}"#, #"\bAKIA[0-9A-Z]{16}\b"#,
                        #"\b\d{8,10}:AA[A-Za-z0-9_-]{30,}"#, #"[A-Za-z0-9+/=_-]{40,}"#]
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    static func read(_ url: URL) -> MemoryNote? {
        guard let data = AppPaths.readSmallFile(url, limit: 512 * 1024), let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var props = [String: String]()
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---", let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            for line in lines[1..<end] {
                guard let colon = line.firstIndex(of: ":") else { continue }
                props[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                    line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
        let kind: MemoryNote.Kind
        switch props["mochi"] {
        case "profile": kind = .profile
        case "project": kind = .project
        default: return nil
        }
        let title = lines.first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
            ?? url.deletingPathExtension().lastPathComponent
        let entries = lines.enumerated().compactMap { parse(line: $0.element, index: $0.offset) }
        return MemoryNote(url: url, kind: kind, title: title, project: kind == .project ? props["project"] : nil, entries: entries)
    }

    /// "- text · author · 2026-11-27", or any other bullet the user wrote. Links ("- [[…]]") are not entries.
    static func parse(line: String, index: Int) -> MemoryEntry? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") else { return nil }
        let body = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty, !body.hasPrefix("[[") else { return nil }
        let parts = body.components(separatedBy: " · ")
        if parts.count >= 3, let day = parts.last, day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
            return MemoryEntry(id: index, text: parts.dropLast(2).joined(separator: " · "), author: parts[parts.count - 2], date: day)
        }
        return MemoryEntry(id: index, text: body, author: nil, date: nil)
    }
}
