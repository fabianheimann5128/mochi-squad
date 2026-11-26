import Foundation

/// One line in a project's team chat.
struct TeamLine: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case user, agent, notice }
    var id = UUID()
    let kind: Kind
    /// Name of the agent at the time of writing; empty for the user and for notices.
    var from = ""
    /// The agent itself. Names can change or be reused, so who may see a line is decided by this id.
    var agent: UUID?
    let text: String
    var date = Date()
    /// Where a user line came from when not typed in the app ("Telegram", "WhatsApp").
    var via: String?
}

/// Team chat per project as JSON lines in the app folder, separate from the clients' histories.
@MainActor final class TeamLog: ObservableObject {
    @Published private(set) var lines = [TeamLine]()
    private(set) var project = ""
    /// Called for every appended line (messengers forward answers from here).
    var onAppend: ((TeamLine, String) -> Void)?
    private let folder: URL
    /// Only the end of a long log is read: enough for the lines that are shown.
    private static let tailBytes = 2 * 1024 * 1024

    init(folder: URL = AppPaths.folder("team")) { self.folder = folder }

    private func file(_ project: String) -> URL {
        folder.appendingPathComponent(String(MochiLook.stableHash(project), radix: 16) + ".jsonl")
    }

    func open(_ project: String) {
        self.project = project
        lines = Self.tail(of: file(project)).split(separator: 10).suffix(400).compactMap { try? JSONFile.decoder.decode(TeamLine.self, from: Data($0)) }
    }

    private static func tail(of url: URL) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: start)
        var data = (try? handle.readToEnd()) ?? Data()
        // A read that starts mid-file begins inside a line; drop that fragment.
        if start > 0, let cut = data.firstIndex(of: 10) { data = data[data.index(after: cut)...] }
        return data
    }

    func append(_ line: TeamLine, project: String) {
        if project == self.project { lines.append(line) }
        onAppend?(line, project)
        guard var data = try? JSONEncoder.compactISO.encode(line) else { return }
        data.append(10)
        let url = file(project)
        SaveGuard.save(t("team chat", "Team-Chat")) {
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try JSONFile.write(data, to: url)
            }
        }
    }

    func notice(_ text: String, project: String) { append(TeamLine(kind: .notice, text: text), project: project) }

    /// The latest lines as context for an agent that is brought in (only for the open project in memory).
    /// `voices` are the agents whose lines the recipient may see; the user's lines always belong.
    /// Lines from before agent ids were stored fall back to the name, but only for an agent that still carries it.
    func context(project: String, owner: String, voices: [Agent], count: Int = 8) -> String {
        guard project == self.project else { return "" }
        let ids = Set(voices.map(\.id)), names = Set(voices.map(\.name))
        let recent = lines.filter { line in
            line.kind == .user || (line.kind == .agent && (line.agent.map(ids.contains) ?? names.contains(line.from)))
        }.suffix(count)
        guard !recent.isEmpty else { return "" }
        return RelayedMessage.teamContext + "\n" + recent.map {
            "- " + ($0.kind == .user ? owner : $0.from) + ": " + String($0.text.replacingOccurrences(of: "\n", with: " ").prefix(280))
        }.joined(separator: "\n")
    }
}

extension JSONEncoder {
    static let compactISO: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}
