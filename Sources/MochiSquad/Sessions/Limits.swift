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
        get { (UserDefaults.standard.dictionary(forKey: "usageWarnings.v3") as? [String: [Double]]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "usageWarnings.v3") }
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
    ///
    /// Each plan and window has a period in which every threshold warns once. With a reset time the period is the
    /// window up to that reset: a lower number within it (a correction, an older report) starts nothing new. Without
    /// one, the period begins with the first report seen and ends when the window's length has passed since then,
    /// by the reports' own dates, or when usage clearly drops. A report older than one already used is ignored, and a
    /// report without a date never counts as new by time alone. A passed reset, or a report older than the window
    /// itself, warns no more.
    func crossed(_ limit: PlanLimit, now: Date = Date()) -> [(window: String, percent: Double, threshold: Double, resets: Double?)] {
        var result = [(window: String, percent: Double, threshold: Double, resets: Double?)]()
        var store = warned
        let date = limit.date?.timeIntervalSince1970
        for (name, window, span) in [("five", limit.five, 5 * 3600.0), ("week", limit.week, 7 * 86400.0)] {
            guard let window else { continue }
            if let resets = window.resets, resets <= now.timeIntervalSince1970 { continue }
            if let date, now.timeIntervalSince1970 - date > span { continue }
            let key = limit.id + "." + name
            // [period, highest threshold reported, date of the newest report used (0: none), 1 if the period is a reset time]
            let old = store[key].flatMap { $0.count == 4 ? $0 : nil }
            if let date, let seen = old?[2], seen > 0, date < seen { continue }
            var period: Double, reported: Double
            if let resets = window.resets {
                period = resets
                reported = old.flatMap { $0[3] == 1 && $0[0] == resets ? $0[1] : nil } ?? 0
            } else if let old, old[3] == 0 {
                period = old[0]; reported = old[1]
                let expired = date.map { $0 - period > span } ?? false
                if expired || window.percent < 50 { period = date ?? period; reported = 0 }
            } else {
                period = date ?? now.timeIntervalSince1970; reported = 0
            }
            let seen = max(date ?? 0, old?[2] ?? 0)
            let kind: Double = window.resets == nil ? 0 : 1
            guard let threshold = Self.thresholds.last(where: { window.percent >= $0 }), threshold > reported else {
                store[key] = [period, reported, seen, kind]
                continue
            }
            store[key] = [period, threshold, seen, kind]
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
