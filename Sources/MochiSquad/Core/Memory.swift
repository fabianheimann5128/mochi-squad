import CryptoKit
import Darwin
import Foundation

/// Where an entry came from. The app writes it at the end of the entry's line as an Obsidian comment, which
/// Obsidian hides in its reading view: "%%mochi:1 agent=<id> reach=fc from=<project>%%" or "%%mochi:1 user%%".
/// scripts/memory.py reads the same format; both readers must stay alike.
struct MemorySource: Equatable {
    /// Typed by the user in the app.
    var user = false
    /// The stable id of the agent that saved it.
    var agent: String?
    /// What that agent's session could do when it saved: f full access, c computer use, x coordinator.
    var reach = ""
    /// The project the agent worked in, as a short hash of its folder.
    var from: String?
    /// Confirmed by the user: every agent may get it.
    var confirmed = false

    static let prefix = "%%mochi:1"

    var marker: String {
        var parts = [Self.prefix]
        if user { parts.append("user") }
        if let agent { parts += ["agent=" + agent, "reach=" + (reach.isEmpty ? "-" : reach)] }
        if let from { parts.append("from=" + from) }
        if confirmed { parts.append("ok") }
        return parts.joined(separator: " ") + "%%"
    }

    /// nil when the marker is not exactly in the form the app writes.
    static func parse(_ marker: String) -> MemorySource? {
        guard marker.hasPrefix(prefix + " "), marker.hasSuffix("%%"), marker.count > prefix.count + 3 else { return nil }
        var source = MemorySource(), seen = Set<String>()
        for token in marker.dropFirst(prefix.count + 1).dropLast(2).split(separator: " ").map(String.init) {
            let key = String(token.prefix { $0 != "=" })
            guard seen.insert(key).inserted else { return nil }
            let value = String(token.dropFirst(key.count + 1))
            switch key {
            case "user" where token == key: source.user = true
            case "ok" where token == key: source.confirmed = true
            case "agent" where UUID(uuidString: value) != nil: source.agent = value.uppercased()
            case "reach" where value == "-" || (!value.isEmpty && Set(value).count == value.count && value.allSatisfy { "fcx".contains($0) }):
                source.reach = value == "-" ? "" : value
            case "from" where value.count == 16 && value.allSatisfy(\.isHexDigit): source.from = value.lowercased()
            default: return nil
            }
        }
        // Exactly one of the two, and an agent always with its reach.
        guard source.user != (source.agent != nil), source.agent == nil || seen.contains("reach") else { return nil }
        return source
    }

