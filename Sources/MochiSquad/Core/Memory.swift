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
        case empty, tooLong, secret, duplicate, unwritable, full, changed
        var errorDescription: String? {
            switch self {
            case .empty: return t("There is nothing to remember.", "Es gibt nichts zu merken.")
            case .tooLong: return t("Too long for one entry: save one short sentence (at most \(MemoryStore.maxEntry) characters).",
                                    "Zu lang für einen Eintrag: speichere einen kurzen Satz (höchstens \(MemoryStore.maxEntry) Zeichen).")
            case .secret: return t("This looks like a password, key or token. Mochi Memory does not keep things like that.",
                                   "Das sieht nach einem Passwort, Schlüssel oder Token aus. So etwas behält Mochi Memory nicht.")
            case .duplicate: return t("This is already in memory.", "Das steht schon im Gedächtnis.")
            case .unwritable: return t("The memory folder cannot be written.", "In den Gedächtnis-Ordner kann nicht geschrieben werden.")
            case .full: return t("This note is full. Tidy it up first, or start a new note in Obsidian.", "Diese Notiz ist voll. Räum sie erst auf.")
            case .changed: return t("The note was changed elsewhere in the meantime. Look again and try once more.",
                                    "Die Notiz wurde zwischendurch woanders geändert. Schau noch einmal und versuch es erneut.")
            }
        }
    }

    /// Longest entry: the same limit for saving and for the briefing.
    nonisolated static let maxEntry = 400
    /// Largest note that is read or written.
    nonisolated static let maxNote = 512 * 1024

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

    /// Saves a fact in the project's note, or in the note about the user. Returns the note it went into.
    @discardableResult
    func remember(_ raw: String, project: String?, author: String, date: Date = Date()) throws -> MemoryNote {
        let text = raw.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Failure.empty }
        guard text.count <= Self.maxEntry else { throw Failure.tooLong }
        guard !Self.looksSecret(text) else { throw Failure.secret }
        // The folder may have changed outside the app (Obsidian): look again before choosing or creating a note.
        reload()
        let url = try ensureNote(project: project)
        guard let current = Self.read(url) else { throw Failure.changed }
        guard !current.entries.contains(where: { $0.text.caseInsensitiveCompare(text) == .orderedSame }) else { throw Failure.duplicate }
        var lines = try Self.lines(of: url)
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        let day = date.formatted(.iso8601.year().month().day())
        lines.append("- " + text + " · " + author.replacingOccurrences(of: "·", with: "").trimmingCharacters(in: .whitespaces) + " · " + day)
        try write(lines.joined(separator: "\n") + "\n", to: url)
        reload()
        guard let note = Self.read(url) else { throw Failure.changed }
        return note
    }

    /// Changes or removes (nil) one entry; the rest of the note stays exactly as it was. The entry is found by its
    /// line and its text: if the note changed meanwhile and the text is no longer there exactly once, nothing happens.
    func edit(_ entry: MemoryEntry, in note: MemoryNote, to text: String?) throws {
        var lines = try Self.lines(of: note.url)
        let matches = { (index: Int) in Self.parse(line: lines[index], index: index).map { $0.text == entry.text && $0.author == entry.author } ?? false }
        var index = entry.id
        if !(index < lines.count && matches(index)) {
            let found = lines.indices.filter(matches)
            guard found.count == 1 else { reload(); throw Failure.changed }
            index = found[0]
        }
        if let text = text?.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            guard text.count <= Self.maxEntry else { throw Failure.tooLong }
            guard !Self.looksSecret(text) else { throw Failure.secret }
            let trailer = [entry.author, entry.date].compactMap { $0 }.joined(separator: " · ")
            lines[index] = "- " + text + (trailer.isEmpty ? "" : " · " + trailer)
        } else {
            lines.remove(at: index)
        }
        try write(lines.joined(separator: "\n"), to: note.url)
        reload()
    }

    /// Moves the memory to another folder. Only Mochi notes move; other Markdown files stay where they are. A note
    /// that exists in both places is merged. Returns the names of notes that could not be moved (they stay behind).
    func move(to target: URL) -> [String] {
        let fm = FileManager.default
        var failed = [String]()
        try? fm.createDirectory(at: target, withIntermediateDirectories: true)
        let sources = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "md" }
        guard target.standardizedFileURL != folder.standardizedFileURL else { return [] }
        let existing = ((try? fm.contentsOfDirectory(at: target, includingPropertiesForKeys: nil)) ?? []).compactMap(Self.read)
        for file in sources {
            guard let note = Self.read(file) else { continue }
            let twin = existing.first { $0.kind == note.kind && (note.kind == .profile || $0.project == note.project) }
            do {
                if let twin {
                    // Merge: the entries the target lacks are added at its end, then the old note goes.
                    var lines = try Self.lines(of: twin.url)
                    while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
                    let known = Set(twin.entries.map { $0.text.lowercased() })
                    let source = try Self.lines(of: file)
                    for entry in note.entries where !known.contains(entry.text.lowercased()) { lines.append(source[entry.id]) }
                    try write(lines.joined(separator: "\n") + "\n", to: twin.url)
                    try fm.removeItem(at: file)
                } else {
                    var destination = target.appendingPathComponent(file.lastPathComponent)
                    var number = 2
                    while fm.fileExists(atPath: destination.path) {
                        destination = target.appendingPathComponent(file.deletingPathExtension().lastPathComponent + " \(number).md"); number += 1
                    }
                    try fm.moveItem(at: file, to: destination)
                }
            } catch {
                failed.append(file.lastPathComponent)
            }
        }
        folder = target
        reload()
        return failed
    }

    static func lines(of url: URL) throws -> [String] {
        guard let data = AppPaths.readSmallFile(url, limit: maxNote), let text = String(data: data, encoding: .utf8) else { throw Failure.changed }
        return text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
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
        let head = project.map { "---\nmochi: project\nproject: \(Self.quoted($0))\n---\n# \(title)\n\nWhat the team remembers about this project. About the person: [[\(Self.profileTitle)]]\n\n" }
            ?? "---\nmochi: profile\n---\n# \(Self.profileTitle)\n\nWhat your agents remember about you. You can change or delete any line.\n\n"
        try write(head, to: url)
        return url
    }

    private func write(_ text: String, to url: URL) throws {
        let data = Data(text.utf8)
        guard data.count <= Self.maxNote else { throw Failure.full }
        do { try data.write(to: url, options: .atomic) } catch { throw Failure.unwritable }
    }

    /// A YAML string in double quotes, with backslashes and quotes escaped.
    static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// The value of a property: one pair of outer quotes is removed and escapes inside double quotes are undone.
    static func unquoted(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" else { return value }
        let inner = String(value.dropFirst().dropLast())
        guard first == "\"" else { return inner.replacingOccurrences(of: "''", with: "'") }
        var result = "", escaped = false
        for character in inner {
            if escaped { result.append(character); escaped = false } else if character == "\\" { escaped = true } else { result.append(character) }
        }
        return result
    }

    static func fileName(_ title: String) -> String {
        let cleaned = title.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|#^[]")).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Project" : String(cleaned.prefix(60))
    }

    /// Passwords, keys and tokens are kept out of memory. This is pattern matching: it catches the usual forms,
    /// not every possible one.
    static func looksSecret(_ text: String) -> Bool {
        let patterns = [#"(?i)\b(password|passwort|kennwort|passwd|pwd|pin|api[_ -]?key|secret|geheimnis|token|zugangsdaten)\b\s*[:=]"#,
                        #"(?i)\b(my|mein|meine|the|das|der|die)\s+(password|passwort|kennwort|pin|api[_ -]?key|token|secret)\s+(is|ist|lautet|=)\b"#,
                        #"-----BEGIN [A-Z ]*(PRIVATE KEY|CERTIFICATE)-----"#,
                        #"\b(sk|pk|rk)-[A-Za-z0-9_-]{16,}"#, #"\bgh[pousr]_[A-Za-z0-9]{20,}"#, #"\bAKIA[0-9A-Z]{16}\b"#,
                        #"\bxox[abposr]-[A-Za-z0-9-]{10,}"#, #"\bAIza[0-9A-Za-z_-]{30,}"#,
                        #"\b\d{8,10}:AA[A-Za-z0-9_-]{30,}"#, #"[A-Za-z0-9+/=_-]{40,}"#]
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    static func read(_ url: URL) -> MemoryNote? {
        guard let data = AppPaths.readSmallFile(url, limit: maxNote), let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var props = [String: String]()
        var bodyStart = 0
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---", let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            for line in lines[1..<end] {
                guard let colon = line.firstIndex(of: ":") else { continue }
                props[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] = unquoted(String(line[line.index(after: colon)...]))
            }
            // Lists in the properties (tags, aliases) are no facts.
            bodyStart = end + 1
        }
        let kind: MemoryNote.Kind
        switch props["mochi"] {
        case "profile": kind = .profile
        case "project": kind = .project
        default: return nil
        }
        let title = lines.first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
            ?? url.deletingPathExtension().lastPathComponent
        let entries = lines.enumerated().dropFirst(bodyStart).compactMap { parse(line: $0.element, index: $0.offset) }
        return MemoryNote(url: url, kind: kind, title: title, project: kind == .project ? props["project"] : nil, entries: entries)
    }

    /// "- text · author · 2026-11-27", or any other bullet the user wrote. Links ("- [[…]]") are not entries.
    static func parse(line: String, index: Int) -> MemoryEntry? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") else { return nil }
        let body = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty, !body.hasPrefix("[[") else { return nil }
        let parts = body.components(separatedBy: " · ")
        if parts.count >= 3, let day = parts.last, day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
            return MemoryEntry(id: index, text: parts.dropLast(2).joined(separator: " · "), author: parts[parts.count - 2], date: day)
        }
        return MemoryEntry(id: index, text: body, author: nil, date: nil)
    }
}
