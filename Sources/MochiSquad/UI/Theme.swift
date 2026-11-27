import SwiftUI

/// Design tokens (dark theme, modelled on Rakazo's packages/ui-tokens, see NOTICE).
enum Desk {
    static func rgb(_ red: Double, _ green: Double, _ blue: Double) -> Color {
        Color(.sRGB, red: red / 255, green: green / 255, blue: blue / 255)
    }
    static let canvas = rgb(10, 10, 10)          // --background
    static let card = rgb(35, 35, 35)            // --card, --muted
    static let incoming = card                   // reply bubble
    static let bubble = rgb(47, 107, 255)        // own messages: strong blue
    static let pillSelected = rgb(62, 62, 62)    // selected pill in pickers
    static let relayed = rgb(28, 40, 72)         // relayed message
    static let dialog = rgb(22, 22, 22)          // --dialog
    static let glass = rgb(44, 44, 46)           // --glass-fill
    static let glassStroke = Color(white: 0.99).opacity(0.15)
    static let selected = rgb(29, 29, 29)        // --sidebar-accent
    static let hover = rgb(33, 33, 33)           // --accent
    static let text = Color(white: 0.96)         // --foreground
    static let dim = Color(white: 0.96).opacity(0.66)
    static let faint = Color(white: 0.96).opacity(0.54)
    static let rule = Color(white: 0.96).opacity(0.06)
    static let edge = Color(white: 0.96).opacity(0.10)
    static let primary = rgb(245, 245, 245)      // --primary
    static let onPrimary = rgb(18, 18, 18)
    static let accent = rgb(77, 155, 255)        // --link, --unread
    static let success = rgb(0, 186, 105)
    static let working = rgb(14, 159, 90)
    static let warning = rgb(226, 134, 0)
    static let danger = rgb(255, 100, 99)

    static func railWidth(_ width: CGFloat) -> CGFloat { min(340, max(250, width * 0.22)).rounded() }
    static func panelWidth(_ width: CGFloat) -> CGFloat { min(420, max(300, width * 0.25)).rounded() }
}

/// Button as a pill. `primary` is white like Rakazo's main buttons.
struct PillButtonStyle: ButtonStyle {
    var primary = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: primary ? .semibold : .medium)).lineLimit(1).fixedSize()
            .foregroundStyle(primary ? Desk.onPrimary : Desk.text)
            .padding(.horizontal, 13).frame(minHeight: 30)
            .background(primary ? Desk.primary : Desk.hover, in: Capsule())
            .overlay { if !primary { Capsule().strokeBorder(Desk.edge) } }
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Capsule())
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    static var pill: PillButtonStyle { PillButtonStyle() }
    static var primaryPill: PillButtonStyle { PillButtonStyle(primary: true) }
}

/// Picker made of grey pills inside a capsule.
struct PillPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]
    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let chosen = option.0 == selection
                Button { selection = option.0 } label: {
                    Text(option.1).font(.system(size: 12.5, weight: chosen ? .semibold : .regular))
                        .foregroundStyle(chosen ? Desk.text : Desk.dim)
                        .padding(.horizontal, 11).frame(height: 26)
                        .background { if chosen { Capsule().fill(Desk.pillSelected) } }
                        .contentShape(Capsule())
                }.buttonStyle(.plain).accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }.padding(3).background(Desk.card, in: Capsule()).overlay { Capsule().strokeBorder(Desk.edge) }.fixedSize()
    }
}

/// Round button on the left of the composer.
struct RoundGlyph: View {
    let name: String
    var body: some View {
        Image(systemName: name).font(.system(size: 14, weight: .medium)).foregroundStyle(Desk.dim)
            .frame(width: 32, height: 32).background(Desk.card, in: Circle())
            .overlay { Circle().strokeBorder(Desk.edge) }.contentShape(Circle())
    }
}

