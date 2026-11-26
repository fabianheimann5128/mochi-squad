import AppKit
import SwiftUI

// Creates the app icon from the coordinator's Mochi:  tools/make-icon.sh
@main struct MakeIcon {
    @MainActor static func main() {
        let out = URL(fileURLWithPath: CommandLine.arguments[1])
        let icon = ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: [Color(.sRGB, red: 0.16, green: 0.17, blue: 0.24), Color(.sRGB, red: 0.05, green: 0.05, blue: 0.07)],
                                     startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(RadialGradient(colors: [Color(.sRGB, red: 0.35, green: 0.45, blue: 1, opacity: 0.35), .clear],
                                     center: UnitPoint(x: 0.5, y: 0.35), startRadius: 0, endRadius: 520))
            MochiCanvas(look: .coordinator, showsPlate: false)
                .frame(width: 824, height: 824).clipShape(RoundedRectangle(cornerRadius: 185, style: .continuous))
            RoundedRectangle(cornerRadius: 185, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 3)
        }.frame(width: 824, height: 824).shadow(color: .black.opacity(0.35), radius: 22, y: 12).frame(width: 1024, height: 1024)
        let renderer = ImageRenderer(content: icon)
        renderer.scale = 1
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) else { fatalError("Icon konnte nicht gerendert werden.") }
        try! png.write(to: out)
    }
}
