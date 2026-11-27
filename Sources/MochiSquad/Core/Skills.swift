import CryptoKit
import Foundation

/// A skill: a folder with a SKILL.md that tells an agent how to do one kind of work, plus any files it refers to.
struct Skill: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var description: String
    /// The agents that get this skill; nil means every agent.
    var agents: [UUID]?
    /// Folder in Claude Code's or Codex's own skills the skill is linked to; nil for a skill the user added by hand.
    var source: String?
    /// Fingerprint of that folder when it was last copied: a different one means the skill changed there.
    var stamp: String?

    /// "Claude Code", "Codex", or nil for a skill added by hand.
    var origin: String? {
        guard let source else { return nil }
        return source.contains("/.claude/") ? "Claude Code" : "Codex"
    }
}

/// The skill library of Mochi Squad. Skills work the same for Claude Code and Codex agents: the app tells an agent
/// in its briefing which skills it has and where their files are, and the agent reads a skill when a task fits it.
///
/// Three places are involved:
/// - the library in the app data, where imported skills are kept (agents cannot read or change it);
/// - a copy in the shared area, which agents may read but sandboxed agents cannot write;
/// - skills.json, the list with the assignment to agents, read by the launcher for sessions and routines.
@MainActor final class SkillStore: ObservableObject {
    @Published private(set) var skills: [Skill]
    /// Linked skills the user took out; they stay out until the user brings them back.
    @Published private(set) var hidden: [String]
    private let index: URL
    private let library: URL
    private let mirror: URL
    private let hiddenFile: URL

    static let maxBytes = 50 * 1024 * 1024
    static let maxFiles = 2000

    enum Failure: LocalizedError {
        case noSkill, tooLarge, unreadable
        var errorDescription: String? {
            switch self {
            case .noSkill: return t("No skill found there. A skill is a folder (or .zip) with a SKILL.md file that starts with a name and a description.",
                                    "Dort wurde kein Skill gefunden. Ein Skill ist ein Ordner (oder .zip) mit einer Datei SKILL.md, die mit Name und Beschreibung beginnt.")
            case .tooLarge: return t("This skill is larger than 50 MB or has too many files.", "Dieser Skill ist größer als 50 MB oder hat zu viele Dateien.")
            case .unreadable: return t("The skill could not be copied.", "Der Skill konnte nicht kopiert werden.")
            }
        }
    }

    init(index: URL = AppPaths.file("skills.json"), library: URL = AppPaths.folder("skills"),
         mirror: URL = AppPaths.shared.appendingPathComponent("skills", isDirectory: true),
         hidden: URL = AppPaths.file("skills-hidden.json")) {
        self.index = index
        self.library = library
        self.mirror = mirror
        self.hiddenFile = hidden
        skills = JSONFile.load([Skill].self, from: index) ?? []
        self.hidden = JSONFile.load([String].self, from: hidden) ?? []
        // The shared copy lives in a cache folder macOS may clear: bring it back at every launch.
        publish()
    }

    /// Skills an agent has.
    func skills(for agent: Agent) -> [Skill] { skills.filter { $0.agents?.contains(agent.id) ?? true } }

