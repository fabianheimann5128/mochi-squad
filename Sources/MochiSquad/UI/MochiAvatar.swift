import SwiftUI

// Mochi-Avatare. Körper- und Handumriss, Farbstufen und Lichtebenen sind an Rakazos Maskottchen angelehnt
// (Apache-2.0, siehe NOTICE); Bauformen, Kopfteile, Augen und Extras sind eigene Ergänzungen von Mochi Squad.

/// Aussehen eines Mochis. Gespeichert als Schlüssel „mochi:<bau>.<kopf>.<augen>.<extra>:<RRGGBB>“.
struct MochiLook: Equatable, Hashable {
    enum Build: Int, CaseIterable { case classic, tall, chubby, small }
    enum Top: Int, CaseIterable {
        case none, bear, cat, bunny, antenna, horns, tuft, sprout
        case headphones, cap, beanie, crown, propeller, flower, spikes
    }
    enum Eyes: Int, CaseIterable { case oval, happy, wink, big, sleepy, shiny, focused, star }
    enum Extra: Int, CaseIterable { case none, glasses, blush, bow, scarf, freckles, moustache, badge }

    var build = Build.classic
    var top = Top.none
    var eyes = Eyes.oval
    var extra = Extra.none
    var hex = "FFFFFF"

    /// Bot-Farben (an Rakazos Palette angelehnt).
    static let palette: [(name: String, hex: String)] = [
        ("Weiß", "FFFFFF"), ("Violett", "A97EFE"), ("Smaragd", "00C972"), ("Orange", "FF781C"),
        ("Cyan", "1CC3B0"), ("Kobaltblau", "2A92FE"), ("Bernstein", "FFAF38"), ("Karamell", "A27952"),
        ("Karminrot", "FF3E51"), ("Neonpink", "FF5EB1"), ("Schiefer", "94A3B8")
    ]

    var key: String { "mochi:\(build.rawValue).\(top.rawValue).\(eyes.rawValue).\(extra.rawValue):\(hex)" }

    init(build: Build = .classic, top: Top = .none, eyes: Eyes = .oval, extra: Extra = .none, hex: String = "FFFFFF") {
        self.build = build; self.top = top; self.eyes = eyes; self.extra = extra; self.hex = hex
    }

    /// Liest einen gespeicherten Schlüssel. Alles andere (auch alte Schlüssel) ergibt ein festes Aussehen aus dem Text.
    init(key: String) {
        let parts = key.split(separator: ":")
        if parts.count == 3, parts[0] == "mochi" {
            let v = parts[1].split(separator: ".").compactMap { Int($0) }
            if v.count == 4, let b = Build(rawValue: v[0]), let t = Top(rawValue: v[1]), let e = Eyes(rawValue: v[2]),
               let x = Extra(rawValue: v[3]), parts[2].count == 6, UInt32(parts[2], radix: 16) != nil {
                self.init(build: b, top: t, eyes: e, extra: x, hex: String(parts[2]).uppercased())
                return
            }
        }
        var generator = SeededGenerator(seed: Self.stableHash(key))
        self = Self.random(using: &generator)
    }

    /// Zufälliges, aber ausgewogenes Aussehen für einen neuen Agenten.
    static func random<G: RandomNumberGenerator>(using generator: inout G) -> MochiLook {
        MochiLook(build: Build.allCases.randomElement(using: &generator)!,
                  top: Top.allCases.randomElement(using: &generator)!,
                  eyes: Eyes.allCases.randomElement(using: &generator)!,
                  extra: Extra.allCases.randomElement(using: &generator)!,
                  hex: palette.dropFirst().randomElement(using: &generator)!.hex)
    }
    static func random() -> MochiLook {
        var generator = SystemRandomNumberGenerator()
        return random(using: &generator)
    }

    /// FNV-1a: über Programmstarts hinweg gleich (anders als `hashValue`).
    static func stableHash(_ text: String) -> UInt64 {
        text.utf8.reduce(14_695_981_039_346_656_037) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
    }

    var color: Color { Mochi.color(hex) }
}

