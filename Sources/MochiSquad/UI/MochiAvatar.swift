import SwiftUI

// Mochi-Avatare: eine eigene Figur von Mochi Squad. Ein weich zerfließender Mochi auf dunkler Kachel,
// dazu Bauformen, Kopfteile, Augen und Extras aus einem Baukasten.

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
    var hex = "F7F2EA"

    static let palette: [(name: String, hex: String)] = [
        ("Creme", "F7F2EA"), ("Blau", "4C8DFF"), ("Grün", "3CCB7F"), ("Koralle", "FF6B5E"), ("Sonne", "FFC43D"),
        ("Violett", "9B7BFF"), ("Türkis", "2CC5B6"), ("Rosa", "FF7EB6"), ("Schiefer", "94A3B8")
    ]
    /// Der Mochi des Koordinators und der App: cremefarben mit Katzenohren.
    static let coordinator = MochiLook(top: .cat)

    var key: String { "mochi:\(build.rawValue).\(top.rawValue).\(eyes.rawValue).\(extra.rawValue):\(hex)" }

    init(build: Build = .classic, top: Top = .none, eyes: Eyes = .oval, extra: Extra = .none, hex: String = "F7F2EA") {
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

/// Zeichenformen und Farben der Mochis (Koordinaten 0 … 100: Scheitel bei y = 4, Augen bei 40, Fuß bei `foot`).
enum Mochi {
    static let foot: CGFloat = 69
    /// Runder Kopf, der unten weich in einen breiten Fuß zerfließt.
    static let body: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 50, y: 4))
        p.addCurve(to: CGPoint(x: 83.1, y: 37.1), control1: CGPoint(x: 69.4, y: 4), control2: CGPoint(x: 83.1, y: 17.7))
        p.addCurve(to: CGPoint(x: 99, y: 62.1), control1: CGPoint(x: 83.1, y: 50.7), control2: CGPoint(x: 96.7, y: 53))
        p.addCurve(to: CGPoint(x: 91, y: foot), control1: CGPoint(x: 100.2, y: 66.7), control2: CGPoint(x: 96.7, y: foot))
        p.addLine(to: CGPoint(x: 9, y: foot))
        p.addCurve(to: CGPoint(x: 1, y: 62.1), control1: CGPoint(x: 3.3, y: foot), control2: CGPoint(x: -0.2, y: 66.7))
        p.addCurve(to: CGPoint(x: 16.9, y: 37.1), control1: CGPoint(x: 3.3, y: 53), control2: CGPoint(x: 16.9, y: 50.7))
        p.addCurve(to: CGPoint(x: 50, y: 4), control1: CGPoint(x: 16.9, y: 17.7), control2: CGPoint(x: 30.6, y: 4))
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

    static func buildScale(_ build: MochiLook.Build) -> (x: Double, y: Double) {
        switch build {
        case .classic: return (1, 1)
        case .tall: return (0.86, 1.06)
        case .chubby: return (1.06, 0.9)
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
    /// Rund statt als Kachel, für Pillen und Chips.
    var round = false
    @Environment(\.accessibilityReduceMotion) private var still

    var body: some View {
        let look = MochiLook(key: key)
        Group {
            if working && !still {
                TimelineView(.animation(minimumInterval: 1 / 20)) { moment in
                    let t = moment.date.timeIntervalSinceReferenceDate
                    let phase = t.truncatingRemainder(dividingBy: 3.6)
                    MochiCanvas(look: look, breathe: (1 - cos(t * 2 * .pi / 2.2)) / 2, blink: phase < 0.16 ? sin(phase / 0.16 * .pi) : 0, round: round)
                }
            } else {
                MochiCanvas(look: look, round: round)
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
    var round = false

    var body: some View {
        Canvas { ctx, canvas in
            let s = min(canvas.width, canvas.height) / 100
            ctx.scaleBy(x: s, y: s)
            let plate = round ? Path(ellipseIn: CGRect(x: 0, y: 0, width: 100, height: 100))
                : Path(roundedRect: CGRect(x: 0, y: 0, width: 100, height: 100), cornerRadius: 23, style: .continuous)
            ctx.clip(to: plate)
            if showsPlate {
                ctx.fill(plate, with: .color(Color(.sRGB, red: 20 / 255, green: 20 / 255, blue: 20 / 255)))
                ctx.fill(plate, with: .radialGradient(Gradient(colors: [look.color.opacity(0.16), .clear]), center: CGPoint(x: 50, y: 40), startRadius: 0, endRadius: 70))
            }
            draw(&ctx)
            if showsPlate {
                let border = round ? Path(ellipseIn: CGRect(x: 0.5, y: 0.5, width: 99, height: 99))
                    : Path(roundedRect: CGRect(x: 0.5, y: 0.5, width: 99, height: 99), cornerRadius: 22.5, style: .continuous)
                ctx.stroke(border, with: .color(Color.white.opacity(0.1)), lineWidth: 1)
            }
        }
    }

    private func draw(_ ctx: inout GraphicsContext) {
        let hex = look.hex
        let base = Mochi.color(hex)
        var body = ctx
        // Der Fuß schließt mit dem unteren Kachelrand ab und läuft seitlich leicht darüber hinaus; Bauform und Atmen skalieren um den Fuß.
        let build = Mochi.buildScale(look.build), size = 1.15
        body.translateBy(x: 50, y: 103)
        body.scaleBy(x: size * build.x * (1 - 0.015 * breathe), y: size * build.y * (1 + 0.035 * breathe))
        body.translateBy(x: -50, y: -Mochi.foot)
        let shape = Mochi.silhouette(look.top)

        // Grundton mit Licht von links oben, dunkle Flanke rechts unten, Glanzfleck und helle Kante.
        body.boxFill(shape, cx: 0.4, cy: 0.3, r: 0.8, stops: [.init(color: Mochi.color(hex, factor: 1.08), location: 0), .init(color: base, location: 0.45),
                                                              .init(color: Mochi.color(hex, factor: 0.78), location: 1)])
        body.drawLayer { layer in
            layer.clip(to: shape)
            layer.drawLayer { shade in
                shade.addFilter(.blur(radius: 8))
                shade.fill(Path(ellipseIn: CGRect(x: 59, y: 35, width: 60, height: 50)), with: .color(Mochi.color(hex, factor: 0.45).opacity(0.75)))
                shade.fill(Path(ellipseIn: CGRect(x: -2, y: 66, width: 104, height: 20)), with: .color(Mochi.color(hex, factor: 0.4).opacity(0.8)))
            }
            layer.drawLayer { gloss in
                gloss.addFilter(.blur(radius: 5.5))
                gloss.fill(Path(ellipseIn: CGRect(x: 17, y: 10, width: 32, height: 18)), with: .color(.white.opacity(0.5)))
            }
            layer.drawLayer { edge in
                edge.addFilter(.blur(radius: 0.9))
                edge.stroke(shape.applying(CGAffineTransform(translationX: 0.9, y: 1.6)), with: .color(.white.opacity(0.35)), lineWidth: 1.8)
            }
        }
        drawHeadwear(&body)
        let dark = Mochi.darkEyes(hex)
        let ink = dark ? Mochi.eyeInk : Color(white: 0.96)
        drawBlush(&body, strength: look.extra == .blush ? 0.9 : 0.5)
        if look.extra != .moustache {
            var mouth = Path()
            mouth.move(to: CGPoint(x: 46, y: 50.5))
            mouth.addQuadCurve(to: CGPoint(x: 54, y: 50.5), control: CGPoint(x: 50, y: 55.5))
            body.stroke(mouth, with: .color(ink), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
        }
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

    private func drawBlush(_ ctx: inout GraphicsContext, strength: Double) {
        for x in [28.0, 72.0] {
            ctx.fill(Path(ellipseIn: CGRect(x: x - 7, y: 46, width: 14, height: 9)),
                     with: .radialGradient(Gradient(colors: [Color(.sRGB, red: 1, green: 0.45, blue: 0.55, opacity: strength), .clear]),
                                           center: CGPoint(x: x, y: 50.5), startRadius: 0, endRadius: 7))
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
        let ribbon = Mochi.color(look.hex == "FF6B5E" || look.hex == "FF7EB6" ? "F7F2EA" : "FF6B5E")
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
        case "FF6B5E", "FF7EB6": return "4C8DFF"
        case "FFC43D": return "2CC5B6"
        default: return "FF6B5E"
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

    /// Schal um die Stelle, an der der Kopf in den Fuß übergeht, mit Knoten und losem Ende.
    private func drawScarf(_ ctx: inout GraphicsContext) {
        var clipped = ctx
        clipped.clip(to: Mochi.body)
        var band = Path()
        band.move(to: CGPoint(x: 8, y: 53))
        band.addQuadCurve(to: CGPoint(x: 92, y: 53), control: CGPoint(x: 50, y: 65))
        clipped.stroke(band, with: .linearGradient(Gradient(colors: [Mochi.color(accentHex, factor: 0.7), accent, Mochi.color(accentHex, factor: 1.12)]),
                                                   startPoint: CGPoint(x: 0, y: 58), endPoint: CGPoint(x: 100, y: 58)),
                       style: StrokeStyle(lineWidth: 7.5, lineCap: .round))
        var fold = Path()
        fold.move(to: CGPoint(x: 14, y: 52)); fold.addQuadCurve(to: CGPoint(x: 86, y: 52), control: CGPoint(x: 50, y: 62.5))
        clipped.stroke(fold, with: .color(.white.opacity(0.16)), lineWidth: 1)
        solid(clipped, Path(roundedRect: CGRect(x: 63, y: 59, width: 8, height: 13), cornerRadius: 3, style: .continuous), hex: accentHex)
        solid(clipped, Path(ellipseIn: CGRect(x: 61, y: 55.5, width: 11, height: 7.5)), hex: accentHex)
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
            let point = CGPoint(x: 73 + cos(angle) * radius, y: 59 + sin(angle) * radius)
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

/// Gruppenbild aus bis zu drei Mochis, nebeneinander ohne Überlappung.
struct GroupAvatar: View {
    let keys: [String]
    let size: CGFloat
    var round = false
    var body: some View {
        let tile = size * (keys.count > 1 ? 0.48 : 1), shift = size * 0.26
        let spots: [CGPoint] = keys.count == 1 ? [.zero] : keys.count > 2
            ? [CGPoint(x: 0, y: -shift), CGPoint(x: -shift, y: shift), CGPoint(x: shift, y: shift)]
            : [CGPoint(x: -shift, y: 0), CGPoint(x: shift, y: 0)]
        ZStack {
            ForEach(Array(keys.prefix(3).enumerated()), id: \.offset) { index, key in
                MochiAvatar(key: key, size: tile, round: round)
                    .offset(x: spots[index].x, y: spots[index].y)
            }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}
