import Foundation

/// How much of a subscription's plan limit is used, as the clients last reported it (see scripts/limits.py).
struct PlanLimit: Decodable, Identifiable, Equatable {
    struct Window: Decodable, Equatable {
        let percent: Double
        /// Unix time at which the window starts over, if the client said so.
        let resets: Double?

        init(percent: Double, resets: Double?) {
            self.percent = percent.isFinite ? min(100, max(0, percent)) : 0
            self.resets = resets.flatMap { $0.isFinite && $0 > 0 && $0 < 4_102_444_800 ? $0 : nil }
        }

        /// Values are checked here as well: whatever a file says, the app only works with 0–100 % and real times.
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let percent = try values.decode(Double.self, forKey: .percent)
            guard percent.isFinite else { throw DecodingError.dataCorruptedError(forKey: .percent, in: values, debugDescription: "not finite") }
            self.init(percent: percent, resets: try? values.decodeIfPresent(Double.self, forKey: .resets))
        }
        private enum CodingKeys: String, CodingKey { case percent, resets }
    }
    let id: String
    let five: Window?
    let week: Window?
    let stamp: String?

    init(id: String, five: Window?, week: Window?, stamp: String?) {
        self.id = id; self.five = five; self.week = week; self.stamp = stamp
    }

    /// A broken window is dropped on its own; the rest of the entry stays.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        five = try? values.decodeIfPresent(Window.self, forKey: .five)
        week = try? values.decodeIfPresent(Window.self, forKey: .week)
        stamp = try? values.decodeIfPresent(String.self, forKey: .stamp)
    }
    private enum CodingKeys: String, CodingKey { case id, five, week, stamp }

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
    /// Per plan and window: the period it belongs to and the highest threshold reported in it. Kept across launches.
    private var warned: [String: [Double]] {
        get { (UserDefaults.standard.dictionary(forKey: "usageWarnings.v2") as? [String: [Double]]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "usageWarnings.v2") }
    }
    private var timer: Timer?

    func start() {
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    /// Decodes each entry on its own, so one unreadable plan never hides the others.
    private struct Lenient: Decodable {
        let limit: PlanLimit?
        init(from decoder: Decoder) throws { limit = try? PlanLimit(from: decoder) }
    }

    func refresh() async {
        guard let rows = try? await PythonTool.run("limits", [], as: [Lenient].self) else { return }
        let fresh = rows.compactMap(\.limit)
        if fresh != limits { limits = fresh }
        check(fresh)
    }

    /// The thresholds `limit` crossed that were not reported yet; remembers them as reported.
    /// A window whose reset time has passed, or whose report is older than the window itself, warns no more. Without a
    /// reset time, the period follows from the report's date, and a clear drop in usage counts as a new period.
    func crossed(_ limit: PlanLimit, now: Date = Date()) -> [(window: String, percent: Double, threshold: Double, resets: Double?)] {
        var result = [(window: String, percent: Double, threshold: Double, resets: Double?)]()
        var store = warned
        for (name, window, span) in [("five", limit.five, 5 * 3600.0), ("week", limit.week, 7 * 86400.0)] {
            guard let window else { continue }
            if let resets = window.resets, resets <= now.timeIntervalSince1970 { continue }
            if let date = limit.date, now.timeIntervalSince(date) > span { continue }
            let period = window.resets ?? ((limit.date ?? now).timeIntervalSince1970 / span).rounded(.down)
            let key = limit.id + "." + name
            var reported = store[key].flatMap { $0.count == 2 && $0[0] == period ? $0[1] : nil } ?? 0
            if window.percent < 50 { reported = 0 }
            guard let threshold = Self.thresholds.last(where: { window.percent >= $0 }), threshold > reported else {
                store[key] = [period, reported]
                continue
            }
            store[key] = [period, threshold]
            result.append((name, window.percent, threshold, window.resets))
        }
        warned = store
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
