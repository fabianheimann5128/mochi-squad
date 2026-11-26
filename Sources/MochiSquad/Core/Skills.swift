import Foundation

/// A skill: a folder with a SKILL.md that tells an agent how to do one kind of work, plus any files it refers to.
struct Skill: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var description: String
    /// The agents that get this skill; nil means every agent.
    var agents: [UUID]?
}

/// A skill found in a client's own folder that could be added to the library.
struct FoundSkill: Identifiable, Equatable {
    let name, description, source: String
    let folder: URL
    var id: String { folder.path }
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
    private let index: URL
    private let library: URL
    private let mirror: URL

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
         mirror: URL = AppPaths.shared.appendingPathComponent("skills", isDirectory: true)) {
        self.index = index
        self.library = library
        self.mirror = mirror
        skills = JSONFile.load([Skill].self, from: index) ?? []
        // The shared copy lives in a cache folder macOS may clear: bring it back at every launch.
        publish()
    }

    /// Skills an agent has.
    func skills(for agent: Agent) -> [Skill] { skills.filter { $0.agents?.contains(agent.id) ?? true } }

    /// Name and description from the head of a SKILL.md ("---", "name: …", "description: …", "---").
    static func parse(_ text: String) -> (name: String, description: String)? {
        let lines = text.components(separatedBy: "\n")
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
        // A skill of the same name is replaced: importing again is how one updates it. Its assignment stays.
        let previous = skills.first { $0.name.caseInsensitiveCompare(head.name) == .orderedSame }
        if let previous { try? fm.removeItem(at: library.appendingPathComponent(previous.id)) }
        let skill = Skill(id: id, name: head.name, description: head.description, agents: previous?.agents)
        skills = skills.filter { $0.id != previous?.id } + [skill]
        save()
        return skill
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

    /// Skills in the clients' own folders that are not in the library yet.
    func found(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [FoundSkill] {
        let known = Set(skills.map { $0.name.lowercased() })
        var result = [FoundSkill]()
        for (source, path) in [("Claude Code", ".claude/skills"), ("Codex", ".codex/skills")] {
            let root = home.appendingPathComponent(path, isDirectory: true)
            for folder in ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []).sorted(by: { $0.path < $1.path }) {
                guard let text = try? String(contentsOf: folder.appendingPathComponent("SKILL.md"), encoding: .utf8), let head = Self.parse(text),
                      !known.contains(head.name.lowercased()), !result.contains(where: { $0.name.lowercased() == head.name.lowercased() }) else { continue }
                result.append(FoundSkill(name: head.name, description: head.description, source: source, folder: folder))
            }
        }
        return result
    }

    private func save() {
        SaveGuard.save(t("skills", "Skills")) { [skills, index] in try JSONFile.save(skills, to: index) }
        publish()
    }

    /// Rebuilds the copy agents read from: exactly the skills of the library, nothing else.
    private func publish() {
        let fm = FileManager.default
        try? fm.removeItem(at: mirror)
        try? fm.createDirectory(at: mirror, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        for skill in skills {
            try? fm.copyItem(at: library.appendingPathComponent(skill.id), to: mirror.appendingPathComponent(skill.id))
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
