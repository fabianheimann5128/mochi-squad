import AppKit
import CoreImage
import SwiftUI

/// Settings section: reach the team chat from the phone through Telegram or WhatsApp.
struct MessengerSection: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var hub: MessengerHub
    @State private var setup: Channel?

    enum Channel: String, Identifiable { case telegram, whatsapp; var id: String { rawValue } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(t("Messengers", "Messenger")).font(.system(size: 13, weight: .semibold)).foregroundStyle(Desk.dim)
            Row(title: "Telegram", symbol: "paperplane.fill", link: hub.telegram) { setup = .telegram }
            WhatsAppRow(link: hub.whatsapp) { setup = .whatsapp }
            if settings.messengers.telegram != nil || settings.messengers.whatsapp != nil {
                if settings.projects.count > 1 {
                    HStack {
                        Text(t("Team chat of", "Team-Chat von")).foregroundStyle(Desk.dim)
                        Picker("", selection: Binding(get: { settings.messengerProject?.path ?? "" }, set: { settings.messengers.project = $0 })) {
                            ForEach(settings.projects, id: \.path) { Text($0.lastPathComponent).tag($0.path) }
                        }.labelsHidden().fixedSize()
                    }
                }
                Toggle(isOn: Binding(get: { settings.messengers.reachPrivileged }, set: { settings.messengers.reachPrivileged = $0 })) {
                    Text(t("Agents with full access or computer use may also be reached this way", "Auch Agenten mit Vollzugriff oder Computer-Nutzung sind so erreichbar"))
                        .font(.system(size: 12.5))
                }.toggleStyle(.checkbox)
            }
            Text(t("Write to your team from your phone: without a mention your coordinator answers, with @name a specific agent. Answers come back to the messenger.",
                   "Schreib deinem Team vom Handy aus: Ohne Anrede antwortet dein Koordinator, mit @Name ein bestimmter Agent. Die Antworten kommen im Messenger an."))
                .font(.system(size: 12)).foregroundStyle(Desk.dim).fixedSize(horizontal: false, vertical: true)
        }
        .sheet(item: $setup) { channel in
            Group { if channel == .telegram { TelegramSetup(link: hub.telegram) } else { WhatsAppSetup(link: hub.whatsapp) } }.dialogStyle()
                // The setup opens on top of the settings, which have the same colour: a fine line sets it apart.
                .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Desk.edge).allowsHitTesting(false) }
        }
    }

    private struct Row: View {
        let title: String
        let symbol: String
        @ObservedObject var link: TelegramLink
        let open: () -> Void
        var body: some View {
            channelRow(title: title, symbol: symbol, ready: link.paired && link.state == .ready,
                       detail: link.paired ? (link.state == .ready ? t("connected with \(link.config?.userName ?? "your account")", "verbunden mit \(link.config?.userName ?? "deinem Konto")")
                                                                   : t("not connected right now", "gerade nicht verbunden"))
                                           : (link.config == nil ? t("not set up", "nicht eingerichtet") : t("bot saved, account not linked yet", "Bot gespeichert, Konto noch nicht verknüpft")),
                       action: link.config == nil ? t("Set up", "Einrichten") : t("Manage", "Verwalten"), open: open)
        }
    }

    private struct WhatsAppRow: View {
        @ObservedObject var link: WhatsAppLink
        let open: () -> Void
        var body: some View {
            let detail: String = {
                switch link.state {
                case .open(let number): return t("connected with +\(number)", "verbunden mit +\(number)")
                case .installing: return t("is being installed …", "wird installiert …")
                case .connecting, .code: return t("connecting …", "verbindet …")
                default: return link.linked ? t("not connected right now", "gerade nicht verbunden") : t("not set up", "nicht eingerichtet")
                }
            }()
            var ready = false
            if case .open = link.state { ready = true }
            return channelRow(title: "WhatsApp", symbol: "phone.bubble.fill", ready: ready, detail: detail,
                              action: link.linked ? t("Manage", "Verwalten") : t("Set up", "Einrichten"), open: open)
        }
    }
}

@MainActor private func channelRow(title: String, symbol: String, ready: Bool, detail: String, action: String, open: @escaping () -> Void) -> some View {
    HStack(spacing: 12) {
        Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(ready ? Desk.success : Desk.faint).frame(width: 22)
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 13.5, weight: .medium))
            Text(detail).font(.system(size: 12)).foregroundStyle(Desk.dim).lineLimit(1)
        }
        Spacer()
        Button(action, action: open).buttonStyle(.pill)
    }.padding(.horizontal, 12).frame(height: 48).field(12)
}

