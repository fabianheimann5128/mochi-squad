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
        guard let head = Self.manifest(folder) else { throw Failure.noSkill }
        // A skill of the same name is replaced: importing again is how one updates it. Its assignment stays.
        let previous = skills.first { $0.name.caseInsensitiveCompare(head.name) == .orderedSame }
        let skill = try keep(folder, head: head, replacing: previous, source: nil, stamp: nil)
        save()
        return skill
    }

    /// Largest SKILL.md that is read; bigger ones are no skill.
    static let maxManifest = 256 * 1024

    /// Name and description of the skill in `folder`, read with a size limit. A SKILL.md that is a link counts only
    /// if it points to a file inside the skill's own folder.
    static func manifest(_ folder: URL) -> (name: String, description: String)? {
        let root = folder.resolvingSymlinksInPath()
        let file = root.appendingPathComponent("SKILL.md").resolvingSymlinksInPath()
        guard file.path.hasPrefix(root.path + "/"), let data = AppPaths.readSmallFile(file, limit: maxManifest),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return parse(text)
    }

    /// Copies a skill folder into the library and puts it in the list in place of `previous`. A replaced skill keeps
    /// its id, so the path in the briefing of a running agent stays valid; the new content is swapped in at once.
    private func keep(_ folder: URL, head: (name: String, description: String), replacing previous: Skill?,
                      source: String?, stamp: String?) throws -> Skill {
        let fm = FileManager.default
        let root = folder.resolvingSymlinksInPath()
        // Never a whole home folder or anything above it, whatever a link points at.
        let home = fm.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
        guard root.path != "/", !(home + "/").hasPrefix(root.path + "/") else { throw Failure.unreadable }
        guard Self.fits(root) else { throw Failure.tooLarge }
        let slug = String(head.name.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "-" })
            .split(separator: "-").joined(separator: "-")
        let id = previous?.id ?? String((slug.isEmpty ? "skill" : slug).prefix(40)) + "-" + String(UUID().uuidString.prefix(4)).lowercased()
        try? fm.createDirectory(at: library, withIntermediateDirectories: true)
        let staging = library.appendingPathComponent(".incoming-" + UUID().uuidString, isDirectory: true)
        do {
            try Self.copyResolved(root, to: staging, root: root)
            // What was copied must still be a valid skill (a manifest link may have pointed elsewhere).
            guard Self.manifest(staging) != nil else { throw Failure.noSkill }
            try Self.swap(staging, into: library.appendingPathComponent(id, isDirectory: true))
        } catch {
            try? fm.removeItem(at: staging)
            throw (error as? Failure) ?? Failure.unreadable
        }
        let skill = Skill(id: id, name: head.name, description: head.description, agents: previous?.agents, source: source,
                          stamp: stamp ?? Self.fingerprint(library.appendingPathComponent(id)))
        if let position = skills.firstIndex(where: { $0.id == previous?.id }) { skills[position] = skill } else { skills.append(skill) }
        return skill
    }

    /// Copies a folder as plain files and folders. Links are followed only when they lead to something inside the
    /// skill's own folder (`root`); everything else they point at is left out.
    static func copyResolved(_ source: URL, to target: URL, root: URL, depth: Int = 0) throws {
        let fm = FileManager.default
        guard depth < 24 else { return }
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        for item in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            var real = item
            if (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                real = item.resolvingSymlinksInPath()
                guard real.path.hasPrefix(root.path + "/") else { continue }
            }
            let values = try? real.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            let destination = target.appendingPathComponent(item.lastPathComponent)
            if values?.isDirectory == true {
                try copyResolved(real, to: destination, root: root, depth: depth + 1)
            } else if values?.isRegularFile == true {
                try fm.copyItem(at: real, to: destination)
            }
        }
    }

    /// Puts `fresh` in the place of `target` with renames only, so a reader finds either the old or the new folder.
    static func swap(_ fresh: URL, into target: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: target.path) {
            let old = target.deletingLastPathComponent().appendingPathComponent(".old-" + UUID().uuidString)
            try fm.moveItem(at: target, to: old)
            do { try fm.moveItem(at: fresh, to: target) } catch { try? fm.moveItem(at: old, to: target); throw error }
            try? fm.removeItem(at: old)
        } else {
            try fm.moveItem(at: fresh, to: target)
        }
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
                let source = folder.path
                guard fm.fileExists(atPath: folder.appendingPathComponent("SKILL.md").path) else { continue }
                guard let head = Self.manifest(folder) else {
                    // There but unreadable right now (for example half saved): keep what was linked, with its assignment.
                    if skills.contains(where: { $0.source == source }) { seen.insert(source) }
                    continue
                }
                // The first source of a name wins: Claude Code before Codex.
                guard names.insert(head.name.lowercased()).inserted else { continue }
                seen.insert(source)
                guard !hidden.contains(source) else { continue }
                guard let stamp = Self.fingerprint(folder, limit: Self.maxFiles) else { continue }
                // Linked before; otherwise a skill of the same name (from another source, or taken over by hand
                // earlier) is replaced and keeps its assignment.
                let previous = skills.first { $0.source == source }
                    ?? skills.first { $0.name.caseInsensitiveCompare(head.name) == .orderedSame }
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
        if changed { save() } else { publish() }
    }

    /// Hidden skills whose folder still exists and could come back.
    func restorable(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Int {
        hidden.filter { FileManager.default.fileExists(atPath: URL(fileURLWithPath: $0).appendingPathComponent("SKILL.md").path) }.count
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
    static func fingerprint(_ folder: URL) -> String { fingerprint(folder, limit: Int.max) ?? "" }

    /// nil when the folder holds more than `limit` items: the walk stops early instead of reading a huge tree.
    static func fingerprint(_ folder: URL, limit: Int) -> String? {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        var lines = [String]()
        var count = 0
        let walker = FileManager.default.enumerator(at: folder.resolvingSymlinksInPath(), includingPropertiesForKeys: keys)
        let base = folder.resolvingSymlinksInPath().path
        while let item = walker?.nextObject() as? URL {
            count += 1
            if count > limit { return nil }
            guard let values = try? item.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let relative = String(item.path.dropFirst(base.count))
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

    /// Brings the copy agents read from in line with the library: missing or changed skills are copied (swapped in
    /// at once, under the same path), removed ones deleted. A marker file holds the version each copy shows.
    private func publish() {
        let fm = FileManager.default
        try? fm.createDirectory(at: mirror, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let wanted = Set(skills.map(\.id))
        for name in (try? fm.contentsOfDirectory(atPath: mirror.path)) ?? [] where !wanted.contains(name) {
            try? fm.removeItem(at: mirror.appendingPathComponent(name))
        }
        for skill in skills {
            let copy = mirror.appendingPathComponent(skill.id, isDirectory: true)
            let marker = copy.appendingPathComponent(".mochi-version")
            let version = skill.stamp ?? skill.id
            if fm.fileExists(atPath: copy.appendingPathComponent("SKILL.md").path),
               (try? String(contentsOf: marker, encoding: .utf8)) == version { continue }
            let staging = mirror.appendingPathComponent(".incoming-" + UUID().uuidString, isDirectory: true)
            do {
                try fm.copyItem(at: library.appendingPathComponent(skill.id), to: staging)
                try Data(version.utf8).write(to: staging.appendingPathComponent(".mochi-version"))
                try Self.swap(staging, into: copy)
            } catch {
                try? fm.removeItem(at: staging)
            }
        }
    }

    /// Size and number of files, stopping at the limits. Links count with what they point at.
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