/// Send button on the right of the composer.
struct SendGlyph: View {
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        Image(systemName: "arrow.up").font(.system(size: 14, weight: .semibold))
            .foregroundStyle(enabled ? Desk.onPrimary : Desk.text.opacity(0.3)).frame(width: 32, height: 32)
            .background(enabled ? Desk.primary : Desk.primary.opacity(0.13), in: Circle()).contentShape(Circle())
    }
}

/// Centred grey line, e.g. "Today 9:40" or a notice in the team chat.
struct NoticeLine: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 14)).foregroundStyle(Desk.dim).multilineTextAlignment(.center)
            .padding(.horizontal, 14).padding(.vertical, 4).frame(maxWidth: .infinity)
    }
}

/// "is typing …" as three travelling dots in a reply bubble.
struct TypingBubble: View {
    let name: String
    @Environment(\.accessibilityReduceMotion) private var still
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.35)) { context in
            let step = still ? 1 : Int(context.date.timeIntervalSinceReferenceDate / 0.35) % 3
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    Circle().fill(Color(white: index == step ? 0.85 : 0.45)).frame(width: 6, height: 6)
                }
            }.padding(.horizontal, 16).padding(.vertical, 13)
                .background(Desk.incoming, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }.accessibilityLabel(t(name + " is typing", name + " schreibt"))
    }
}

/// Floating pill with a glass look (title in the chat header).
struct GlassPill<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        HStack(spacing: 8, content: content)
            .padding(.leading, 4).padding(.trailing, 14).padding(.vertical, 4).frame(minHeight: 38)
            .background(Desk.glass, in: Capsule()).overlay { Capsule().strokeBorder(Desk.glassStroke) }
            .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
    }
}

extension View {
    /// Composer as a capsule: send on the right, a round button on the left.
    func composerCapsule() -> some View {
        padding(.leading, 12).padding(.trailing, 10).padding(.vertical, 10).frame(minHeight: 52)
            .background(Desk.card, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Desk.edge).allowsHitTesting(false) }
    }

    /// Input field or card with a border.
    func field(_ radius: CGFloat = 10, fill: Color = Desk.card) -> some View {
        background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Desk.edge).allowsHitTesting(false) }
    }

    /// Dialog surface: --dialog, pill buttons, dark scheme.
    func dialogStyle() -> some View {
        buttonStyle(.pill).tint(Desk.accent).preferredColorScheme(.dark).foregroundStyle(Desk.text).background(Desk.dialog)
    }
}

/// A compact menu in the shape of a pill: the current choice with a small chevron; the options open on click.
struct PillMenu: View {
    let title: String
    let options: [(value: String, label: String)]
    let current: String
    let pick: (String) -> Void

    var body: some View {
        Menu {
            ForEach(options, id: \.value) { option in
                Button { pick(option.value) } label: {
                    if option.value == current { Label(option.label, systemImage: "checkmark") } else { Text(option.label) }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Desk.dim)
            }
            .foregroundStyle(Desk.text).padding(.horizontal, 12).frame(height: 32)
            .background(Desk.card, in: Capsule()).overlay { Capsule().strokeBorder(Desk.edge) }.contentShape(Capsule())
        }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }
}

/// Ring chart: segments in order, clockwise from the top, with small gaps; the centre shows `label`.
struct Donut<Label: View>: View {
    let parts: [(color: Color, value: Double)]
    var lineWidth: CGFloat = 12
    @ViewBuilder let label: () -> Label

    var body: some View {
        let total = max(parts.reduce(0) { $0 + $1.value }, 0.0001)
        let gap = parts.count > 1 ? 0.006 : 0
        ZStack {
            Circle().stroke(Color.white.opacity(0.06), lineWidth: lineWidth)
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                let start = parts.prefix(index).reduce(0) { $0 + $1.value } / total
                let end = start + part.value / total
                Circle().trim(from: start + gap, to: max(start + gap, end - gap))
                    .stroke(part.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }
            label()
        }
        .padding(lineWidth / 2)
        .animation(.easeOut(duration: 0.4), value: parts.map(\.value))
    }
}