/// A QR code drawn from text, white on the dark dialog with a light quiet zone so phones read it reliably.
struct QRCode: View {
    let text: String
    var body: some View {
        if let image = Self.image(text) {
            Image(nsImage: image).interpolation(.none).resizable().frame(width: 196, height: 196)
                .padding(10).background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityLabel(t("QR code", "QR-Code"))
        }
    }

    static func image(_ text: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

/// Numbered step of a setup dialog.
@MainActor private func step(_ number: Int, _ text: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
        Text("\(number)").font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(Desk.onPrimary)
            .frame(width: 20, height: 20).background(Desk.primary, in: Circle())
        Text(text).font(.system(size: 13.5)).fixedSize(horizontal: false, vertical: true)
    }
}

/// Telegram: create a bot, paste its token, press Start on the phone, confirm the account.
struct TelegramSetup: View {
    @ObservedObject var link: TelegramLink
    @Environment(\.dismiss) private var dismiss
    @State private var pasted = ""
    @State private var confirmRemove = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Telegram").font(.system(size: 20, weight: .semibold))
                Spacer()
                Button(t("Done", "Fertig")) { dismiss() }.buttonStyle(.primaryPill).keyboardShortcut(.defaultAction)
            }
            if link.config == nil { token } else if !link.paired { pair } else { connected }
            if case .failed(let reason) = link.state {
                Label(reason, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12.5)).foregroundStyle(Desk.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(22).frame(width: 460)
        .onAppear { if link.config != nil, !link.paired, link.pairing == nil { link.beginPairing() } }
        .onChange(of: link.config) { _, config in if config != nil, config?.userID == nil, link.pairing == nil { link.beginPairing() } }
    }

