import Foundation

/// Ein gespeicherter Chat eines Clients (aus history.py list).
struct ChatEntry: Decodable, Identifiable, Hashable {
    let id, path, provider, title: String
    let modified: Double
    var providerKind: Provider { Provider(rawValue: provider) ?? .claude }
}

struct ChatLine: Decodable, Identifiable, Equatable {
    let id: Int
    let role, text, timestamp: String
}

struct ChatPage: Decodable {
    let messages: [ChatLine]
    let position: Int
    let older: Bool
    let usage: Usage
}

/// Nutzungsdaten einer Sitzung (aus der Statuszeile oder dem Verlauf).
struct Usage: Decodable, Equatable {
    var model: String?
    var historyPath: String?
    var used, limit, cached, output, cacheWrite, fresh, skills, tools: Int?
    var percent, five, week: Double?
}

/// Ereignis aus history.py activity: was ein Agent zuletzt getan hat.
struct ActivityEvent: Decodable, Identifiable, Equatable {
    let id, stamp, text: String
    let file: String?
}

/// Verlauf des geöffneten Chats. Neue Zeilen werden inkrementell gelesen und einmal zu Blasen aufbereitet.
@MainActor final class TranscriptStore: ObservableObject {
    @Published private(set) var entries = [ChatEntry]()
    @Published private(set) var bubbles = [Bubble]()
    @Published private(set) var lineCount = 0
    @Published private(set) var lastLine: ChatLine?
    @Published private(set) var older = false
    @Published private(set) var usage = Usage()
    @Published private(set) var issue: String?
    @Published private(set) var loading = false

    private var lines = [ChatLine]()
    private var position = 0
    private var file: String?
    private var generation = UUID()
    private var limit = 40
    private var busy = false

    func index(_ project: URL) async {
        do {
            let rows = try await PythonTool.run("history", ["list", project.path], as: [ChatEntry].self)
            entries = rows
        } catch {
            entries = []
        }
    }

    func reset() {
        generation = UUID(); file = nil; position = 0; lines = []; bubbles = []; lineCount = 0; lastLine = nil
        older = false; usage = Usage(); issue = nil; limit = 40; busy = false; loading = false
    }

    /// Lädt neue Zeilen von `path`. `earlier` sind ältere Verläufe desselben Agenten, die davor erscheinen.
    func load(_ path: String, provider: Provider, earlier: [String] = [], more: Bool = false) async {
        if file != path { reset(); file = path }
        guard !busy else { return }
        if more { limit += 60; position = 0 }
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue,
              size != position else { return }
        if size < position { position = 0 }
        let initial = position == 0, token = generation
        busy = true; loading = initial
        defer { if generation == token { busy = false; loading = false } }
        do {
            let page = try await PythonTool.run("history", ["read", path, provider.rawValue, String(position), String(initial ? limit : 4000)],
                                                as: ChatPage.self)
            guard generation == token else { return }
            let previous = lines.last
            if initial {
                var all = page.messages, more = page.older
                if !earlier.isEmpty,
                   let before = try? await PythonTool.run("history", ["thread", String(limit)] + earlier, as: ChatPage.self) {
                    guard generation == token else { return }
                    all = Self.merge(before.messages, all)
                    more = more || before.older
                }
                lines = all; older = more
            } else {
                lines.append(contentsOf: page.messages)
            }
            position = page.position
            if page.usage.used != nil { usage = page.usage } else if let model = page.usage.model { usage.model = model }
            // Beim Anhängen nur die neuen Zeilen aufbereiten; die fertigen Blasen bleiben unverändert.
            if initial { bubbles = Bubble.make(from: lines) } else { bubbles += Bubble.make(from: page.messages, after: previous) }
            lineCount = lines.count
            lastLine = lines.last
            issue = nil
        } catch {
            if generation == token { issue = "Der Verlauf konnte nicht geladen werden." }
        }
    }

    /// Fortsetzungen enthalten Kopien des alten Verlaufs: gleiche Rolle, Zeit und Text zählen nur einmal.
    static func merge(_ before: [ChatLine], _ current: [ChatLine]) -> [ChatLine] {
        func key(_ line: ChatLine) -> String { line.role + "|" + line.timestamp + "|" + String(line.text.prefix(200)) }
        let known = Set(current.map(key))
        let merged = before.filter { !known.contains(key($0)) } + current
        return merged.enumerated().sorted { a, b in
            let left = a.element.timestamp.count > 8 ? a.element.timestamp : "~"
            let right = b.element.timestamp.count > 8 ? b.element.timestamp : "~"
            return left == right ? a.offset < b.offset : left < right
        }.map(\.element)
    }
}
