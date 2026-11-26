import Foundation

/// Eine Zeile im Team-Chat eines Projekts.
struct TeamLine: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case user, agent, notice }
    var id = UUID()
    let kind: Kind
    /// Name des Agenten; leer beim Nutzer und bei Hinweisen.
    var from = ""
    let text: String
    var date = Date()
}

/// Team-Chat je Projekt als Zeilen-JSON im App-Ordner, getrennt von den Verläufen der Clients.
@MainActor final class TeamLog: ObservableObject {
    @Published private(set) var lines = [TeamLine]()
    private(set) var project = ""
    private let folder: URL

    init(folder: URL = AppPaths.folder("team")) { self.folder = folder }

    private func file(_ project: String) -> URL {
        folder.appendingPathComponent(String(MochiLook.stableHash(project), radix: 16) + ".jsonl")
    }

    func open(_ project: String) {
        self.project = project
        guard let data = try? Data(contentsOf: file(project)) else { lines = []; return }
        lines = data.split(separator: 10).suffix(400).compactMap { try? JSONFile.decoder.decode(TeamLine.self, from: Data($0)) }
    }

    func append(_ line: TeamLine, project: String) {
        if project == self.project { lines.append(line) }
        guard var data = try? JSONEncoder.compactISO.encode(line) else { return }
        data.append(10)
        let url = file(project)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? JSONFile.write(data, to: url)
        }
    }

    func notice(_ text: String, project: String) { append(TeamLine(kind: .notice, text: text), project: project) }

    /// Die letzten Zeilen als Zusammenhang für einen dazugeholten Agenten (nur für das geöffnete Projekt im Speicher).
    func context(project: String, owner: String, count: Int = 8) -> String {
        guard project == self.project else { return "" }
        let recent = lines.filter { $0.kind != .notice }.suffix(count)
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