    private var token: some View {
        VStack(alignment: .leading, spacing: 12) {
            step(1, t("Open @BotFather in Telegram and send /newbot. Pick any name for your bot.", "Öffne @BotFather in Telegram und sende /newbot. Gib deinem Bot einen beliebigen Namen."))
            Button { NSWorkspace.shared.open(URL(string: "https://t.me/BotFather")!) } label: { Label(t("Open BotFather", "BotFather öffnen"), systemImage: "arrow.up.right") }
                .buttonStyle(.pill).padding(.leading, 30)
            step(2, t("BotFather answers with a token. Paste it here; the whole reply works too.", "BotFather antwortet mit einem Token. Füge es hier ein; die ganze Antwort geht auch."))
            HStack(spacing: 8) {
                SecureField(t("Bot token", "Bot-Token"), text: $pasted).textFieldStyle(.plain).padding(.horizontal, 12).frame(height: 34).field(8).onSubmit(connect)
                Button(link.state == .connecting ? t("Checking …", "Prüfe …") : t("Connect", "Verbinden"), action: connect).buttonStyle(.primaryPill)
                    .disabled(TelegramLink.token(in: pasted) == nil || link.state == .connecting)
            }.padding(.leading, 30)
            Text(t("The token stays in your Mac's keychain. Mochi Squad asks Telegram for new messages itself; no server is involved.",
                   "Das Token bleibt im Schlüsselbund deines Macs. Mochi Squad fragt Telegram selbst nach neuen Nachrichten; ein Server ist nicht beteiligt."))
                .font(.system(size: 12)).foregroundStyle(Desk.dim).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var pair: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let candidate = link.candidate {
                Text(t("Is this your Telegram account?", "Ist das dein Telegram-Konto?")).font(.system(size: 15, weight: .semibold))
                HStack(spacing: 10) {
                    Image(systemName: "person.crop.circle.fill").font(.system(size: 26)).foregroundStyle(Desk.dim)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(candidate.name.isEmpty ? t("No name", "Ohne Namen") : candidate.name).font(.system(size: 14, weight: .medium))
                        if !candidate.username.isEmpty { Text("@" + candidate.username).font(.system(size: 12.5)).foregroundStyle(Desk.dim) }
                    }
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).field(12)
                Text(t("Only this account will be able to write to your team.", "Nur dieses Konto kann deinem Team danach schreiben."))
                    .font(.system(size: 12.5)).foregroundStyle(Desk.dim)
                HStack {
                    Button(t("Yes, link it", "Ja, verknüpfen")) { link.confirmCandidate() }.buttonStyle(.primaryPill)
                    Button(t("No", "Nein")) { link.rejectCandidate(); link.beginPairing() }.buttonStyle(.pill)
                }
            } else if let pairing = link.pairing {
                step(1, t("Scan the code with your phone, or open the link on this Mac.", "Scanne den Code mit dem Handy oder öffne den Link auf diesem Mac."))
                HStack(alignment: .center, spacing: 16) {
                    QRCode(text: pairing.link.absoluteString)
                    VStack(alignment: .leading, spacing: 10) {
                        Button { NSWorkspace.shared.open(pairing.link) } label: { Label("@" + (link.config?.bot ?? ""), systemImage: "arrow.up.right") }.buttonStyle(.pill)
                        TimelineView(.periodic(from: .now, by: 20)) { moment in
                            if pairing.expires > moment.date {
                                Text(t("The link is valid for 15 minutes.", "Der Link gilt 15 Minuten.")).font(.system(size: 12)).foregroundStyle(Desk.dim)
                            } else {
                                Button(t("Expired: new link", "Abgelaufen: neuer Link")) { link.beginPairing() }.buttonStyle(.pill)
                            }
                        }
                    }
                }.padding(.leading, 30)
                step(2, t("Press “Start” in the chat with your bot. This window then shows your account.", "Drücke im Chat mit deinem Bot auf „Start“. Dieses Fenster zeigt dann dein Konto."))
            }
            remove
        }
    }

    private var connected: some View {
        VStack(alignment: .leading, spacing: 12) {
            if link.state == .ready {
                Label(t("Connected with \(link.config?.userName ?? "your account") through @\(link.config?.bot ?? "")",
                        "Verbunden mit \(link.config?.userName ?? "deinem Konto") über @\(link.config?.bot ?? "")"), systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13.5)).foregroundStyle(Desk.success)
            } else {
                Label(t("Linked with \(link.config?.userName ?? "your account"), but not connected right now.",
                        "Verknüpft mit \(link.config?.userName ?? "deinem Konto"), aber gerade nicht verbunden."), systemImage: "wifi.exclamationmark")
                    .font(.system(size: 13.5)).foregroundStyle(Desk.warning)
                Button(t("Connect again", "Neu verbinden")) { link.reconnect() }.buttonStyle(.primaryPill)
            }
            Text(t("Write to your bot in Telegram. Only your account is answered; messages from anyone else are ignored.",
                   "Schreib deinem Bot in Telegram. Nur dein Konto bekommt Antworten; Nachrichten von anderen werden ignoriert."))
                .font(.system(size: 12.5)).foregroundStyle(Desk.dim).fixedSize(horizontal: false, vertical: true)
            remove
        }
    }

    private var remove: some View {
        Button(t("Remove Telegram", "Telegram entfernen")) { confirmRemove = true }.buttonStyle(.pill)
            .confirmationDialog(t("Remove Telegram?", "Telegram entfernen?"), isPresented: $confirmRemove) {
                Button(t("Remove", "Entfernen"), role: .destructive) { link.disconnect() }
                Button(t("Cancel", "Abbrechen"), role: .cancel) {}
            } message: { Text(t("The token is deleted from the keychain. Your bot itself stays at Telegram; you can delete it in BotFather.",
                                "Das Token wird aus dem Schlüsselbund gelöscht. Dein Bot selbst bleibt bei Telegram; du kannst ihn in BotFather löschen.")) }
    }

    private func connect() {
        guard let token = TelegramLink.token(in: pasted) else { return }
        pasted = ""
        link.connect(token: token)
    }
}

