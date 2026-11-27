import Foundation
import UserNotifications

/// Mac notifications for results that arrive while the user looks elsewhere, such as a finished routine.
/// macOS asks once for permission; without it, nothing is shown and nothing fails.
enum Notifier {
    static func post(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = String(body.prefix(400))
            content.sound = .default
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    /// The part of a routine's answer that fits a notification: the last lines, without blank ones.
    static func summary(of output: String, limit: Int = 300) -> String {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var picked = [String]()
        for line in lines.reversed() {
            if picked.joined(separator: " ").count + line.count > limit, !picked.isEmpty { break }
            picked.insert(line, at: 0)
        }
        let text = picked.joined(separator: " ")
        return text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }
}
