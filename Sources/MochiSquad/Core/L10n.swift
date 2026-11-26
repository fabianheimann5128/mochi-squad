import Foundation

/// Interface language. English is the default; German can be picked during setup or in Settings.
/// Agents are not bound to it: they answer in the language they are addressed in.
enum Language: String, Codable, CaseIterable, Identifiable {
    case en, de
    var id: String { rawValue }
    var title: String { self == .en ? "English" : "Deutsch" }
    /// Locale for dates and for speech recognition.
    var locale: Locale { Locale(identifier: self == .en ? "en_US" : "de_DE") }
}

enum L10n {
    /// Set at launch and whenever the user switches language. Views are rebuilt on change (see RootView).
    static var language = Language.en
}

/// Picks the text for the current interface language. Both versions sit next to each other at the call site,
/// so a missing translation cannot happen and no key can drift from its text.
func t(_ en: String, _ de: String) -> String { L10n.language == .en ? en : de }