/// WhatsApp: link this Mac as a device by scanning a code, then use the "Message yourself" chat.
struct WhatsAppSetup: View {
    @ObservedObject var link: WhatsAppLink
    @Environment(\.dismiss) private var dismiss
    @State private var confirmRemove = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("WhatsApp").font(.system(size: 20, weight: .semibold))
                Spacer()
                Button(t("Done", "Fertig")) { if !link.linked { link.cancel() }; dismiss() }.buttonStyle(.primaryPill).keyboardShortcut(.defaultAction)
            }
            content
            Label(t("WhatsApp offers no official way to do this for private accounts. Mochi Squad connects like WhatsApp Web through an unofficial library; WhatsApp does not allow that in its terms, and there is a small risk that it blocks a number for it.",
                    "WhatsApp bietet dafür keinen offiziellen Weg für private Konten. Mochi Squad verbindet sich wie WhatsApp Web über eine inoffizielle Bibliothek; WhatsApp erlaubt das in seinen Bedingungen nicht, und es besteht ein kleines Risiko, dass eine Nummer dafür gesperrt wird."),
                  systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(Desk.dim).fixedSize(horizontal: false, vertical: true)
        }
        .padding(22).frame(width: 460)
    }

    @ViewBuilder private var content: some View {
        switch link.state {
        case .off:
            VStack(alignment: .leading, spacing: 12) {
                Text(t("You chat with your team in WhatsApp's “Message yourself” chat. All your other chats stay outside Mochi Squad: they are neither read nor stored.",
                       "Du schreibst mit deinem Team im WhatsApp-Chat „Nachricht an mich selbst“. Alle anderen Chats bleiben außerhalb von Mochi Squad: Sie werden weder gelesen noch gespeichert."))
                    .font(.system(size: 13.5)).fixedSize(horizontal: false, vertical: true)
                Button(link.linked ? t("Reconnect", "Neu verbinden") : t("Connect WhatsApp", "WhatsApp verbinden")) { link.connect() }.buttonStyle(.primaryPill)
                if link.linked { remove }
            }
        case .needsNode:
            VStack(alignment: .leading, spacing: 12) {
                Text(t("WhatsApp needs Node.js, which is not installed on this Mac. Install it, then come back here.",
                       "WhatsApp braucht Node.js, das auf diesem Mac nicht installiert ist. Installiere es und komm dann hierher zurück."))
                    .font(.system(size: 13.5)).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button { NSWorkspace.shared.open(URL(string: "https://nodejs.org/en/download")!) } label: { Label("nodejs.org", systemImage: "arrow.up.right") }.buttonStyle(.pill)
                    Button(t("Check again", "Erneut prüfen")) { link.connect() }.buttonStyle(.primaryPill)
                }
            }
        case .installing:
            progress(t("Downloading the WhatsApp library once …", "Lade die WhatsApp-Bibliothek einmalig …"))
        case .connecting:
            progress(t("Connecting to WhatsApp …", "Verbinde mit WhatsApp …"))
        case .code(let code):
            VStack(alignment: .leading, spacing: 12) {
                step(1, t("On your phone, open WhatsApp › Settings › Linked devices › Link a device.", "Öffne auf dem Handy WhatsApp › Einstellungen › Verknüpfte Geräte › Gerät hinzufügen."))
                step(2, t("Scan this code. It renews itself about every minute.", "Scanne diesen Code. Er erneuert sich etwa jede Minute."))
                QRCode(text: code).padding(.leading, 30)
            }
        case .open(let number):
            VStack(alignment: .leading, spacing: 12) {
                Label(t("Connected with +\(number)", "Verbunden mit +\(number)"), systemImage: "checkmark.circle.fill").font(.system(size: 13.5)).foregroundStyle(Desk.success)
                Text(t("Open the “Message yourself” chat in WhatsApp (your own number at the top of the chat list) and write there.",
                       "Öffne in WhatsApp den Chat „Nachricht an mich selbst“ (deine eigene Nummer oben in der Chatliste) und schreib dort."))
                    .font(.system(size: 12.5)).foregroundStyle(Desk.dim).fixedSize(horizontal: false, vertical: true)
                remove
            }
        case .failed(let reason):
            VStack(alignment: .leading, spacing: 12) {
                Label(reason, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12.5)).foregroundStyle(Desk.warning).fixedSize(horizontal: false, vertical: true)
                Button(t("Try again", "Erneut versuchen")) { link.connect() }.buttonStyle(.primaryPill)
                if link.linked { remove }
            }
        }
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: 10) { ProgressView().controlSize(.small); Text(text).font(.system(size: 13.5)) }.padding(.vertical, 20)
    }

    private var remove: some View {
        Button(t("Unlink WhatsApp", "WhatsApp trennen")) { confirmRemove = true }.buttonStyle(.pill)
            .confirmationDialog(t("Unlink WhatsApp?", "WhatsApp trennen?"), isPresented: $confirmRemove) {
                Button(t("Unlink", "Trennen"), role: .destructive) { link.disconnect() }
                Button(t("Cancel", "Abbrechen"), role: .cancel) {}
            } message: { Text(t("This Mac is removed from your linked devices and the stored session is deleted.",
                                "Dieser Mac wird aus deinen verknüpften Geräten entfernt und die gespeicherte Sitzung gelöscht.")) }
    }
}