    /// The short, stable key of a project folder: the same as `project_key` in scripts/memory.py.
    static func key(of project: String) -> String {
        var resolved = project
        if let real = realpath(project, nil) { resolved = String(cString: real); free(real) }
        return SHA256.hash(data: Data(resolved.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// One line of Mochi Memory: a fact, who saved it and when (empty for lines the user wrote).
struct MemoryEntry: Identifiable, Equatable {
    let note: URL
    /// Line in its note; stable until the note changes.
    let line: Int
    var text: String
    var author: String?
    var date: String?
    /// The app's marker; nil for a line without one.
    var source: MemorySource?
    /// A marker was there but not in the app's form: where the line came from is unknown.
    var broken = false

    var id: String { note.path + "#\(line)" }
    /// The user's own: typed in the app, or written by hand without a byline.
    var byUser: Bool { source?.user == true || (source == nil && !broken && author == nil) }
    /// From an agent (or of unknown origin) and not confirmed by the user yet. Agents with more rights than its
    /// author, and agents of other projects for facts about the user, get it only once it is confirmed.
    var unconfirmed: Bool { !byUser && source?.confirmed != true }
}

/// A note of Mochi Memory: one about the user, or one per project.
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
    static let profileIntro = "What your agents remember about you. You can change or delete any line."
    static let projectIntro = "What the team remembers about this project. About the person: [[\(profileTitle)]]"

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
        let fresh = Self.markdown(in: folder).compactMap(Self.read)
        if fresh != notes { notes = fresh }
    }

    var profile: MemoryNote? { notes.first { $0.kind == .profile } }
    func note(for project: String) -> MemoryNote? { notes.first { $0.project == project } }

    /// Everything about the user (nil) or a project, from every note about it: the app shows what agents get.
    func entries(for project: String?) -> [MemoryEntry] {
        notes.filter { project == nil ? $0.kind == .profile : $0.project == project }.flatMap(\.entries)
    }

    /// Saves a fact in the project's note, or in the note about the user. Returns the note it went into.
    @discardableResult
    func remember(_ raw: String, project: String?, author: String, source: MemorySource, date: Date = Date()) throws -> MemoryNote {
        let text = Self.clean(raw)
        guard !text.isEmpty else { throw Failure.empty }
        guard text.count <= Self.maxEntry else { throw Failure.tooLong }
        guard !Self.looksSecret(text) else { throw Failure.secret }
        // The folder may have changed outside the app (Obsidian): look again before choosing or creating a note.
        reload()
        guard !entries(for: project).contains(where: { $0.text.caseInsensitiveCompare(text) == .orderedSame }) else { throw Failure.duplicate }
        let url = try ensureNote(project: project)
        let data = try Self.data(of: url)
        guard Self.note(from: data, at: url) != nil else { throw Failure.changed }
        var lines = Self.lines(of: data)
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        let day = date.formatted(.iso8601.year().month().day())
        let name = author.replacingOccurrences(of: "·", with: "").replacingOccurrences(of: "%%", with: "%").trimmingCharacters(in: .whitespaces)
        lines.append("- " + text + " · " + (name.isEmpty ? "Agent" : name) + " · " + day + " " + source.marker)
        try Self.write(lines.joined(separator: "\n") + "\n", to: url, replacing: data)
        reload()
        guard let note = Self.read(url) else { throw Failure.changed }
        return note
    }

    /// Changes or removes (nil) one entry; the rest of the note stays exactly as it was. A fact the user corrects
    /// counts as confirmed by them.
    func edit(_ entry: MemoryEntry, to text: String?) throws {
        if let text {
            let cleaned = Self.clean(text)
            if !cleaned.isEmpty {
                guard cleaned.count <= Self.maxEntry else { throw Failure.tooLong }
                guard !Self.looksSecret(cleaned) else { throw Failure.secret }
                return try change(entry, to: Self.line(entry, text: cleaned, confirmed: true))
            }
        }
        try change(entry, to: nil)
    }

    /// The user vouches for a fact an agent saved: from now on every agent may get it.
    func confirm(_ entry: MemoryEntry) throws {
        try change(entry, to: Self.line(entry, text: entry.text, confirmed: true))
    }

    /// Finds the entry by its line and everything the line says (text, byline, date and marker), only below the
    /// note's properties. If the note changed meanwhile and that line is not there exactly once, nothing happens.
    private func change(_ entry: MemoryEntry, to replacement: String?) throws {
        let data = try Self.data(of: entry.note)
        var lines = Self.lines(of: data)
        let body = Self.frontMatter(lines).body
        func same(_ index: Int) -> Bool {
            guard index >= body, index < lines.count, let found = Self.parse(line: lines[index], index: index, note: entry.note) else { return false }
            return found.text == entry.text && found.author == entry.author && found.date == entry.date
                && found.source == entry.source && found.broken == entry.broken
        }
        var index = entry.line
        if !same(index) {
            let found = lines.indices.filter(same)
            guard found.count == 1 else { reload(); throw Failure.changed }
            index = found[0]
        }
        if let replacement { lines[index] = replacement } else { lines.remove(at: index) }
        try Self.write(lines.joined(separator: "\n"), to: entry.note, replacing: data)
        reload()
    }

    private static func line(_ entry: MemoryEntry, text: String, confirmed: Bool) -> String {
        var source = entry.source
        if confirmed, !entry.byUser {
            // An agent's fact keeps its origin and is marked confirmed; one of unknown origin becomes the user's.
            if source?.agent != nil { source?.confirmed = true } else { source = MemorySource(user: true) }
        }
        let trailer = [entry.author, entry.date].compactMap { $0 }.joined(separator: " · ")
        return "- " + text + (trailer.isEmpty ? "" : " · " + trailer) + (source.map { " " + $0.marker } ?? "")
    }

    // MARK: Moving to another folder

    struct Move: Equatable {
        /// The memory now lives in the new folder.
        var switched: Bool
        /// Notes that could not be moved or that changed while moving; they stay in the old folder.
        var stayed: [String]
    }

    /// Moves the memory to another folder. Only Mochi notes move; other Markdown files stay where they are. A note
    /// that exists in both places is merged when it holds nothing but what the app writes; otherwise both are kept
    /// whole, the moved one under a free name. Everything is written to the new folder first: if any of that fails,
    /// all of it is undone and the memory stays where it was. Only then are the old notes removed.
    func move(to target: URL) -> Move {
        let fm = FileManager.default
        try? fm.createDirectory(at: target, withIntermediateDirectories: true)
        // The same folder under another path (a link): nothing to move.
        if Self.sameItem(target, folder) {
            use(target)
            return Move(switched: true, stayed: [])
        }
        struct Planned { var url: URL; var data: Data; var original: Data?; var note: MemoryNote }
        var targets = Self.markdown(in: target).compactMap { url -> Planned? in
            guard let data = AppPaths.readSmallFile(url, limit: Self.maxNote), let note = Self.note(from: data, at: url) else { return nil }
            return Planned(url: url, data: data, original: data, note: note)
        }
        var taken = Set(((try? fm.contentsOfDirectory(atPath: target.resolvingSymlinksInPath().path)) ?? []).map { $0.lowercased() })
        var sources = [(url: URL, data: Data)]()
        for file in Self.markdown(in: folder) {
            guard let data = AppPaths.readSmallFile(file, limit: Self.maxNote), let note = Self.note(from: data, at: file),
                  !targets.contains(where: { Self.sameItem($0.url, file) }) else { continue }
            sources.append((file, data))
            let twin = targets.firstIndex { $0.note.kind == note.kind && (note.kind == .profile || $0.note.project == note.project) }
            if let twin, Self.onlyEntries(data) {
                var lines = Self.lines(of: targets[twin].data)
                while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
                let known = Set(targets[twin].note.entries.map { $0.text.lowercased() })
                let source = Self.lines(of: data)
                lines += note.entries.filter { !known.contains($0.text.lowercased()) }.map { source[$0.line] }
                let merged = Data((lines.joined(separator: "\n") + "\n").utf8)
                if merged.count <= Self.maxNote, let mergedNote = Self.note(from: merged, at: targets[twin].url) {
                    targets[twin].data = merged
                    targets[twin].note = mergedNote
                    continue
                }
            }
            // Kept whole under a free name.
            let stem = file.deletingPathExtension().lastPathComponent
            var name = file.lastPathComponent, number = 2
            while taken.contains(name.lowercased()) { name = stem + " \(number).md"; number += 1 }
            taken.insert(name.lowercased())
            let url = target.appendingPathComponent(name)
            targets.append(Planned(url: url, data: data, original: nil, note: Self.note(from: data, at: url) ?? note))
        }
        // Write everything; on the first failure undo what was written.
        var written = [Planned]()
        for planned in targets where planned.data != planned.original {
            do {
                if let original = planned.original {
                    try Self.write(planned.data, to: planned.url, replacing: original)
                } else {
                    try planned.data.write(to: planned.url, options: .withoutOverwriting)
                }
                written.append(planned)
            } catch {
                for done in written.reversed() {
                    if let original = done.original { try? original.write(to: done.url, options: .atomic) } else { try? fm.removeItem(at: done.url) }
                }
                return Move(switched: false, stayed: sources.map(\.url.lastPathComponent))
            }
        }
        // Everything is in the new folder. A note changed meanwhile stays where it is, so the change is not lost.
        var stayed = [String]()
        for source in sources {
            let now = AppPaths.readSmallFile(source.url, limit: Self.maxNote)
            if now != source.data || (try? fm.removeItem(at: source.url)) == nil { stayed.append(source.url.lastPathComponent) }
        }
        use(target)
        return Move(switched: true, stayed: stayed)
    }

    /// True when a note holds only what the app writes itself: its two properties, title, intro, entries and blank
    /// lines. Such a note can be merged into another without losing anything.
    static func onlyEntries(_ data: Data) -> Bool {
        let lines = lines(of: data)
        let head = frontMatter(lines)
        guard head.body >= 2 else { return false }
        // Every property line is one of the app's own: no lists, no nested values, no other properties.
        guard lines[1..<(head.body - 1)].allSatisfy({ line in
            line.trimmingCharacters(in: .whitespaces).isEmpty
                || (!line.hasPrefix(" ") && !line.hasPrefix("\t") && ["mochi", "project"].contains(line.prefix { $0 != ":" }.lowercased()))
        }) else { return false }
        return lines[head.body...].allSatisfy { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty || trimmed.hasPrefix("# ") || trimmed == profileIntro || trimmed == projectIntro
                || parse(line: line, index: 0) != nil
        }
    }

    /// The same file system object, also when reached by different paths (links, a second mount point).
    static func sameItem(_ a: URL, _ b: URL) -> Bool {
        func real(_ url: URL) -> String {
            guard let resolved = realpath(url.path, nil) else { return url.standardizedFileURL.path }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let left = real(a), right = real(b)
        if left == right { return true }
        let key = URLResourceKey.fileResourceIdentifierKey
        guard let one = (try? URL(fileURLWithPath: left).resourceValues(forKeys: [key]))?.fileResourceIdentifier as? NSObject,
              let two = (try? URL(fileURLWithPath: right).resourceValues(forKeys: [key]))?.fileResourceIdentifier else { return false }
        return one.isEqual(two)
    }

    // MARK: Files

    /// The Markdown files directly in a folder; the folder itself may be a link (to a vault elsewhere).
    static func markdown(in folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder.resolvingSymlinksInPath(), includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "md" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func data(of url: URL) throws -> Data {
        guard let data = AppPaths.readSmallFile(url, limit: maxNote) else { throw Failure.changed }
        return data
    }

    static func lines(of data: Data) -> [String] {
        String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    }

    /// One line, without line breaks or the app's comment markers.
    private static func clean(_ raw: String) -> String {
        raw.components(separatedBy: .newlines).joined(separator: " ").replacingOccurrences(of: "%%", with: "%")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
        let head = project.map { "---\nmochi: project\nproject: \(Self.quoted($0))\n---\n# \(Self.fileName(title))\n\n\(Self.projectIntro)\n\n" }
            ?? "---\nmochi: profile\n---\n# \(Self.profileTitle)\n\n\(Self.profileIntro)\n\n"
        do { try Data(head.utf8).write(to: url, options: .withoutOverwriting) } catch { throw Failure.unwritable }
        return url
    }

    /// Writes a note only if it still holds what was read (`replacing`), so a change made elsewhere meanwhile is
    /// never overwritten.
    private static func write(_ text: String, to url: URL, replacing original: Data) throws {
        try write(Data(text.utf8), to: url, replacing: original)
    }

    private static func write(_ data: Data, to url: URL, replacing original: Data) throws {
        guard data.count <= maxNote else { throw Failure.full }
        guard AppPaths.readSmallFile(url, limit: maxNote) == original else { throw Failure.changed }
        do { try data.write(to: url, options: .atomic) } catch { throw Failure.unwritable }
    }

    /// A YAML string in double quotes. Backslashes, quotes and every control character (line breaks too) are
    /// escaped, so any folder name comes back exactly as it was.
    static func quoted(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F { result += String(format: "\\u%04X", scalar.value) } else { result.unicodeScalars.append(scalar) }
            }
        }
        return result + "\""
    }

    /// The value of a property: one pair of outer quotes is removed and the escapes of `quoted` are undone.
    static func unquoted(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" else { return value }
        let inner = String(value.dropFirst().dropLast())
        guard first == "\"" else { return inner.replacingOccurrences(of: "''", with: "'") }
        var result = String.UnicodeScalarView()
        var scalars = inner.unicodeScalars.makeIterator()
        while let scalar = scalars.next() {
            guard scalar == "\\", let next = scalars.next() else { result.append(scalar); continue }
            switch next {
            case "n": result.append("\n")
            case "r": result.append("\r")
            case "t": result.append("\t")
            case "0": result.append("\0")
            case "u", "x":
                var hex = ""
                for _ in 0..<(next == "u" ? 4 : 2) { if let digit = scalars.next() { hex.unicodeScalars.append(digit) } }
                if let code = UInt32(hex, radix: 16), let decoded = Unicode.Scalar(code) { result.append(decoded) } else { result.append(contentsOf: hex.unicodeScalars) }
            default: result.append(next)
            }
        }
        return String(result)
    }

    static func fileName(_ title: String) -> String {
        let cleaned = title.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|#^[]")).joined(separator: " ")
            .components(separatedBy: .controlCharacters).joined(separator: " ")
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

    /// The top-level properties of a note and the line its body starts at. Indented lines and list items belong to
    /// a property above them and are never read as properties of their own (the same rule as scripts/memory.py).
    static func frontMatter(_ lines: [String]) -> (props: [String: String], body: Int) {
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return ([:], 0) }
        var props = [String: String]()
        for line in lines[1..<end] where !line.hasPrefix(" ") && !line.hasPrefix("\t") && !line.hasPrefix("-") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            if !key.isEmpty { props[key] = unquoted(String(line[line.index(after: colon)...])) }
        }
        return (props, end + 1)
    }

    static func read(_ url: URL) -> MemoryNote? {
        guard let data = AppPaths.readSmallFile(url, limit: maxNote) else { return nil }
        return note(from: data, at: url)
    }

    static func note(from data: Data, at url: URL) -> MemoryNote? {
        guard String(data: data, encoding: .utf8) != nil else { return nil }
        let lines = lines(of: data)
        let head = frontMatter(lines)
        let kind: MemoryNote.Kind
        switch head.props["mochi"] {
        case "profile": kind = .profile
        case "project" where !(head.props["project"] ?? "").isEmpty: kind = .project
        default: return nil
        }
        let title = lines.dropFirst(head.body).first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
            ?? url.deletingPathExtension().lastPathComponent
        let entries = lines.enumerated().dropFirst(head.body).compactMap { parse(line: $0.element, index: $0.offset, note: url) }
        return MemoryNote(url: url, kind: kind, title: title, project: kind == .project ? head.props["project"] : nil, entries: entries)
    }

    /// "- text · author · 2026-11-27 %%mochi:1 …%%", or any other bullet the user wrote. Links ("- [[…]]") are not
    /// entries. Only a marker at the very end of the line counts, so a fact cannot bring its own.
    static func parse(line: String, index: Int, note: URL = URL(fileURLWithPath: "/")) -> MemoryEntry? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") else { return nil }
        var body = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        var source: MemorySource?, broken = false
        if body.hasSuffix("%%"), let start = body.range(of: "%%mochi", options: .backwards) {
            source = MemorySource.parse(String(body[start.lowerBound...]))
            broken = source == nil
            body = String(body[..<start.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        guard !body.isEmpty, !body.hasPrefix("[[") else { return nil }
        let parts = body.components(separatedBy: " · ")
        if parts.count >= 3, let day = parts.last, day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
            let author = parts[parts.count - 2].trimmingCharacters(in: .whitespaces)
            return MemoryEntry(note: note, line: index, text: parts.dropLast(2).joined(separator: " · "), author: author.isEmpty ? nil : author,
                               date: day, source: source, broken: broken || author.isEmpty)
        }
        return MemoryEntry(note: note, line: index, text: body, author: nil, date: nil, source: source, broken: broken)
    }
}