/// Deterministischer Zufall (SplitMix64) für feste Aussehen aus einem Text.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Zeichenformen und Farben der Mochis (Koordinaten 0 … 100, Fuß bei y = 100).
enum Mochi {
    static let body: Path = {
        var p = Path()
        p.move(to: CGPoint(x: -1.759, y: 76.33))
        p.addCurve(to: CGPoint(x: 10.602, y: 56.566), control1: CGPoint(x: 0.959, y: 69.782), control2: CGPoint(x: 7.117, y: 63.647))
        p.addCurve(to: CGPoint(x: 17.063, y: 33.747), control1: CGPoint(x: 14.086, y: 49.486), control2: CGPoint(x: 14.898, y: 41.46))
        p.addCurve(to: CGPoint(x: 28.465, y: 13.175), control1: CGPoint(x: 19.227, y: 26.034), control2: CGPoint(x: 22.744, y: 18.634))
        p.addCurve(to: CGPoint(x: 50.032, y: 4.183), control1: CGPoint(x: 34.186, y: 7.716), control2: CGPoint(x: 42.11, y: 4.197))
        p.addCurve(to: CGPoint(x: 71.581, y: 13.121), control1: CGPoint(x: 57.954, y: 4.169), control2: CGPoint(x: 65.874, y: 7.66))
        p.addCurve(to: CGPoint(x: 82.945, y: 33.732), control1: CGPoint(x: 77.288, y: 18.582), control2: CGPoint(x: 80.783, y: 26.014))
        p.addCurve(to: CGPoint(x: 89.402, y: 56.543), control1: CGPoint(x: 85.107, y: 41.449), control2: CGPoint(x: 85.935, y: 49.451))
        p.addCurve(to: CGPoint(x: 101.767, y: 76.305), control1: CGPoint(x: 92.869, y: 63.634), control2: CGPoint(x: 98.975, y: 69.814))
        p.addLine(to: CGPoint(x: 108.0, y: 108.0))
        p.addLine(to: CGPoint(x: -8.0, y: 108.0))
        p.closeSubpath()
        return p
    }()
    static let leftHand: Path = {
        var p = Path()
        p.move(to: CGPoint(x: -2.0, y: 74.0))
        p.addCurve(to: CGPoint(x: 26.0, y: 83.0), control1: CGPoint(x: 7.0, y: 68.0), control2: CGPoint(x: 22.0, y: 75.0))
        p.addCurve(to: CGPoint(x: 19.0, y: 107.0), control1: CGPoint(x: 31.0, y: 93.0), control2: CGPoint(x: 26.0, y: 102.0))
        p.addLine(to: CGPoint(x: -2.0, y: 107.0))
        p.closeSubpath()
        return p
    }()
    static let rightHand: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 102.0, y: 73.0))
        p.addCurve(to: CGPoint(x: 74.0, y: 83.0), control1: CGPoint(x: 92.0, y: 68.0), control2: CGPoint(x: 78.0, y: 75.0))
        p.addCurve(to: CGPoint(x: 81.0, y: 107.0), control1: CGPoint(x: 69.0, y: 93.0), control2: CGPoint(x: 74.0, y: 102.0))
        p.addLine(to: CGPoint(x: 102.0, y: 107.0))
        p.closeSubpath()
        return p
    }()

    static let eyeInk = Color(.sRGB, red: 16 / 255, green: 16 / 255, blue: 20 / 255)

    static func rgb(_ hex: String) -> (Double, Double, Double) {
        let v = UInt32(hex, radix: 16) ?? 0xFFFFFF
        return (Double(v >> 16 & 0xFF), Double(v >> 8 & 0xFF), Double(v & 0xFF))
    }
    static func color(_ hex: String, factor: Double = 1) -> Color {
        let (r, g, b) = rgb(hex)
        return Color(.sRGB, red: min(255, r * factor) / 255, green: min(255, g * factor) / 255, blue: min(255, b * factor) / 255)
    }
    /// Lichtkante: Grundton zu 90 % Richtung Weiß.
    static func rim(_ hex: String) -> Color {
        let (r, g, b) = rgb(hex)
        return Color(.sRGB, red: (r + (255 - r) * 0.9) / 255, green: (g + (255 - g) * 0.9) / 255, blue: (b + (255 - b) * 0.9) / 255)
    }
    /// Dunkle Augen, solange sie sich ausreichend vom Körper abheben (Kontrast nach WCAG ≥ 3,5).
    static func darkEyes(_ hex: String) -> Bool {
        func channel(_ c: Double) -> Double { let s = c / 255; return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4) }
        let (r, g, b) = rgb(hex)
        let body = 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
        let ink = 0.2126 * channel(16) + 0.7152 * channel(16) + 0.0722 * channel(20)
        return (max(body, ink) + 0.05) / (min(body, ink) + 0.05) >= 3.5
    }

    /// Kopfteile, die mit dem Körper verschmelzen und dieselbe Lichtgestaltung bekommen (Körperkoordinaten).
    static func topShape(_ top: MochiLook.Top) -> Path {
        var p = Path()
        switch top {
        case .none, .sprout, .headphones, .cap, .beanie, .crown, .propeller, .flower: break
        case .bear:
            p.addEllipse(in: CGRect(x: 22, y: 6, width: 19, height: 19))
            p.addEllipse(in: CGRect(x: 59, y: 6, width: 19, height: 19))
        case .cat:
            // Spitze Ohren: außen steil, innen flacher, mit leicht gerundeter Spitze.
            for side in [-1.0, 1.0] {
                func at(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: 50 + side * x, y: y) }
                p.move(to: at(31, 32))
                p.addLine(to: at(29, 1))
                p.addQuadCurve(to: at(25, -2), control: at(28, -3))
                p.addLine(to: at(9, 14))
                p.closeSubpath()
            }
        case .bunny:
            p.addRoundedRect(in: CGRect(x: 30, y: -20, width: 12, height: 36), cornerSize: CGSize(width: 6, height: 6))
            p.addRoundedRect(in: CGRect(x: 58, y: -20, width: 12, height: 36), cornerSize: CGSize(width: 6, height: 6))
        case .antenna:
            p.addRoundedRect(in: CGRect(x: 48.8, y: -6, width: 2.4, height: 14), cornerSize: CGSize(width: 1.2, height: 1.2))
            p.addEllipse(in: CGRect(x: 45, y: -13, width: 10, height: 10))
        case .horns:
            for (base, tip) in [(CGPoint(x: 33, y: 13), CGPoint(x: 28, y: -2)), (CGPoint(x: 67, y: 13), CGPoint(x: 72, y: -2))] {
                p.move(to: CGPoint(x: base.x - 6, y: base.y))
                p.addQuadCurve(to: tip, control: CGPoint(x: base.x - 5, y: base.y - 9))
                p.addQuadCurve(to: CGPoint(x: base.x + 6, y: base.y), control: CGPoint(x: tip.x + (base.x > 50 ? -2 : 2), y: base.y - 3))
                p.closeSubpath()
            }
        case .tuft:
            for (x, y, r) in [(42.0, 6.0, 6.0), (50.0, 1.5, 7.0), (58.0, 6.0, 6.0)] {
                p.addEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
            }
        case .spikes:
            for (x, tipX, tipY) in [(36.0, 31.0, -3.0), (45.0, 44.0, -8.0), (55.0, 57.0, -7.0), (64.0, 70.0, -1.0)] {
                p.move(to: CGPoint(x: x - 6, y: 14))
                p.addLine(to: CGPoint(x: tipX, y: tipY))
                p.addLine(to: CGPoint(x: x + 6, y: 14))
                p.closeSubpath()
            }
        }
        return p
    }

    /// Körper und Kopfteil als eine Fläche (echte Vereinigung, unabhängig von der Zeichenrichtung der Teile).
    static func silhouette(_ top: MochiLook.Top) -> Path {
        let extra = topShape(top)
        return extra.isEmpty ? body : body.union(extra)
    }

    /// Kopfbedeckung, die exakt der Kopfkontur folgt: der Körper oberhalb von `cut`, leicht vergrößert wie aufgesetzt.
    static func headCover(cut: CGFloat, grow: CGFloat = 1.06) -> Path {
        let top = body.intersection(Path(CGRect(x: -30, y: -30, width: 160, height: 30 + cut)))
        return top.applying(CGAffineTransform(translationX: 50, y: cut).scaledBy(x: grow, y: grow).translatedBy(x: -50, y: -cut))
    }

    /// Wie stark die Figur für Kopfteile verkleinert wird, damit nichts aus der Kachel ragt.
    static func fit(_ top: MochiLook.Top) -> Double {
        switch top {
        case .none: return 1
        case .bunny: return 0.78
        case .antenna, .sprout, .propeller, .crown, .beanie: return 0.84
        case .headphones: return 0.86
        default: return 0.9
        }
    }
    static func buildScale(_ build: MochiLook.Build) -> (x: Double, y: Double) {
        switch build {
        case .classic: return (1, 1)
        case .tall: return (0.86, 1.06)
        case .chubby: return (1.1, 0.9)
        case .small: return (0.9, 0.82)
        }
    }
}

