import Foundation

/// A saved chat of a client (from history.py list).
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

/// Usage data of a session (from the status line or the history).
struct Usage: Decodable, Equatable {
    var model: String?
    var historyPath: String?
    var used, limit, cached, output, cacheWrite, fresh, skills, tools: Int?
    /// Tokens the session started with: instructions, tools, skills and the first exchange.
    var base: Int?
    /// Codex counts the last answer in `used`; Claude reports it separately (`output`), it joins the context next turn.
    var answerInside: Bool?
    var percent, five, week: Double?

    /// The context window split by what fills it; parts in tokens, in drawing order. Empty without numbers.
    var parts: [(kind: ContextPart, tokens: Int)] {
        // Numbers beyond any real context window are ignored rather than added up (they could overflow).
        let ceiling = 1 << 40
        guard let used, used > 0, used <= ceiling else { return [] }
        let output = self.output.map { min(max(0, $0), ceiling) }
        let window = self.limit.map { min(max(0, $0), ceiling) }
        let start = min(max(0, base ?? 0), used)
        if answerInside == true {
            // The answer is part of what the context holds.
            let answer = min(max(0, output ?? 0), used - start)
            let limit = max(window ?? used, used)
            return [(.base, start), (.conversation, used - start - answer), (.answer, answer), (.free, limit - used)].filter { $0.tokens > 0 }
        }
        // The answer comes on top of what was read; without a known window size there is no "free" part.
        let answer = max(0, output ?? 0)
        let filled = used + answer
        let limit = max(window ?? filled, filled)
        return [(.base, start), (.conversation, used - start), (.answer, answer), (.free, limit - filled)].filter { $0.tokens > 0 }
    }
}

enum ContextPart: CaseIterable {
    case base, conversation, answer, free
    var title: String {
        switch self {
        case .base: return t("Instructions, tools and skills", "Anweisungen, Werkzeuge und Skills")
        case .conversation: return t("Conversation", "Gesprächsverlauf")
        case .answer: return t("Last answer", "Letzte Antwort")
        case .free: return t("Free", "Frei")
        }
    }
}

/// Event from history.py activity: what an agent did last.
struct ActivityEvent: Decodable, Identifiable, Equatable {
    let id, stamp, text: String
    let file: String?
}

/// List of a project's saved chats. Separate from the open history so the sidebar does not redraw with every new line.
@MainActor final class ChatIndex: ObservableObject {
    @Published private(set) var entries = [ChatEntry]()

    func refresh(_ project: URL) async {
        let rows = (try? await PythonTool.run("history", ["list", project.path], as: [ChatEntry].self)) ?? []
        if rows != entries { entries = rows }
    }
}

/// History of the open chat. New lines are read incrementally and prepared as bubbles once.
@MainActor final class TranscriptStore: ObservableObject {
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

    func reset() {
        generation = UUID(); file = nil; position = 0; lines = []; bubbles = []; lineCount = 0; lastLine = nil
        older = false; usage = Usage(); issue = nil; limit = 40; busy = false; loading = false
    }

    /// Loads new lines from `path`. `earlier` are older histories of the same agent that appear before it.
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
            if page.usage.used != nil {
                // A read that continues where the last one stopped knows nothing about the session's start: keep it.
                // The base belongs to the session's start and does not change once known.
                var fresh = page.usage
                if !initial, let known = usage.base { fresh.base = known } else if fresh.base == nil { fresh.base = usage.base }
                usage = fresh
            } else if let model = page.usage.model { usage.model = model }
            // When appending, prepare only the new lines; finished bubbles stay untouched.
            if initial { bubbles = Bubble.make(from: lines) } else { bubbles += Bubble.make(from: page.messages, after: previous) }
            lineCount = lines.count
            lastLine = lines.last
            issue = nil
        } catch {
            if generation == token { issue = t("The history could not be loaded.", "Der Verlauf konnte nicht geladen werden.") }
        }
    }

    /// Continuations contain copies of the old history: same role, time and text count only once.
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