    /// Name and description from the head of a SKILL.md ("---", "name: …", "description: …", "---").
    static func parse(_ text: String) -> (name: String, description: String)? {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return nil }
        var fields = [String: String](), current: String?
        for line in lines[1..<end] {
            if let colon = line.firstIndex(of: ":"), line.first.map({ !$0.isWhitespace }) == true {
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
                fields[key] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                current = key
            } else if let key = current {
                // A long description may continue on indented lines.
                fields[key] = ((fields[key] ?? "") + " " + line.trimmingCharacters(in: .whitespaces)).trimmingCharacters(in: .whitespaces)
            }
        }
        func clean(_ value: String?) -> String {
            var text = (value ?? "").trimmingCharacters(in: .whitespaces)
            if [">", "|", ">-", "|-"].contains(where: { text.hasPrefix($0 + " ") }) { text = String(text.drop { $0 != " " }).trimmingCharacters(in: .whitespaces) }
            if text.count >= 2, let first = text.first, first == text.last, "\"'".contains(first) { text = String(text.dropFirst().dropLast()) }
            return text
        }
        let name = clean(fields["name"])
        return name.isEmpty ? nil : (String(name.prefix(80)), String(clean(fields["description"]).prefix(600)))
    }

    /// Adds a skill from a folder with a SKILL.md, from a SKILL.md itself, or from a .zip / .skill archive.
    @discardableResult
    func add(from source: URL) throws -> Skill {
        let fm = FileManager.default
        var folder = source, scratch: URL?
        defer { if let scratch { try? fm.removeItem(at: scratch) } }
        if ["zip", "skill"].contains(source.pathExtension.lowercased()) {
            let target = fm.temporaryDirectory.appendingPathComponent("mochi-skill-" + UUID().uuidString, isDirectory: true)
            scratch = target
            guard Self.unzip(source, to: target) else { throw Failure.unreadable }
            folder = target
        } else if source.lastPathComponent.lowercased() == "skill.md" {
            folder = source.deletingLastPathComponent()
        }
        // An archive often holds the skill one level down, in a folder named after it.
        if !fm.fileExists(atPath: folder.appendingPathComponent("SKILL.md").path) {
            let inner = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { fm.fileExists(atPath: $0.appendingPathComponent("SKILL.md").path) }
            guard inner.count == 1 else { throw Failure.noSkill }
            folder = inner[0]
        }
        guard let text = try? String(contentsOf: folder.appendingPathComponent("SKILL.md"), encoding: .utf8),
              let head = Self.parse(text) else { throw Failure.noSkill }
        // A skill of the same name is replaced: importing again is how one updates it. Its assignment stays.
        let previous = skills.first { $0.name.caseInsensitiveCompare(head.name) == .orderedSame }
        let skill = try keep(folder, head: head, replacing: previous, source: nil, stamp: nil)
        save()
        return skill
    }

    /// Copies a skill folder into the library and puts it in the list in place of `previous`.
    private func keep(_ folder: URL, head: (name: String, description: String), replacing previous: Skill?,
                      source: String?, stamp: String?) throws -> Skill {
        let fm = FileManager.default
        guard Self.fits(folder) else { throw Failure.tooLarge }
        let slug = String(head.name.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "-" })
            .split(separator: "-").joined(separator: "-")
        let id = String((slug.isEmpty ? "skill" : slug).prefix(40)) + "-" + String(UUID().uuidString.prefix(4)).lowercased()
        let home = library.appendingPathComponent(id, isDirectory: true)
        do {
            try fm.copyItem(at: folder, to: home)
            Self.dropLinks(in: home)
        } catch {
            try? fm.removeItem(at: home)
            throw Failure.unreadable
        }
        if let previous { try? fm.removeItem(at: library.appendingPathComponent(previous.id)) }
        let skill = Skill(id: id, name: head.name, description: head.description, agents: previous?.agents, source: source, stamp: stamp)
        if let position = skills.firstIndex(where: { $0.id == previous?.id }) { skills[position] = skill } else { skills.append(skill) }
        return skill
    }

    /// The places where Claude Code and Codex keep the user's own skills, in this order.
    static let clientFolders = [".claude/skills", ".codex/skills", ".agents/skills"]

    /// Links every skill the user already has in Claude Code or Codex, so agents of both kinds can use it, and
    /// keeps the links current: a skill changed there is copied again, one deleted there goes away here too.
    /// Skills the user took out stay out. Cheap when nothing changed: only file sizes and dates are compared.
    func sync(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let fm = FileManager.default
        var changed = false, seen = Set<String>(), names = Set<String>()
        for path in Self.clientFolders {
            let root = home.appendingPathComponent(path, isDirectory: true)
            for folder in ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []).sorted(by: { $0.path < $1.path }) {
                guard let text = try? String(contentsOf: folder.appendingPathComponent("SKILL.md"), encoding: .utf8),
                      let head = Self.parse(text), names.insert(head.name.lowercased()).inserted else { continue }
                let source = folder.path
                seen.insert(source)
                guard !hidden.contains(source) else { continue }
                let stamp = Self.fingerprint(folder)
                // Linked before; or taken over by hand from the clients earlier, then it becomes a link now.
                let previous = skills.first { $0.source == source }
                    ?? skills.first { $0.source == nil && $0.name.caseInsensitiveCompare(head.name) == .orderedSame }
                if let previous, previous.source == source, previous.stamp == stamp,
                   fm.fileExists(atPath: library.appendingPathComponent(previous.id + "/SKILL.md").path) { continue }
                if (try? keep(folder, head: head, replacing: previous, source: source, stamp: stamp)) != nil { changed = true }
            }
        }
        // Linked skills whose folder is gone, or that the user took out.
        for skill in skills where skill.source.map({ !seen.contains($0) || hidden.contains($0) }) == true {
            try? fm.removeItem(at: library.appendingPathComponent(skill.id))
            skills.removeAll { $0.id == skill.id }
            changed = true
        }
        if changed { save() }
    }

    /// Takes a linked skill out; it does not come back by itself. A skill added by hand is simply removed.
    func hide(_ skill: Skill) {
        if let source = skill.source, !hidden.contains(source) {
            hidden.append(source)
            SaveGuard.save(t("skills", "Skills")) { [hidden, hiddenFile] in try JSONFile.save(hidden, to: hiddenFile) }
        }
        remove(skill)
    }

    /// Brings back every linked skill the user took out.
    func showHidden(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        hidden = []
        SaveGuard.save(t("skills", "Skills")) { [hiddenFile] in try JSONFile.save([String](), to: hiddenFile) }
        sync(home: home)
    }

    /// Paths, sizes and dates of the files in a skill folder, hashed. Contents are not read.
    static func fingerprint(_ folder: URL) -> String {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        var lines = [String]()
        let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys)
        while let item = walker?.nextObject() as? URL {
            guard let values = try? item.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let relative = String(item.path.dropFirst(folder.path.count))
            lines.append("\(relative)|\(values.fileSize ?? 0)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)")
        }
        let digest = SHA256.hash(data: Data(lines.sorted().joined(separator: "\n").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func remove(_ skill: Skill) {
        try? FileManager.default.removeItem(at: library.appendingPathComponent(skill.id))
        skills.removeAll { $0.id == skill.id }
        save()
    }

    /// nil gives the skill to every agent, a list only to those agents.
    func assign(_ skill: Skill, to agents: [UUID]?) {
        guard let position = skills.firstIndex(where: { $0.id == skill.id }) else { return }
        skills[position].agents = agents
        save()
    }

    private func save() {
        SaveGuard.save(t("skills", "Skills")) { [skills, index] in try JSONFile.save(skills, to: index) }
        publish()
    }

    /// Brings the copy agents read from in line with the library: missing skills are added, removed ones deleted.
    /// Skills that are already there stay untouched, so a running agent never finds a skill gone for a moment
    /// (a changed skill gets a new id on import and is therefore a new folder).
    private func publish() {
        let fm = FileManager.default
        try? fm.createDirectory(at: mirror, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let wanted = Set(skills.map(\.id))
        for name in (try? fm.contentsOfDirectory(atPath: mirror.path)) ?? [] where !wanted.contains(name) {
            try? fm.removeItem(at: mirror.appendingPathComponent(name))
        }
        for id in wanted where !fm.fileExists(atPath: mirror.appendingPathComponent(id + "/SKILL.md").path) {
            try? fm.removeItem(at: mirror.appendingPathComponent(id))
            try? fm.copyItem(at: library.appendingPathComponent(id), to: mirror.appendingPathComponent(id))
        }
    }

    /// Links are removed: a skill must not point at files outside its own folder.
    private static func dropLinks(in folder: URL) {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return }
        for case let item as URL in walker where (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            try? fm.removeItem(at: item)
        }
    }

    private static func fits(_ folder: URL) -> Bool {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey]) else { return false }
        var bytes = 0, files = 0
        for case let item as URL in walker {
            files += 1
            bytes += (try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if bytes > maxBytes || files > maxFiles { return false }
        }
        return true
    }

    private static func unzip(_ archive: URL, to folder: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, folder.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