private extension GraphicsContext {
    /// Elliptischer Radialverlauf, auf `clip` beschnitten (wie SVG-radialGradient mit gradientTransform).
    func ellipseFill(_ clip: Path, center: CGPoint, rx: CGFloat, ry: CGFloat, radius: CGFloat = 1, stops: [Gradient.Stop]) {
        var c = self
        c.clip(to: clip)
        c.translateBy(x: center.x, y: center.y)
        c.scaleBy(x: rx, y: ry)
        c.fill(Path(CGRect(x: -3, y: -3, width: 6, height: 6)),
               with: .radialGradient(Gradient(stops: stops), center: .zero, startRadius: 0, endRadius: radius))
    }
    /// Radialverlauf in den Maßen der Form (objectBoundingBox): cx, cy, r als Anteile.
    func boxFill(_ shape: Path, cx: CGFloat, cy: CGFloat, r: CGFloat, stops: [Gradient.Stop]) {
        let box = shape.boundingRect
        ellipseFill(shape, center: CGPoint(x: box.minX + cx * box.width, y: box.minY + cy * box.height),
                    rx: r * box.width, ry: r * box.height, stops: stops)
    }
}

/// Avatar eines Agenten. Statisch gezeichnet; nur wer gerade arbeitet, atmet und blinzelt (spart Rechenzeit).
struct MochiAvatar: View {
    let key: String
    let size: CGFloat
    var working = false
    @Environment(\.accessibilityReduceMotion) private var still

