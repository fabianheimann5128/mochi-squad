import AppKit
import SwiftUI

/// Rückmeldungen gehen per Telegram an den Entwickler. Vorbereitet wird nur eine Nachricht mit App- und macOS-Version;
/// abgeschickt wird sie erst vom Nutzer selbst.
enum Feedback {
    /// Telegram-Name, an den Rückmeldungen gehen. Ändert er sich, genügt diese Zeile.
    static let telegram = "mochisquad"

    enum Kind { case bug, idea }

    static func url(_ kind: Kind, version: String = appVersion, system: String = ProcessInfo.processInfo.operatingSystemVersionString) -> URL {
        let opening = kind == .bug ? "Fehler in Mochi Squad" : "Vorschlag für Mochi Squad"
        let question = kind == .bug ? "Was ist passiert, und was hattest du erwartet?" : "Was wünschst du dir, und wobei würde es helfen?"
        var parts = URLComponents(string: "https://t.me/" + telegram)!
        parts.queryItems = [URLQueryItem(name: "text", value: "\(opening) \(version) (macOS \(system))\n\n\(question)\n")]
        return parts.url!
    }

    static var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Entwicklung" }

    /// Text von CHANGELOG.md aus dem App-Bundle.
    static var changelog: String {
        Bundle.main.url(forResource: "CHANGELOG", withExtension: "md").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }
}

/// Knopf unten links: Neuigkeiten, Fehler melden, Funktion vorschlagen.
struct HelpMenu: View {
    @State private var showNews = false

    var body: some View {
        Menu {
            Button { showNews = true } label: { Label("Was ist neu?", systemImage: "sparkles") }
            Divider()
            Button { NSWorkspace.shared.open(Feedback.url(.bug)) } label: { Label("Fehler melden …", systemImage: "ladybug") }
            Button { NSWorkspace.shared.open(Feedback.url(.idea)) } label: { Label("Funktion vorschlagen …", systemImage: "lightbulb") }
        } label: {
            Image(systemName: "questionmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(Desk.dim)
                .frame(width: 38, height: 38).background(Color(white: 0.96).opacity(0.04), in: Circle()).contentShape(Circle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("Neuigkeiten und Rückmeldung").accessibilityLabel("Neuigkeiten und Rückmeldung")
        .sheet(isPresented: $showNews) { WhatsNew().dialogStyle() }
    }
}

/// Zeigt CHANGELOG.md: Überschriften je Version, darunter die Punkte.
struct WhatsNew: View {
    @Environment(\.dismiss) private var dismiss

    /// (Überschrift, Punkte) je Version.
    static func sections(_ text: String) -> [(title: String, items: [String])] {
        var result = [(title: String, items: [String])]()
        for line in text.components(separatedBy: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.hasPrefix("## ") { result.append((String(line.dropFirst(3)), [])) }
            else if line.hasPrefix("- "), !result.isEmpty { result[result.count - 1].items.append(String(line.dropFirst(2))) }
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Was ist neu?").font(.system(size: 22, weight: .semibold))
                Spacer()
                Button("Fertig") { dismiss() }.buttonStyle(.primaryPill).keyboardShortcut(.defaultAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(Self.sections(Feedback.changelog).enumerated()), id: \.offset) { _, section in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Version " + section.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Desk.dim)
                            ForEach(section.items, id: \.self) { item in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Circle().fill(Desk.accent).frame(width: 5, height: 5).offset(y: -2)
                                    Text(item).font(.system(size: 13.5)).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 320)
            Text("Du nutzt Mochi Squad " + Feedback.appVersion + ".").font(.system(size: 12)).foregroundStyle(Desk.dim)
        }.padding(22).frame(width: 480)
    }
}
