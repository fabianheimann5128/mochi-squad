import SwiftUI

/// Colour of a usage level: calm below 80 %, amber up to 95 %, red above.
func usageColor(_ percent: Double) -> Color {
    percent >= 95 ? Desk.danger : percent >= 80 ? Desk.warning : Desk.accent
}

/// Round gauge for the icon rail: the fullest limit of all subscriptions at a glance. A click shows each one.
struct UsageGauge: View {
    @EnvironmentObject private var limits: LimitStore
    @State private var open = false
    @State private var hovered = false

    var body: some View {
        let highest = limits.limits.map(\.highest).max()
        Button { open.toggle() } label: {
            ZStack {
                Circle().stroke(Color(white: 0.96).opacity(0.10), lineWidth: 3)
                if let highest {
                    Circle().trim(from: 0, to: max(0.02, highest / 100))
                        .stroke(usageColor(highest), style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
                    Text("\(Int(highest.rounded()))").font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(Desk.text)
                } else {
                    Image(systemName: "gauge.with.dots.needle.33percent").font(.system(size: 14, weight: .medium)).foregroundStyle(Desk.dim)
                }
            }
            .frame(width: 30, height: 30).frame(width: 40, height: 40)
            .background(Color(white: 0.96).opacity(open ? 0.14 : hovered ? 0.09 : 0.05), in: Circle())
            .contentShape(Circle())
        }
        .buttonStyle(.plain).onHover { hovered = $0 }
        .help(t("Plan usage", "Abo-Verbrauch")).accessibilityLabel(t("Plan usage", "Abo-Verbrauch") + (highest.map { ": \(Int($0.rounded())) %" } ?? ""))
        .popover(isPresented: $open, arrowEdge: .trailing) { UsagePanel().environmentObject(limits) }
    }
}

/// The plan limits of every subscription, with time to reset and how fresh the numbers are.
struct UsagePanel: View {
    @EnvironmentObject private var limits: LimitStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(t("Plan usage", "Abo-Verbrauch")).font(.system(size: 16, weight: .semibold))
                Text(t("What your agents used of your subscriptions. You get a warning at 80 % and 95 %.",
                       "Was deine Agenten von deinen Abos verbraucht haben. Bei 80 % und 95 % bekommst du eine Warnung."))
                    .font(.system(size: 12)).foregroundStyle(Desk.dim).fixedSize(horizontal: false, vertical: true)
            }
            if limits.limits.isEmpty {
                Text(t("The numbers appear after your agents' first answers.", "Die Zahlen erscheinen nach den ersten Antworten deiner Agenten."))
                    .font(.system(size: 12.5)).foregroundStyle(Desk.dim)
            }
            ForEach(limits.limits) { limit in
                VStack(alignment: .leading, spacing: 9) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(limits.name(limit.id)).font(.system(size: 13.5, weight: .semibold))
                        Spacer()
                        if let date = limit.date {
                            Text(t("as of ", "Stand ") + date.formatted(.relative(presentation: .named).locale(L10n.language.locale)))
                                .font(.system(size: 11)).foregroundStyle(Desk.faint)
                        }
                    }
                    if let five = limit.five { bar(t("5 hours", "5 Stunden"), five) }
                    if let week = limit.week { bar(t("Week", "Woche"), week) }
                }
                .padding(12).background(Desk.card.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(18).frame(width: 300)
        .task { await limits.refresh() }
    }

    private func bar(_ title: String, _ window: PlanLimit.Window) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).font(.system(size: 12)).foregroundStyle(Desk.dim)
                Spacer()
                Text("\(Int(window.percent.rounded())) %").font(.system(size: 12, weight: .semibold).monospacedDigit())
            }
            GeometryReader { area in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule().fill(usageColor(window.percent)).frame(width: max(4, area.size.width * min(1, window.percent / 100)))
                }
            }.frame(height: 5)
            if let resets = window.resets {
                // A window whose reset time has passed shows an old value until the client reports again.
                Text(resets > Date().timeIntervalSince1970 ? t("Starts over ", "Beginnt neu ") + LimitStore.when(resets)
                                                          : t("Has started over since; new numbers follow with the next answer", "Inzwischen neu gestartet; neue Zahlen kommen mit der nächsten Antwort"))
                    .font(.system(size: 11)).foregroundStyle(Desk.faint)
            }
        }
    }
}