    var body: some View {
        let look = MochiLook(key: key)
        Group {
            if working && !still {
                TimelineView(.animation(minimumInterval: 1 / 20)) { moment in
                    let t = moment.date.timeIntervalSinceReferenceDate
                    let phase = t.truncatingRemainder(dividingBy: 3.6)
                    MochiCanvas(look: look, breathe: (1 - cos(t * 2 * .pi / 2.2)) / 2, blink: phase < 0.16 ? sin(phase / 0.16 * .pi) : 0)
                }
            } else {
                MochiCanvas(look: look, breathe: 0, blink: 0)
            }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

/// Eine Mochi-Figur auf ihrer Kachel.
struct MochiCanvas: View, Equatable {
    let look: MochiLook
    var breathe: Double = 0
    var blink: Double = 0
    /// Ohne Kachel zeichnen, z. B. für das App-Icon mit eigenem Hintergrund.
    var showsPlate = true

    var body: some View {
        Canvas { ctx, canvas in
            let s = min(canvas.width, canvas.height) / 100
            ctx.scaleBy(x: s, y: s)
            let plate = Path(roundedRect: CGRect(x: 0, y: 0, width: 100, height: 100), cornerRadius: 23, style: .continuous)
            ctx.clip(to: plate)
            if showsPlate { ctx.fill(plate, with: .color(Color(.sRGB, red: 20 / 255, green: 20 / 255, blue: 20 / 255))) }
            draw(&ctx)
            if showsPlate {
                ctx.stroke(Path(roundedRect: CGRect(x: 0.5, y: 0.5, width: 99, height: 99), cornerRadius: 22.5, style: .continuous),
                           with: .color(Color.white.opacity(0.1)), lineWidth: 1)
            }
        }
    }

    private func draw(_ ctx: inout GraphicsContext) {
        let hex = look.hex
        let base = Mochi.color(hex), edge = Mochi.color(hex, factor: 0.96), shadow = Mochi.color(hex, factor: 0.8)
        let flank = Mochi.color(hex, factor: 0.58), contact = Mochi.color(hex, factor: 0.42), rim = Mochi.rim(hex)
        var body = ctx
        // Fuß bleibt stehen: Bauform, Platz für Kopfteile und Atmen skalieren um den unteren Rand.
        let fit = Mochi.fit(look.top), build = Mochi.buildScale(look.build)
        body.translateBy(x: 50, y: 109)
        body.scaleBy(x: fit * build.x * (1 - 0.015 * breathe), y: fit * build.y * (1 + 0.035 * breathe))
        body.translateBy(x: -50, y: -100)
        let shape = Mochi.silhouette(look.top)

        body.boxFill(shape, cx: 0.57, cy: 0.30, r: 0.76, stops: [.init(color: base, location: 0), .init(color: base, location: 0.48),
                                                                 .init(color: edge, location: 1)])
        body.ellipseFill(shape, center: CGPoint(x: 0, y: 32), rx: 45, ry: 44, stops: [
            .init(color: flank.opacity(0.94), location: 0), .init(color: flank.opacity(0.94), location: 0.4),
            .init(color: flank.opacity(0.76), location: 0.65), .init(color: flank.opacity(0.22), location: 0.85),
            .init(color: flank.opacity(0), location: 1)])
        body.ellipseFill(shape, center: CGPoint(x: 57, y: 23.5), rx: 34, ry: 33, stops: [
            .init(color: .white.opacity(0.28), location: 0), .init(color: .white.opacity(0.12), location: 0.4), .init(color: .white.opacity(0), location: 1)])
        let area = Path(CGRect(x: -30, y: -40, width: 160, height: 160))
        // Obere Lichtkante: nach rechts heller, unten ausgeblendet, links oben gedämpft.
        body.drawLayer { layer in
            layer.ellipseFill(shape, center: CGPoint(x: 50.02, y: 49.42), rx: 35.35, ry: 45.39, radius: 1.1, stops: [
                .init(color: rim.opacity(0), location: 0), .init(color: rim.opacity(0), location: 0.818),
                .init(color: rim.opacity(0.035), location: 0.855), .init(color: rim.opacity(0.14), location: 0.882),
                .init(color: rim.opacity(0.42), location: 0.9), .init(color: rim.opacity(0.53), location: 0.918),
                .init(color: rim.opacity(0.2), location: 0.941), .init(color: rim.opacity(0), location: 0.973)])
            layer.blendMode = .destinationIn
            layer.fill(area, with: .linearGradient(Gradient(stops: [.init(color: .white.opacity(0.25), location: 0),
                                                                    .init(color: .white.opacity(0.72), location: 0.5), .init(color: .white, location: 1)]),
                                                   startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 100, y: 0)))
            layer.blendMode = .destinationOut
            layer.fill(area, with: .linearGradient(Gradient(stops: [.init(color: .black.opacity(0), location: 0), .init(color: .black.opacity(0), location: 0.36),
                                                                    .init(color: .black, location: 0.58), .init(color: .black, location: 1)]),
                                                   startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: 100)))
            layer.ellipseFill(area, center: CGPoint(x: 36, y: 19), rx: 8.4, ry: 10.5, stops: [
                .init(color: .black.opacity(0.6), location: 0), .init(color: .black.opacity(0.6), location: 0.9),
                .init(color: .black.opacity(0.5), location: 0.94), .init(color: .black.opacity(0), location: 0.965)])
        }
        // Seitliche Lichtkanten im unteren Teil.
        body.drawLayer { layer in
            for (center, strength) in [(CGPoint(x: -50, y: 30.68), 0.22), (CGPoint(x: 150, y: 30.56), 0.46)] {
                layer.ellipseFill(shape, center: center, rx: 66.25, ry: 63.2, radius: 1.1, stops: [
                    .init(color: rim.opacity(0), location: 0), .init(color: rim.opacity(0), location: 0.873),
                    .init(color: rim.opacity(strength), location: 0.891), .init(color: rim.opacity(strength), location: 0.912),
                    .init(color: rim.opacity(strength * 0.45), location: 0.93), .init(color: rim.opacity(0), location: 0.955)])
            }
            layer.blendMode = .destinationIn
            layer.fill(area, with: .linearGradient(Gradient(stops: [.init(color: .white.opacity(0), location: 0), .init(color: .white.opacity(0), location: 0.36),
                                                                    .init(color: .white, location: 0.58), .init(color: .white, location: 1)]),
                                                   startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: 100)))
        }
        // Kontaktschatten unter den Händen, dann die Hände mit eigenem Licht.
        for x in [24.5, 75.5] {
            body.ellipseFill(shape, center: CGPoint(x: x, y: 91), rx: 7.5, ry: 17, stops: [
                .init(color: contact.opacity(0.72), location: 0), .init(color: contact.opacity(0.64), location: 0.45),
                .init(color: contact.opacity(0.3), location: 0.65), .init(color: contact.opacity(0.04), location: 0.9),
                .init(color: contact.opacity(0), location: 1)])
        }
        for (hand, cx, peak) in [(Mochi.leftHand, 0.6, 0.15), (Mochi.rightHand, 0.4, 0.24)] {
            var clipped = body
            clipped.clip(to: Mochi.body)
            clipped.boxFill(hand, cx: cx, cy: 0.35, r: 0.76, stops: [.init(color: base, location: 0), .init(color: base, location: 0.28),
                                                                   .init(color: shadow, location: 1)])
            clipped.boxFill(hand, cx: cx, cy: 0.35, r: 0.62, stops: [.init(color: .white.opacity(peak), location: 0), .init(color: .white.opacity(0), location: 1)])
        }
        drawHeadwear(&body)
        let dark = Mochi.darkEyes(hex)
        let ink = dark ? Mochi.eyeInk : Color(white: 0.96)
        if look.extra == .blush { drawBlush(&body) }
        if look.extra == .freckles { drawFreckles(&body, ink: ink) }
        if look.extra == .scarf { drawScarf(&body) }
        if look.extra == .badge { drawBadge(&body) }
        drawEyes(&body, ink: ink, glint: dark ? Color(white: 0.96) : Mochi.eyeInk)
        if look.extra == .glasses { drawGlasses(&body, ink: ink) }
        if look.extra == .bow { drawBow(&body) }
        if look.extra == .moustache { drawMoustache(&body, ink: ink) }
    }

