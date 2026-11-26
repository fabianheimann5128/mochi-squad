import Foundation

/// Eine Sprechblase, fertig aufbereitet: Markdown einmal geparst, Tageszeilen gesetzt.
/// Antworten der Agenten werden absatzweise geteilt, wie einzeln getippte Nachrichten.
struct Bubble: Identifiable, Equatable {
    enum Kind: Equatable { case user, agent, code }
    let id: String
    let kind: Kind
    let text: AttributedString
    let plain: String
    /// Absender einer Nachricht von Agent zu Agent oder aus dem Team-Chat.
    let relayedFrom: String?
    let relayedVia: String?
    /// Erste Blase eines neuen Tages: „Heute 9:40“.
    let day: String?
    /// Abstand nach oben in Punkten.
    let gap: Double

    /// `after` ist die letzte schon gezeigte Zeile, wenn Blasen an einen bestehenden Verlauf angehängt werden.
    static func make(from lines: [ChatLine], after: ChatLine? = nil) -> [Bubble] {
        let calendar = Calendar.current
        func dayLabel(_ date: Date) -> String {
            calendar.isDateInToday(date) ? "Heute" : calendar.isDateInYesterday(date) ? "Gestern"
                : date.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
        }
        var result = [Bubble]()
        var previousDay = after.flatMap { Timestamp.date($0.timestamp) }.map(dayLabel)
        var previousRole = after?.role
        for line in lines {
            let date = Timestamp.date(line.timestamp)
            var day: String?
            if let date {
                let label = dayLabel(date)
                if label != previousDay { day = label + " " + date.formatted(date: .omitted, time: .shortened); previousDay = label }
            }
            let follows = previousRole == line.role && day == nil
            let first = result.isEmpty && after == nil
            previousRole = line.role
            if line.role == "user" {
                let relay = RelayedMessage.parse(line.text)
                let shown = relay?.body ?? line.text
                result.append(Bubble(id: "\(line.id).0", kind: .user, text: AttributedString(shown), plain: shown,
                                     relayedFrom: relay?.sender, relayedVia: relay?.via, day: day,
                                     gap: first ? 0 : (follows ? 4 : 14)))
                continue
            }
            for (k, part) in paragraphs(line.text).enumerated() {
                let rich = part.code ? AttributedString(part.text)
                    : (try? AttributedString(markdown: part.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                    ?? AttributedString(part.text)
                result.append(Bubble(id: "\(line.id).\(k)", kind: part.code ? .code : .agent, text: rich, plain: part.text,
                                     relayedFrom: nil, relayedVia: nil, day: k == 0 ? day : nil,
                                     gap: first && k == 0 ? 0 : (k > 0 || follows ? 4 : 14)))
            }
        }
        return result
    }

    /// Zerlegt eine Antwort in Absätze und Codeblöcke. Überschriften werden fett, Listenpunkte zu „•“.
    static func paragraphs(_ text: String) -> [(text: String, code: Bool)] {
        var result = [(String, Bool)](), block = [String](), fenced = false
        func flush(_ code: Bool) {
            let joined = block.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { result.append((joined, code)) }
            block = []
        }
        for raw in text.components(separatedBy: "\n") {
            let bare = raw.trimmingCharacters(in: .whitespaces)
            if !fenced, bare.hasPrefix("```"), bare.hasSuffix("```"), bare.count > 6 {
                flush(false); block = [String(bare.dropFirst(3).dropLast(3))]; flush(true); continue
            }
            if bare.hasPrefix("```") { flush(fenced); fenced.toggle(); continue }
            if fenced { block.append(raw); continue }
            if bare.isEmpty { flush(false); continue }
            if bare.range(of: #"^#{1,6}\s+\S"#, options: .regularExpression) != nil {
                block.append("**" + bare.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "**", with: "") + "**")
            } else if bare.hasPrefix("- ") || bare.hasPrefix("* ") {
                block.append(String(raw.prefix { $0 == " " }) + "•  " + bare.dropFirst(2))
            } else {
                block.append(raw)
            }
        }
        flush(fenced)
        // Kurze Einleitungszeilen („…:“) und Überschriften bleiben beim folgenden Absatz.
        var merged = [(text: String, code: Bool)]()
        for piece in result {
            if let last = merged.last, !last.code, !piece.1, last.text.count < 60, last.text.hasSuffix(":") || last.text.hasPrefix("**") {
                merged[merged.count - 1].text += "\n" + piece.0
            } else { merged.append(piece) }
        }
        return merged
    }
}

/// Zeitstempel aus den Verläufen (ISO 8601, mit oder ohne Sekundenbruchteile).
enum Timestamp {
    private static let fine: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let plain = ISO8601DateFormatter()
    static func date(_ stamp: String) -> Date? {
        stamp.count <= 8 ? nil : fine.date(from: stamp) ?? plain.date(from: stamp)
    }
    static func string(_ date: Date) -> String { plain.string(from: date) }
}

/// Nachrichten, die Mochi Squad in einen Agenten-Chat leitet: Agenten-Post und Team-Chat.
enum RelayedMessage {
    static let postPrefix = "Nachricht von "
    static let teamPrefix = "Team-Chat · "
    static let teamContext = "\n\n[Verlauf im Team-Chat]"
    static let teamHint = "\n[Hinweis] "

    static func parse(_ text: String) -> (sender: String, body: String, via: String)? {
        if let team = parseTeam(text) { return (team.sender, team.body, "im Team-Chat") }
        guard text.hasPrefix(postPrefix), let colon = text.firstIndex(of: ":") else { return nil }
        let head = text[text.index(text.startIndex, offsetBy: postPrefix.count)..<colon]
        let name = head.split(separator: "(").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard !name.isEmpty, name.count < 40 else { return nil }
        return (name, text[text.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines), "über Agenten-Post")
    }

    static func parseTeam(_ text: String) -> (sender: String, body: String)? {
        guard text.hasPrefix(teamPrefix), let colon = text.firstIndex(of: ":") else { return nil }
        let sender = text[text.index(text.startIndex, offsetBy: teamPrefix.count)..<colon].trimmingCharacters(in: .whitespaces)
        var body = String(text[text.index(after: colon)...])
        if let cut = body.range(of: teamContext) { body = String(body[..<cut.lowerBound]) }
        if let cut = body.range(of: teamHint) { body = String(body[..<cut.lowerBound]) }
        return sender.isEmpty || sender.count > 40 ? nil : (sender, body.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// Echte Erwähnung: „@Name“ mit Wortgrenzen, damit „presse@otto.de“ niemanden ruft.
enum Mention {
    private static var cache = [String: NSRegularExpression]()
    private static let lock = NSLock()

    static func contains(_ text: String, _ name: String) -> Bool {
        lock.lock()
        let regex: NSRegularExpression
        if let known = cache[name.lowercased()] { regex = known } else {
            let pattern = "(?<![\\p{L}\\p{N}._-])@" + NSRegularExpression.escapedPattern(for: name) + "(?![\\p{L}\\p{N}])"
            regex = (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])) ?? NSRegularExpression()
            cache[name.lowercased()] = regex
        }
        lock.unlock()
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
