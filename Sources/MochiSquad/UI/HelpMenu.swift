import AppKit
import SwiftUI

/// Feedback goes to the repository as an issue. The link only picks the template; filling in and sending happens in the browser.
enum Feedback {
    static let repository = "https://github.com/fabianheimann5128/mochi-squad"

    enum Kind { case bug, idea }

    static func url(_ kind: Kind) -> URL {
        var parts = URLComponents(string: repository + "/issues/new")!
        parts.queryItems = [URLQueryItem(name: "template", value: kind == .bug ? "bug.md" : "feature.md")]
        return parts.url!
    }

    static var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }

    /// Text of the changelog from the app bundle: CHANGELOG.md, or CHANGELOG.de.md for the German interface.
    static var changelog: String {
        let names = L10n.language == .de ? ["CHANGELOG.de", "CHANGELOG"] : ["CHANGELOG"]
        return names.lazy.compactMap { Bundle.main.url(forResource: $0, withExtension: "md") }
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }.first ?? ""
    }
}

/// One entry of the changelog: an optional bold lead ("**Telegram.** Reach your team …") and the text after it.
struct ChangeItem: Equatable {
    let title: String?
    let text: String

    init(_ line: String) {
        if line.hasPrefix("**"), let end = line.dropFirst(2).range(of: "**") {
            title = String(line.dropFirst(2)[..<end.lowerBound]).trimmingCharacters(in: CharacterSet(charactersIn: ".: "))
            text = String(line[end.upperBound...]).trimmingCharacters(in: .whitespaces)
        } else {
            title = nil
            text = line
        }
    }

    /// A fitting symbol, chosen by what the entry talks about.
    var symbol: String {
        let words = ((title ?? "") + " " + text).lowercased()
        let table: [(String, [String])] = [
            ("paperplane.fill", ["telegram"]), ("phone.bubble.fill", ["whatsapp"]), ("globe", ["english", "englisch", "language", "sprache"]),
            ("sidebar.left", ["icon bar", "symbolleiste"]), ("text.bubble.fill", ["chats read", "chats lesen", "formatting"]),
            ("person.2.fill", ["coordinator", "koordinator"]), ("clock.fill", ["routine"]), ("checkmark.shield.fill", ["review", "prüfung", "fixes", "korrekturen"]),
            ("paperclip", ["attach", "anhängen"]), ("mic.fill", ["dictate", "einsprechen"]), ("desktopcomputer", ["computer"]),
            ("lock.fill", ["access", "zugriff"]), ("face.smiling", ["mochi"]),
        ]
        return table.first { $0.1.contains(where: words.contains) }?.0 ?? "sparkles"
    }
}

/// "What's new?": the latest version as a short illustrated list, earlier versions folded away below it.
struct WhatsNew: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showEarlier = false

    /// (heading, items) per version, newest first.
    static func sections(_ text: String) -> [(title: String, items: [String])] {
        var result = [(title: String, items: [String])]()
        for line in text.components(separatedBy: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.hasPrefix("## ") { result.append((String(line.dropFirst(3)), [])) }
            else if line.hasPrefix("- "), !result.isEmpty { result[result.count - 1].items.append(String(line.dropFirst(2))) }
        }
        return result
    }

    var body: some View {
        let sections = Self.sections(Feedback.changelog)
        VStack(spacing: 0) {
            header(version: sections.first?.title)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if let latest = sections.first {
                        ForEach(Array(latest.items.map(ChangeItem.init).enumerated()), id: \.offset) { _, item in row(item) }
                    }
                    if sections.count > 1 { earlier(Array(sections.dropFirst())) }
                }.padding(.horizontal, 18).padding(.vertical, 14)
            }.frame(height: 380)
            Rectangle().fill(Desk.rule).frame(height: 1)
            HStack {
                Text(t("You are using Mochi Squad \(Feedback.appVersion).", "Du nutzt Mochi Squad \(Feedback.appVersion)."))
                    .font(.system(size: 12)).foregroundStyle(Desk.dim)
                Spacer()
                Button(t("Done", "Fertig")) { dismiss() }.buttonStyle(.primaryPill).keyboardShortcut(.defaultAction)
            }.padding(.horizontal, 22).padding(.vertical, 14)
        }.frame(width: 520)
    }

    private func header(version: String?) -> some View {
        HStack(spacing: 16) {
            RocketGlyph().foregroundStyle(.white).frame(width: 30, height: 30)
                .frame(width: 60, height: 60).background(Color.white.opacity(0.16), in: Circle())
                .overlay { Circle().strokeBorder(Color.white.opacity(0.22)) }
            VStack(alignment: .leading, spacing: 4) {
                Text(t("What's new", "Was ist neu")).font(.system(size: 24, weight: .bold)).foregroundStyle(.white)
                if let version {
                    Text("Version " + version).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 9).frame(height: 22).background(Color.white.opacity(0.18), in: Capsule())
                }
            }
            Spacer()
        }
        .padding(.horizontal, 24).padding(.vertical, 22)
        .background(LinearGradient(colors: [Desk.rgb(47, 107, 255), Desk.rgb(118, 84, 240)], startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    private func row(_ item: ChangeItem) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: item.symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(Desk.accent)
                .frame(width: 36, height: 36).background(Desk.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                if let title = item.title { Text(title).font(.system(size: 14, weight: .semibold)) }
                Text(item.text).font(.system(size: 13)).foregroundStyle(item.title == nil ? Desk.text : Desk.dim).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }.padding(.top, item.title == nil ? 8 : 0)
            Spacer(minLength: 0)
        }.padding(.horizontal, 8).padding(.vertical, 8)
    }

    private func earlier(_ sections: [(title: String, items: [String])]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(.easeInOut(duration: 0.2)) { showEarlier.toggle() } } label: {
                HStack(spacing: 6) {
                    Text(t("Earlier versions", "Frühere Versionen")).font(.system(size: 12.5, weight: .medium))
                    Image(systemName: showEarlier ? "chevron.down" : "chevron.right").font(.system(size: 9.5, weight: .semibold))
                }.foregroundStyle(Desk.dim).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if showEarlier {
                ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Version " + section.title).font(.system(size: 12.5, weight: .semibold))
                        ForEach(section.items, id: \.self) { line in
                            let item = ChangeItem(line)
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("•").foregroundStyle(Desk.faint)
                                Text((item.title.map { $0 + ": " } ?? "") + item.text).font(.system(size: 12.5)).foregroundStyle(Desk.dim)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading).field(12)
                }
            }
        }.padding(.horizontal, 8).padding(.top, 14)
    }
}
