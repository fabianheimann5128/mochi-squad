import Foundation

/// How much of a subscription's plan limit is used, as the clients last reported it (see scripts/limits.py).
struct PlanLimit: Decodable, Identifiable, Equatable {
    struct Window: Decodable, Equatable {
        let percent: Double
        /// Unix time at which the window starts over, if the client said so.
        let resets: Double?
    }
    let id: String
    let five: Window?
    let week: Window?
    let stamp: String?

    var highest: Double { max(five?.percent ?? 0, week?.percent ?? 0) }
    var date: Date? { stamp.flatMap { PlanLimit.parse($0) } }

    static func parse(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

/// Keeps the plan limits of all subscriptions current and warns before one runs out: at 80 % and again at 95 %,
/// once per window and threshold, in the app and through the connected messengers.
@MainActor final class LimitStore: ObservableObject {
    @Published private(set) var limits = [PlanLimit]()
    /// Called with a warning text when a limit crosses a threshold.
    var onWarning: ((String) -> Void)?
    static let thresholds: [Double] = [80, 95]
    private var warned = [String: Double]()
    private var timer: Timer?

    func start() {
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func refresh() async {
        guard let fresh = try? await PythonTool.run("limits", [], as: [PlanLimit].self) else { return }
        if fresh != limits { limits = fresh }
        check(fresh)
    }

    /// The thresholds `limit` crossed that were not reported yet; remembers them as reported.
    func crossed(_ limit: PlanLimit) -> [(window: String, percent: Double, threshold: Double, resets: Double?)] {
        var result = [(window: String, percent: Double, threshold: Double, resets: Double?)]()
        for (name, window) in [("five", limit.five), ("week", limit.week)] {
            guard let window else { continue }
            let key = limit.id + "." + name + "." + String(Int(window.resets ?? 0))
            guard let threshold = Self.thresholds.last(where: { window.percent >= $0 }), threshold > (warned[key] ?? 0) else { continue }
            warned[key] = threshold
            result.append((name, window.percent, threshold, window.resets))
        }
        return result
    }

    private func check(_ fresh: [PlanLimit]) {
        for limit in fresh {
            for hit in crossed(limit) {
                let percent = Int(hit.percent.rounded())
                let span = hit.window == "five" ? t("5-hour limit", "5-Stunden-Limit") : t("weekly limit", "Wochenlimit")
                let reset = hit.resets.map { " " + t("It starts over \(Self.when($0)).", "Es beginnt \(Self.when($0)) neu.") } ?? ""
                onWarning?(t("\(name(limit.id)) has used \(percent) % of its \(span).", "\(name(limit.id)) hat \(percent) % des \(span)s verbraucht.") + reset)
            }
        }
    }

    /// Name of an extra ChatGPT plan by its id; set by the app from the settings.
    var accountName: (String) -> String? = { _ in nil }
    /// "Claude", "ChatGPT", or "ChatGPT · <plan>" for an extra one.
    func name(_ id: String) -> String {
        if id == "claude" { return "Claude" }
        if id == "codex" { return "ChatGPT" }
        return accountName(String(id.dropFirst("codex:".count))).map { "ChatGPT · " + $0 } ?? "ChatGPT"
    }

    static func when(_ unix: Double) -> String {
        let date = Date(timeIntervalSince1970: unix)
        let locale = L10n.language.locale
        if Calendar.current.isDateInToday(date) { return t("today at ", "heute um ") + date.formatted(.dateTime.hour().minute().locale(locale)) }
        return date.formatted(.dateTime.weekday(.wide).hour().minute().locale(locale))
    }
}
