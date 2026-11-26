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

/// Shows the changelog: one heading per version, its items below.
struct WhatsNew: View {
    @Environment(\.dismiss) private var dismiss

    /// (heading, items) per version.
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
                Text(t("What's new?", "Was ist neu?")).font(.system(size: 22, weight: .semibold))
                Spacer()
                Button(t("Done", "Fertig")) { dismiss() }.buttonStyle(.primaryPill).keyboardShortcut(.defaultAction)
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
            Text(t("You are using Mochi Squad \(Feedback.appVersion).", "Du nutzt Mochi Squad \(Feedback.appVersion)."))
                .font(.system(size: 12)).foregroundStyle(Desk.dim)
        }.padding(22).frame(width: 480)
    }
}
