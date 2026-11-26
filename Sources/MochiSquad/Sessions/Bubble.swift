import Foundation
import SwiftUI

/// One line of a message as it is drawn: a paragraph, or a list item with its marker set off to the left
/// so that wrapped lines align under the text instead of under the bullet.
struct TextRow: Equatable, Identifiable {
    let id: Int
    /// "•" or "1." for list items, nil for plain paragraphs.
    let marker: String?
    var text: AttributedString

    /// Splits a block of Markdown into rows. Headings become bold lines, list items keep their marker,
    /// consecutive plain lines stay one paragraph.
    static func rows(_ block: String) -> [TextRow] {
        var result = [TextRow](), plain = [String]()
        func flush() {
            guard !plain.isEmpty else { return }
            result.append(TextRow(id: result.count, marker: nil, text: rich(plain.joined(separator: "\n"))))
            plain = []
        }
        for raw in block.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if let item = listItem(line) {
                flush()
                result.append(TextRow(id: result.count, marker: item.marker, text: rich(item.text)))
            } else if line.range(of: #"^#{1,6}\s+\S"#, options: .regularExpression) != nil {
                flush()
                let title = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "**", with: "")
                result.append(TextRow(id: result.count, marker: nil, text: rich("**" + title + "**")))
            } else {
                plain.append(line)
            }
        }
        flush()
        return result
    }

    /// "- text", "* text", "• text" or "1. text" → marker and text.
    static func listItem(_ line: String) -> (marker: String, text: String)? {
        for bullet in ["- ", "* ", "• "] where line.hasPrefix(bullet) {
            return ("•", String(line.dropFirst(bullet.count)).trimmingCharacters(in: .whitespaces))
        }
        guard let match = line.range(of: #"^\d{1,2}[.)]\s+"#, options: .regularExpression) else { return nil }
        let number = line[match].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ")", with: ".")
        return (number, String(line[match.upperBound...]))
    }

    /// Inline Markdown; code spans get a monospaced face on a quiet background so file names stand out.
    static func rich(_ markdown: String) -> AttributedString {
        var text = (try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(markdown)
        for run in text.runs where run.inlinePresentationIntent?.contains(.code) == true {
            text[run.range].font = .system(size: 13.5, design: .monospaced)
            text[run.range].backgroundColor = Color.white.opacity(0.09)
        }
        return text
    }
}

/// A speech bubble, prepared once: Markdown parsed, day lines set.
/// Agent answers are split by paragraph, like messages typed one after the other.
struct Bubble: Identifiable, Equatable {
    enum Kind: Equatable { case user, agent, code }
    let id: String
    let kind: Kind
    /// What is drawn: paragraphs and list items. Code bubbles and the user's own messages have one row.
    let rows: [TextRow]
    let plain: String
    /// Sender of a message from agent to agent or from the team chat.
    let relayedFrom: String?
    let relayedVia: String?
    /// Files attached to an own message, relative to the project.
    var attachments = [String]()
    /// First bubble of a new day: "Today 9:40".
    let day: String?
    /// Gap above in points.
    let gap: Double

    /// `after` is the last line already shown when bubbles are appended to an existing history.
    static func make(from lines: [ChatLine], after: ChatLine? = nil) -> [Bubble] {
        let calendar = Calendar.current
        func dayLabel(_ date: Date) -> String {
            calendar.isDateInToday(date) ? t("Today", "Heute") : calendar.isDateInYesterday(date) ? t("Yesterday", "Gestern")
                : date.formatted(.dateTime.weekday(.wide).day().month(.wide).year().locale(L10n.language.locale))
        }
        var result = [Bubble]()
        var previousDay = after.flatMap { Timestamp.date($0.timestamp) }.map(dayLabel)
        var previousRole = after?.role
        for line in lines {
            let date = Timestamp.date(line.timestamp)
            var day: String?
            if let date {
                let label = dayLabel(date)
                if label != previousDay { day = label + " " + date.formatted(.dateTime.hour().minute().locale(L10n.language.locale)); previousDay = label }
            }
            let follows = previousRole == line.role && day == nil
            let first = result.isEmpty && after == nil
            previousRole = line.role
            if line.role == "user" {
                let relay = RelayedMessage.parse(line.text)
                // Attachments exist only on own messages; relayed text from agents is not read as a file list.
                let parts = relay == nil ? Attachments.split(line.text) : (text: relay!.body, files: [])
                let shown = parts.text
                result.append(Bubble(id: "\(line.id).0", kind: .user, rows: [TextRow(id: 0, marker: nil, text: AttributedString(shown))], plain: shown,
                                     relayedFrom: relay?.sender, relayedVia: relay?.via, attachments: parts.files, day: day,
                                     gap: first ? 0 : (follows ? 4 : 14)))
                continue
            }
            for (k, part) in paragraphs(line.text).enumerated() {
                let rows = part.code ? [TextRow(id: 0, marker: nil, text: AttributedString(part.text))] : TextRow.rows(part.text)
                result.append(Bubble(id: "\(line.id).\(k)", kind: part.code ? .code : .agent, rows: rows, plain: part.text,
                                     relayedFrom: nil, relayedVia: nil, day: k == 0 ? day : nil,
                                     gap: first && k == 0 ? 0 : (k > 0 || follows ? 4 : 14)))
            }
        }
        return result
    }