    private func drawEyes(_ ctx: inout GraphicsContext, ink: Color, glint: Color) {
        for (index, x) in [40.5, 59.5].enumerated() {
            var eye = ctx
            eye.translateBy(x: x, y: 40)
            let style = look.eyes == .wink && index == 1 ? MochiLook.Eyes.happy : look.eyes
            switch style {
            case .shiny:
                let w: CGFloat = 11, h: CGFloat = 14.5
                eye.scaleBy(x: 1, y: max(0.08, 1 - blink))
                eye.fill(Path(roundedRect: CGRect(x: -w / 2, y: -h / 2, width: w, height: h), cornerRadius: w / 2),
                         with: .linearGradient(Gradient(colors: [ink.opacity(0.82), ink]), startPoint: CGPoint(x: 0, y: -h / 2), endPoint: CGPoint(x: 0, y: h / 2)))
                if blink < 0.5 {
                    eye.fill(Path(ellipseIn: CGRect(x: -3.4, y: -5.2, width: 4.6, height: 4.6)), with: .color(glint.opacity(0.95)))
                    eye.fill(Path(ellipseIn: CGRect(x: 0.8, y: 1.8, width: 2.2, height: 2.2)), with: .color(glint.opacity(0.6)))
                }
            case .focused:
                eye.scaleBy(x: 1, y: max(0.08, 1 - blink))
                eye.fill(Path(roundedRect: CGRect(x: -5, y: -4.2, width: 10, height: 10.5), cornerRadius: 5), with: .color(ink))
                if blink < 0.5 { eye.fill(Path(ellipseIn: CGRect(x: -2.8, y: -2.6, width: 3, height: 3)), with: .color(glint.opacity(0.85))) }
                var brow = Path()
                let side: CGFloat = index == 0 ? 1 : -1
                brow.move(to: CGPoint(x: -side * 6.5, y: -10.5))
                brow.addLine(to: CGPoint(x: side * 5.5, y: -6.5))
                ctx.stroke(brow.applying(CGAffineTransform(translationX: x, y: 40)), with: .color(ink.opacity(0.9)),
                           style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
            case .star:
                var star = Path()
                for i in 0..<10 {
                    let radius: CGFloat = i % 2 == 0 ? 7.6 : 3.2
                    let angle = CGFloat(i) * .pi / 5 - .pi / 2
                    let point = CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
                    if i == 0 { star.move(to: point) } else { star.addLine(to: point) }
                }
                star.closeSubpath()
                eye.fill(star, with: .color(ink))
                eye.fill(Path(ellipseIn: CGRect(x: -2.4, y: -3, width: 2.4, height: 2.4)), with: .color(glint.opacity(0.8)))
            case .oval, .wink, .big:
                let big = style == .big
                let w: CGFloat = big ? 12.5 : 10.4, h: CGFloat = big ? 17 : 16
                eye.scaleBy(x: 1, y: max(0.08, 1 - blink))
                eye.fill(Path(ellipseIn: CGRect(x: -w / 2, y: -h / 2, width: w, height: h)),
                         with: .linearGradient(Gradient(stops: [.init(color: ink.opacity(0.8), location: 0), .init(color: ink, location: 0.35),
                                                                .init(color: ink, location: 1)]),
                                               startPoint: CGPoint(x: -w / 2, y: -h / 2), endPoint: CGPoint(x: w * 0.3, y: h / 2)))
                if blink < 0.5 {
                    let r: CGFloat = big ? 2.6 : 1.4
                    eye.fill(Path(ellipseIn: CGRect(x: -1.6 - r, y: -3.8 - r * 1.5, width: 2 * r, height: 3 * r)),
                             with: .color(glint.opacity(big ? 0.75 : 0.15)))
                }
            case .happy:
                var arc = Path()
                arc.move(to: CGPoint(x: -5, y: 2))
                arc.addQuadCurve(to: CGPoint(x: 5, y: 2), control: CGPoint(x: 0, y: -7))
                eye.stroke(arc, with: .color(ink), style: StrokeStyle(lineWidth: 3.2, lineCap: .round))
            case .sleepy:
                var lid = Path()
                lid.move(to: CGPoint(x: -5, y: 0))
                lid.addQuadCurve(to: CGPoint(x: 5, y: 0), control: CGPoint(x: 0, y: 4.5))
                eye.stroke(lid, with: .color(ink), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            }
        }
    }

    private func drawBlush(_ ctx: inout GraphicsContext) {
        for x in [29.0, 71.0] {
            ctx.fill(Path(ellipseIn: CGRect(x: x - 5.5, y: 48, width: 11, height: 6)),
                     with: .radialGradient(Gradient(colors: [Color(.sRGB, red: 1, green: 0.42, blue: 0.62, opacity: 0.55), .clear]),
                                           center: CGPoint(x: x, y: 51), startRadius: 0, endRadius: 6))
        }
    }

    private func drawGlasses(_ ctx: inout GraphicsContext, ink: Color) {
        var frame = Path()
        frame.addEllipse(in: CGRect(x: 31.5, y: 31, width: 18, height: 18))
        frame.addEllipse(in: CGRect(x: 50.5, y: 31, width: 18, height: 18))
        frame.move(to: CGPoint(x: 47.5, y: 38))
        frame.addQuadCurve(to: CGPoint(x: 52.5, y: 38), control: CGPoint(x: 50, y: 35.5))
        ctx.fill(Path(ellipseIn: CGRect(x: 31.5, y: 31, width: 18, height: 18)), with: .color(.white.opacity(0.08)))
        ctx.fill(Path(ellipseIn: CGRect(x: 50.5, y: 31, width: 18, height: 18)), with: .color(.white.opacity(0.08)))
        ctx.stroke(frame, with: .color(ink.opacity(0.9)), lineWidth: 2)
    }

    private func drawBow(_ ctx: inout GraphicsContext) {
        let ribbon = Mochi.color(look.hex == "FF3E51" || look.hex == "FF5EB1" ? "FFFFFF" : "FF3E51")
        var bow = Path()
        bow.move(to: CGPoint(x: 66, y: 16))
        bow.addQuadCurve(to: CGPoint(x: 56, y: 9), control: CGPoint(x: 58, y: 18))
        bow.addQuadCurve(to: CGPoint(x: 66, y: 16), control: CGPoint(x: 57, y: 3))
        bow.move(to: CGPoint(x: 66, y: 16))
        bow.addQuadCurve(to: CGPoint(x: 77, y: 12), control: CGPoint(x: 76, y: 20))
        bow.addQuadCurve(to: CGPoint(x: 66, y: 16), control: CGPoint(x: 74, y: 5))
        ctx.fill(bow, with: .linearGradient(Gradient(colors: [ribbon, ribbon.opacity(0.8)]),
                                            startPoint: CGPoint(x: 56, y: 6), endPoint: CGPoint(x: 77, y: 20)))
        ctx.fill(Path(ellipseIn: CGRect(x: 63.5, y: 13.5, width: 5, height: 5)), with: .color(ribbon))
    }

    /// Kontrastfarbe für Zubehör, damit es sich von jeder Körperfarbe abhebt.
    private var accentHex: String {
        switch look.hex {
        case "FF3E51", "FF5EB1", "FF781C": return "2A92FE"
        case "FFAF38", "A27952": return "1CC3B0"
        default: return "FF5A4D"
        }
    }
    private var accent: Color { Mochi.color(accentHex) }
    /// Dunklere, deckende Stufe der Zubehörfarbe (für Schatten und Schirme).
    private var accentShade: Color { Mochi.color(accentHex, factor: 0.72) }

    /// Plastisch schattierte Fläche mit Licht von rechts oben, passend zum Körper.
    private func solid(_ ctx: GraphicsContext, _ shape: Path, hex: String) {
        ctx.boxFill(shape, cx: 0.62, cy: 0.2, r: 1.0, stops: [
            .init(color: Mochi.color(hex, factor: 1.14), location: 0), .init(color: Mochi.color(hex), location: 0.4),
            .init(color: Mochi.color(hex, factor: 0.66), location: 1)])
        ctx.boxFill(shape, cx: 0.66, cy: 0.16, r: 0.34, stops: [
            .init(color: .white.opacity(0.32), location: 0), .init(color: .white.opacity(0), location: 1)])
    }
    /// Weicher Schattenwurf eines Accessoires auf den Körper, unterhalb von `y`.
    private func castShadow(_ ctx: GraphicsContext, below y: CGFloat, depth: CGFloat = 7) {
        var clipped = ctx
        clipped.clip(to: Mochi.body)
        clipped.fill(Path(CGRect(x: 0, y: y, width: 100, height: depth)),
                     with: .linearGradient(Gradient(colors: [.black.opacity(0.26), .black.opacity(0)]),
                                           startPoint: CGPoint(x: 50, y: y), endPoint: CGPoint(x: 50, y: y + depth)))
    }
    private static let charcoalHex = "2C2F36"
    private static let creamHex = "F3F0EA"

    private func drawHeadwear(_ ctx: inout GraphicsContext) {
        switch look.top {
        case .sprout: drawSprout(&ctx)
        case .headphones:
            // Bügel folgt der Kopfkontur mit etwas Abstand; Muscheln sitzen auf Augenhöhe am Rand.
            let outline = Mochi.body.applying(CGAffineTransform(translationX: 50, y: 40).scaledBy(x: 1.075, y: 1.075).translatedBy(x: -50, y: -40))
            var band = ctx
            band.clip(to: Path(CGRect(x: -30, y: -30, width: 160, height: 64)))
            band.stroke(outline, with: .color(Mochi.color(Self.charcoalHex)), style: StrokeStyle(lineWidth: 4.4, lineCap: .round))
            band.stroke(outline.applying(CGAffineTransform(translationX: 0.6, y: -0.9)), with: .color(.white.opacity(0.22)), lineWidth: 1)
            for x in [12.5, 87.5] {
                let cup = Path(roundedRect: CGRect(x: x - 6.5, y: 29, width: 13, height: 22), cornerRadius: 6.5, style: .continuous)
                solid(ctx, cup, hex: Self.charcoalHex)
                solid(ctx, Path(roundedRect: CGRect(x: x - 2.6, y: 33.5, width: 5.2, height: 13), cornerRadius: 2.6), hex: accentHex)
            }
        case .cap:
            let cap = Mochi.headCover(cut: 17)
            let box = cap.boundingRect
            castShadow(ctx, below: 17)
            // Schirm zeigt nach rechts vorn und liegt unter der Kappe.
            var visor = Path()
            visor.move(to: CGPoint(x: 52, y: 14))
            visor.addCurve(to: CGPoint(x: box.maxX + 17, y: 19.5), control1: CGPoint(x: 68, y: 12.5), control2: CGPoint(x: box.maxX + 12, y: 14.5))
            visor.addCurve(to: CGPoint(x: 52, y: 20), control1: CGPoint(x: box.maxX + 8, y: 23), control2: CGPoint(x: 66, y: 21))
            visor.closeSubpath()
            solid(ctx, visor, hex: accentHex)
            ctx.fill(visor, with: .color(.black.opacity(0.22)))
            solid(ctx, cap, hex: accentHex)
            solid(ctx, Path(ellipseIn: CGRect(x: 47.6, y: box.minY - 1.4, width: 4.8, height: 3.4)), hex: accentHex)
            var seam = Path()
            seam.move(to: CGPoint(x: 50, y: box.minY + 2)); seam.addQuadCurve(to: CGPoint(x: 62, y: 16.5), control: CGPoint(x: 60, y: box.minY + 3))
            ctx.stroke(seam, with: .color(.black.opacity(0.14)), lineWidth: 0.7)
        case .beanie:
            let hat = Mochi.headCover(cut: 18, grow: 1.08)
            let box = hat.boundingRect
            castShadow(ctx, below: 21)
            solid(ctx, hat, hex: accentHex)
            // Strickrippen
            var ribs = ctx
            ribs.clip(to: hat)
            for x in stride(from: box.minX + 5, to: box.maxX, by: 6.5) {
                var rib = Path(); rib.move(to: CGPoint(x: x, y: 20)); rib.addQuadCurve(to: CGPoint(x: 50 + (x - 50) * 0.35, y: box.minY), control: CGPoint(x: x, y: 6))
                ribs.stroke(rib, with: .color(.black.opacity(0.12)), lineWidth: 0.8)
            }
            solid(ctx, Path(roundedRect: CGRect(x: box.minX - 1.8, y: 13.5, width: box.width + 3.6, height: 8.5), cornerRadius: 4.2, style: .continuous), hex: Self.creamHex)
            solid(ctx, Path(ellipseIn: CGRect(x: 43.2, y: box.minY - 10.5, width: 13.6, height: 13.6)), hex: Self.creamHex)
        case .crown:
            let base = Mochi.headCover(cut: 13, grow: 1.05).intersection(Path(CGRect(x: 0, y: 6.5, width: 100, height: 7)))
            let box = base.boundingRect
            castShadow(ctx, below: 13, depth: 5)
            var points = Path()
            let left = box.minX + 1.5, right = box.maxX - 1.5, y = box.minY + 1
            points.move(to: CGPoint(x: left, y: y + 2))
            for (fx, py) in [(0.0, -11.0), (0.25, -3.5), (0.5, -15.0), (0.75, -3.5), (1.0, -11.0)] {
                points.addLine(to: CGPoint(x: left + (right - left) * fx + (fx == 0 ? -2.5 : fx == 1 ? 2.5 : 0), y: y + py))
            }
            points.addLine(to: CGPoint(x: right, y: y + 2))
            points.closeSubpath()
            solid(ctx, points, hex: "FFC53D")
            solid(ctx, base, hex: "F0A91E")
            for (fx, hex) in [(0.2, "2A92FE"), (0.5, "FF3E51"), (0.8, "2A92FE")] {
                solid(ctx, Path(ellipseIn: CGRect(x: left + (right - left) * fx - 1.9, y: box.midY - 1.9, width: 3.8, height: 3.8)), hex: hex)
            }
            for (fx, py) in [(0.0, -11.0), (0.5, -15.0), (1.0, -11.0)] {
                let cx = left + (right - left) * fx + (fx == 0 ? -2.5 : fx == 1 ? 2.5 : 0)
                solid(ctx, Path(ellipseIn: CGRect(x: cx - 1.8, y: y + py - 2.6, width: 3.6, height: 3.6)), hex: "FFD86B")
            }
        case .propeller:
            let cap = Mochi.headCover(cut: 16, grow: 1.07)
            let box = cap.boundingRect
            castShadow(ctx, below: 17, depth: 5)
            solid(ctx, cap, hex: accentHex)
            solid(ctx, Path(roundedRect: CGRect(x: box.minX - 1.2, y: 13, width: box.width + 2.4, height: 4.6), cornerRadius: 2.3), hex: Self.creamHex)
            solid(ctx, Path(roundedRect: CGRect(x: 48.8, y: box.minY - 8, width: 2.4, height: 9), cornerRadius: 1.2), hex: Self.charcoalHex)
            let hub = CGPoint(x: 50, y: box.minY - 8.5)
            for (dx, hex) in [(-10.0, "FFAF38"), (10.0, "2A92FE")] {
                solid(ctx, Path(ellipseIn: CGRect(x: hub.x + dx - 9.5, y: hub.y - 3.2, width: 19, height: 6.4)), hex: hex)
            }
            solid(ctx, Path(ellipseIn: CGRect(x: hub.x - 2.8, y: hub.y - 2.8, width: 5.6, height: 5.6)), hex: Self.creamHex)
        case .flower:
            let center = CGPoint(x: 66, y: 14)
            ctx.drawLayer { layer in
                layer.addFilter(.shadow(color: .black.opacity(0.3), radius: 1.6, x: 0, y: 1.2))
                for i in 0..<5 {
                    let angle = CGFloat(i) * 2 * .pi / 5 - .pi / 2
                    layer.fill(Path(ellipseIn: CGRect(x: center.x + cos(angle) * 5.2 - 4.3, y: center.y + sin(angle) * 5.2 - 4.3, width: 8.6, height: 8.6)),
                               with: .color(Mochi.color(Self.creamHex)))
                }
            }
            solid(ctx, Path(ellipseIn: CGRect(x: center.x - 3.4, y: center.y - 3.4, width: 6.8, height: 6.8)), hex: "FFAF38")
        default: break
        }
    }

    private func drawScarf(_ ctx: inout GraphicsContext) {
        castShadow(ctx, below: 70, depth: 6)
        var clipped = ctx
        clipped.clip(to: Mochi.body)
        var band = Path()
        band.move(to: CGPoint(x: -4, y: 60))
        band.addQuadCurve(to: CGPoint(x: 104, y: 60), control: CGPoint(x: 50, y: 74))
        clipped.stroke(band, with: .linearGradient(Gradient(colors: [Mochi.color(accentHex, factor: 0.7), accent, Mochi.color(accentHex, factor: 1.12)]),
                                                   startPoint: CGPoint(x: 0, y: 64), endPoint: CGPoint(x: 100, y: 64)),
                       style: StrokeStyle(lineWidth: 10, lineCap: .round))
        var fold = Path()
        fold.move(to: CGPoint(x: 6, y: 59)); fold.addQuadCurve(to: CGPoint(x: 94, y: 59), control: CGPoint(x: 50, y: 71))
        clipped.stroke(fold, with: .color(.white.opacity(0.16)), lineWidth: 1)
        // Loses Ende mit Knoten
        let tail = Path(roundedRect: CGRect(x: 60, y: 66, width: 9.5, height: 19), cornerRadius: 3.5, style: .continuous)
        solid(clipped, tail, hex: accentHex)
        solid(clipped, Path(ellipseIn: CGRect(x: 58.5, y: 62.5, width: 12, height: 8.5)), hex: accentHex)
    }

    private func drawFreckles(_ ctx: inout GraphicsContext, ink: Color) {
        for side in [-1.0, 1.0] {
            for (dx, dy) in [(19.0, 49.0), (23.0, 52.5), (26.5, 48.5)] {
                ctx.fill(Path(ellipseIn: CGRect(x: 50 + side * dx - 1.1, y: dy, width: 2.2, height: 2.2)), with: .color(ink.opacity(0.4)))
            }
        }
    }

    private func drawMoustache(_ ctx: inout GraphicsContext, ink: Color) {
        var path = Path()
        for side in [-1.0, 1.0] {
            path.move(to: CGPoint(x: 50, y: 53.5))
            path.addCurve(to: CGPoint(x: 50 + side * 14, y: 52), control1: CGPoint(x: 50 + side * 5, y: 49), control2: CGPoint(x: 50 + side * 11, y: 56))
            path.addCurve(to: CGPoint(x: 50, y: 53.5), control1: CGPoint(x: 50 + side * 10, y: 60), control2: CGPoint(x: 50 + side * 4, y: 57))
        }
        ctx.fill(path, with: .color(ink))
    }

    private func drawBadge(_ ctx: inout GraphicsContext) {
        var star = Path()
        for i in 0..<10 {
            let radius: CGFloat = i % 2 == 0 ? 6.4 : 2.7
            let angle = CGFloat(i) * .pi / 5 - .pi / 2
            let point = CGPoint(x: 73 + cos(angle) * radius, y: 71 + sin(angle) * radius)
            if i == 0 { star.move(to: point) } else { star.addLine(to: point) }
        }
        star.closeSubpath()
        ctx.fill(star, with: .color(Color(.sRGB, red: 1, green: 0.8, blue: 0.25)))
        ctx.stroke(star, with: .color(.black.opacity(0.25)), lineWidth: 0.6)
    }

    private func drawSprout(_ ctx: inout GraphicsContext) {
        let leaf = Color(.sRGB, red: 0.2, green: 0.78, blue: 0.45)
        var stem = Path()
        stem.move(to: CGPoint(x: 50, y: 7))
        stem.addQuadCurve(to: CGPoint(x: 51, y: -6), control: CGPoint(x: 48, y: 0))
        ctx.stroke(stem, with: .color(leaf.opacity(0.9)), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
        for (tip, control) in [(CGPoint(x: 38, y: -12), CGPoint(x: 40, y: -2)), (CGPoint(x: 63, y: -13), CGPoint(x: 62, y: -2))] {
            var blade = Path()
            blade.move(to: CGPoint(x: 51, y: -5))
            blade.addQuadCurve(to: tip, control: control)
            blade.addQuadCurve(to: CGPoint(x: 51, y: -5), control: CGPoint(x: (tip.x + 51) / 2, y: tip.y - 4))
            ctx.fill(blade, with: .linearGradient(Gradient(colors: [leaf, Color(.sRGB, red: 0.1, green: 0.55, blue: 0.3)]),
                                                  startPoint: tip, endPoint: CGPoint(x: 51, y: -5)))
        }
    }
}

/// Gruppenbild aus bis zu drei Mochis: versetzte Kacheln mit dunklem Ring.
struct GroupAvatar: View {
    let keys: [String]
    let size: CGFloat
    var body: some View {
        let tile = size * (keys.count > 2 ? 0.56 : keys.count == 2 ? 0.66 : 1)
        let spots: [CGPoint] = keys.count == 1 ? [.zero] : keys.count > 2
            ? [CGPoint(x: 0, y: -size * 0.2), CGPoint(x: -size * 0.21, y: size * 0.19), CGPoint(x: size * 0.21, y: size * 0.19)]
            : [CGPoint(x: -size * 0.16, y: -size * 0.16), CGPoint(x: size * 0.16, y: size * 0.16)]
        ZStack {
            ForEach(Array(keys.prefix(3).enumerated()), id: \.offset) { index, key in
                MochiAvatar(key: key, size: tile)
                    .background(RoundedRectangle(cornerRadius: tile * 0.25, style: .continuous)
                        .fill(Color(.sRGB, red: 10 / 255, green: 10 / 255, blue: 10 / 255)).padding(-1.5))
                    .offset(x: spots[index].x, y: spots[index].y)
            }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}