    /// Splits an answer into paragraphs and code blocks. A list stays together with its lead-in line.
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
            block.append(raw)
        }
        flush(fenced)
        // Short lead-in lines ("…:") and headings stay with what follows; so do the items of one list.
        var merged = [(text: String, code: Bool)]()
        for piece in result {
            if let last = merged.last, !last.code, !piece.1 {
                let lead = last.text.count < 80 && (last.text.hasSuffix(":") || last.text.hasPrefix("#") || last.text.hasPrefix("**"))
                let tail = last.text.components(separatedBy: "\n").last ?? ""
                let list = TextRow.listItem(tail.trimmingCharacters(in: .whitespaces)) != nil
                    && TextRow.listItem(piece.0.trimmingCharacters(in: .whitespaces)) != nil
                if lead || list { merged[merged.count - 1].text += "\n" + piece.0; continue }
            }
            merged.append(piece)
        }
        return merged
    }
}

/// Timestamps from the histories (ISO 8601, with or without fractional seconds).
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

/// Messages that Mochi Squad routes into an agent's chat: agent post and team chat.
/// The wording is English because agents read it; the German forms of earlier versions are still recognised.
enum RelayedMessage {
    static let postPrefix = "Message from "
    static let teamPrefix = "Team chat · "
    static let teamContext = "\n\n[Recent team chat]"
    static let teamHint = "\n[Note] "
    private static let legacyPostPrefix = "Nachricht von "
    private static let legacyTeamPrefix = "Team-Chat · "
    private static let legacyCuts = ["\n\n[Verlauf im Team-Chat]", "\n[Hinweis] "]

    static func parse(_ text: String) -> (sender: String, body: String, via: String)? {
        if let team = parseTeam(text) { return (team.sender, team.body, t("in the team chat", "im Team-Chat")) }
        guard let prefix = [postPrefix, legacyPostPrefix].first(where: text.hasPrefix), let colon = text.firstIndex(of: ":") else { return nil }
        let head = text[text.index(text.startIndex, offsetBy: prefix.count)..<colon]
        let name = head.split(separator: "(").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard !name.isEmpty, name.count < 40 else { return nil }
        return (name, text[text.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines), t("via agent post", "über Agenten-Post"))
    }

    static func parseTeam(_ text: String) -> (sender: String, body: String)? {
        guard let prefix = [teamPrefix, legacyTeamPrefix].first(where: text.hasPrefix), let colon = text.firstIndex(of: ":") else { return nil }
        let sender = text[text.index(text.startIndex, offsetBy: prefix.count)..<colon].trimmingCharacters(in: .whitespaces)
        var body = String(text[text.index(after: colon)...])
        for cut in [teamContext, teamHint] + legacyCuts {
            if let range = body.range(of: cut) { body = String(body[..<range.lowerBound]) }
        }
        return sender.isEmpty || sender.count > 40 ? nil : (sender, body.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// A real mention: "@name" with word boundaries, so "press@otto.de" calls nobody.
enum Mention {
    /// Words that address the whole team, in both interface languages.
    static let everyone = ["all", "everyone", "team", "alle"]

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

    static func addressesEveryone(_ text: String) -> Bool { everyone.contains { contains(text, $0) } }
}
