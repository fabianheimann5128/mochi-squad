import SwiftTerm
import SwiftUI

/// Chat mit einem Agenten: Kopf, Verlauf oder Konsole, Eingabe.
struct AgentChat: View {
    let agent: Agent
    @Binding var showRail: Bool
    @Binding var showPanel: Bool
    @Binding var panelTab: PanelTab
    let edit: () -> Void

    @EnvironmentObject private var agents: AgentStore
    @EnvironmentObject private var transcript: TranscriptStore
    @EnvironmentObject private var manager: SessionManager
    @State private var draft = ""
    @State private var console = false

    private var session: AgentSession? { manager.latestSession(for: agent.id) }

    var body: some View {
        VStack(spacing: 0) {
            ChatHeader(showRail: $showRail) {
                Button(action: edit) {
                    GlassPill {
                        MochiAvatar(key: agent.avatar, size: 30, round: true)
                        Text(agent.name).font(.system(size: 15, weight: .medium)).lineLimit(1)
                        if let session { SessionStatus(session: session) }
                    }
                }.buttonStyle(.plain).help("Agent bearbeiten")
            } trailing: {
                if let session {
                    SessionControls(session: session, console: $console) { manager.close(session); console = false }
                }
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if showPanel && panelTab == .computer { showPanel = false } else { panelTab = .computer; showPanel = true }
                    }
                } label: {
                    Image(systemName: "display").font(.system(size: 14)).foregroundStyle(showPanel ? Desk.text : Desk.dim)
                        .frame(width: 36, height: 36).background(Desk.glass, in: Circle())
                        .overlay { Circle().strokeBorder(Desk.glassStroke) }.contentShape(Circle())
                }.buttonStyle(.plain).help("Computer des Agenten")
            }
            if console, let session {
                SessionTerminal(session: session).padding(.horizontal, 12).padding(.bottom, 12)
            } else {
                TranscriptList(agentName: agent.name, peers: peers, loadEarlier: { Task { await refresh(more: true) } }) {
                    if transcript.bubbles.isEmpty, !transcript.loading {
                        if let session { pending(session.task) } else { EmptyChat(agent: agent) { draft = $0 } }
                    }
                    if let session {
                        SessionNotice(session: session, name: agent.name) { console = true }
                        LiveExtras(session: session, name: agent.name) { console = true }
                    }
                }
                // Geänderte Einstellungen gelten erst nach einem Neustart der Sitzung; hier ist das immer sichtbar.
                if let live = manager.liveSession(for: agent.id), live.signature != (agents.agent(agent.id) ?? agent).sessionSignature {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 12)).foregroundStyle(Desk.dim)
                        Text("Du hast \(agent.name) geändert. Die laufende Sitzung arbeitet noch mit den alten Einstellungen."
                             + (agent.provider == .codex ? " Codex beginnt beim Neustart einen neuen Chat." : ""))
                            .font(.system(size: 12.5)).foregroundStyle(Desk.dim)
                        Spacer(minLength: 8)
                        Button("Sitzung neu starten") { manager.restart(agents.agent(agent.id) ?? agent) }.buttonStyle(.pill)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8).frame(maxWidth: 960)
                    .background(Desk.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.horizontal, 24)
                }
                Composer(agent: agent, draft: $draft)
            }
        }
        .background(Desk.canvas)
        .environment(\.projectFolder, URL(fileURLWithPath: agent.project, isDirectory: true))
        .task(id: session?.id) { await follow() }
        .onChange(of: transcript.lastLine) { _, line in
            guard let line, line.role != "user" else { return }
            agents.update(agent.id) { $0.lastLine = String(line.text.prefix(160)) }
        }
        .onDisappear { manager.pinned.subtract(manager.sessions.filter { $0.agentID == agent.id }.map(\.id)) }
    }

    private var peers: [String: String] {
        Dictionary(agents.agents.filter { $0.project == agent.project }.map { ($0.name, $0.avatar) }, uniquingKeysWith: { a, _ in a })
    }

    private func pending(_ task: String) -> some View {
        HStack {
            Spacer(minLength: 120)
            Text(Attachments.split(RelayedMessage.parse(task)?.body ?? task).text).font(.system(size: 15)).foregroundStyle(Desk.text).lineSpacing(4)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Desk.bubble, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    /// Liest den Verlauf, solange dieser Chat offen ist.
    private func follow() async {
        transcript.reset()
        // Die gezeigte Sitzung bleibt erhalten, auch wenn sie endet; frühere Sitzungen dieses Agenten werden freigegeben.
        manager.pinned.subtract(manager.sessions.filter { $0.agentID == agent.id }.map(\.id))
        if let session { manager.pinned.insert(session.id) }
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func refresh(more: Bool = false) async {
        let fresh = agents.agent(agent.id) ?? agent
        let journals = fresh.journals.filter { FileManager.default.fileExists(atPath: $0) }
        guard let current = manager.latestSession(for: agent.id)?.usage.historyPath ?? journals.last else { return }
        // Der Verlauf gehört dem Programm, das ihn geschrieben hat, auch wenn der Agent inzwischen den Anbieter gewechselt hat.
        let writer: Provider = URL(fileURLWithPath: current).lastPathComponent.hasPrefix("rollout-") ? .codex : .claude
        await transcript.load(current, provider: writer, earlier: journals.filter { $0 != current }, more: more)
    }
}

/// Früherer Chat ohne Agenten (nur lesen).
struct ArchiveChat: View {
    let entry: ChatEntry
    @Binding var showRail: Bool
    @EnvironmentObject private var transcript: TranscriptStore

    var body: some View {
        VStack(spacing: 0) {
            ChatHeader(showRail: $showRail) {
                GlassPill {
                    Image(systemName: "bubble.left").font(.system(size: 13)).foregroundStyle(Desk.dim).padding(.leading, 8)
                    Text(entry.title).font(.system(size: 15, weight: .medium)).lineLimit(1)
                }.frame(maxWidth: 420)
            } trailing: { EmptyView() }
            TranscriptList(agentName: entry.providerKind.title, peers: [:]) { EmptyView() }
            Text("Dieser Chat wurde außerhalb von Mochi Squad geführt und lässt sich hier nur lesen.")
                .font(.system(size: 12.5)).foregroundStyle(Desk.dim).padding(.bottom, 18)
        }
        .background(Desk.canvas)
        .task {
            transcript.reset()
            await transcript.load(entry.path, provider: entry.providerKind)
        }
    }
}

/// Kopfzeile: Titel in der Mitte, Knöpfe rechts.
struct ChatHeader<Title: View, Trailing: View>: View {
    @Binding var showRail: Bool
    @ViewBuilder let title: () -> Title
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        ZStack {
            title()
            HStack(spacing: 8) {
                if !showRail {
                    Button { withAnimation(.easeInOut(duration: 0.2)) { showRail = true } } label: {
                        Image(systemName: "sidebar.left").font(.system(size: 15)).foregroundStyle(Desk.dim).frame(width: 30, height: 30).contentShape(Rectangle())
                    }.buttonStyle(.plain).help("Seitenleiste einblenden")
                }
                Spacer()
                trailing()
            }.padding(.leading, showRail ? 22 : 84).padding(.trailing, 22)
        }.padding(.top, 8).padding(.bottom, 12).frame(height: 66)
    }
}

private struct SessionStatus: View {
    @ObservedObject var session: AgentSession
    var body: some View {
        if session.isRunning {
            let (text, color): (String, SwiftUI.Color) = session.prompt != nil ? ("wartet auf dich", Desk.warning)
                : session.working ? ("schreibt …", Desk.success) : ("online", Desk.dim)
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(text).font(.system(size: 12)).foregroundStyle(color).lineLimit(1)
            }.fixedSize()
        }
    }
}

private struct SessionControls: View {
    @ObservedObject var session: AgentSession
    @Binding var console: Bool
    let close: () -> Void
    var body: some View {
        PillPicker(selection: $console, options: [(false, "Chat"), (true, "Konsole")])
        Button(action: close) {
            Image(systemName: "xmark").font(.system(size: 13)).foregroundStyle(Desk.dim).frame(width: 28, height: 28).contentShape(Rectangle())
        }.buttonStyle(.plain).help(session.isRunning ? "Sitzung beenden" : "Sitzung schließen")
    }
}

/// Der Verlauf als Liste von Blasen. Die Blasen sind vorab aufbereitet; hier wird nur gezeichnet.
struct TranscriptList<Extras: View>: View {
    let agentName: String
    let peers: [String: String]
    var loadEarlier: (() -> Void)?
    @ViewBuilder let extras: () -> Extras
    @EnvironmentObject private var transcript: TranscriptStore

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if transcript.older, let reload = loadEarlier {
                        Button("Frühere Nachrichten laden", action: reload).buttonStyle(.pill).frame(maxWidth: .infinity).padding(.bottom, 10)
                    }
                    if let issue = transcript.issue { NoticeLine(text: issue) }
                    if transcript.loading && transcript.bubbles.isEmpty { ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, 40) }
                    ForEach(transcript.bubbles) { bubble in
                        if let day = bubble.day { NoticeLine(text: day).padding(.top, bubble.gap == 0 ? 0 : 22).padding(.bottom, 4) }
                        BubbleView(bubble: bubble, avatar: bubble.relayedFrom.flatMap { peers[$0] }).equatable().padding(.top, bubble.gap)
                    }
                    VStack(alignment: .leading, spacing: 12) { extras() }.padding(.top, 14)
                    Color.clear.frame(height: 1).id("end")
                }.frame(maxWidth: 960, alignment: .leading).padding(.horizontal, 24).padding(.vertical, 18).frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(transcript.bubbles.isEmpty ? .center : .bottom)
            .onChange(of: transcript.lineCount) { _, _ in
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(150))
                    proxy.scrollTo("end", anchor: .bottom)
                }
            }
        }
    }
}

/// Projektordner des gezeigten Chats, um angehängte Dateien zu finden.
private struct ProjectFolderKey: EnvironmentKey { static let defaultValue: URL? = nil }
extension EnvironmentValues {
    var projectFolder: URL? {
        get { self[ProjectFolderKey.self] }
        set { self[ProjectFolderKey.self] = newValue }
    }
}

/// Vorschau einer angehängten Datei: Bilder als passgenaue Kachel, alles andere mit Symbol und Namen. Ein Klick öffnet sie.
struct AttachmentPreview: View {
    let file: URL
    /// Kleine quadratische Kachel fürs Eingabefeld statt der großen Ansicht im Verlauf.
    var compact = false

    /// Größte Darstellung im Verlauf; das Bild behält sein Seitenverhältnis.
    private static let limit = CGSize(width: 320, height: 240)

    var body: some View {
        Button { NSWorkspace.shared.open(file) } label: {
            if Attachments.isImage(file), let image = NSImage(contentsOf: file), image.size.width > 0, image.size.height > 0 {
                let size = compact ? CGSize(width: 44, height: 44) : Self.fitted(image.size)
                let shape = RoundedRectangle(cornerRadius: compact ? 9 : 14, style: .continuous)
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height).clipShape(shape)
                    .overlay { shape.strokeBorder(Color.white.opacity(0.12)) }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text").font(.system(size: 14)).foregroundStyle(Desk.dim)
                    Text(file.lastPathComponent).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                }
                .padding(.horizontal, 12).frame(height: compact ? 44 : 40).frame(maxWidth: 240)
                .background(Desk.card, in: RoundedRectangle(cornerRadius: compact ? 9 : 12, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: compact ? 9 : 12, style: .continuous).strokeBorder(Desk.edge) }
            }
        }.buttonStyle(.plain).help(file.lastPathComponent)
    }

    static func fitted(_ size: CGSize) -> CGSize {
        let scale = min(1, limit.width / size.width, limit.height / size.height)
        return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }
}

struct BubbleView: View, Equatable {
    let bubble: Bubble
    let avatar: String?
    @Environment(\.projectFolder) private var project

    static func == (left: BubbleView, right: BubbleView) -> Bool { left.bubble == right.bubble && left.avatar == right.avatar }

    var body: some View {
        let outgoing = bubble.kind == .user
        HStack(spacing: 0) {
            if outgoing { Spacer(minLength: 120) }
            VStack(alignment: outgoing ? .trailing : .leading, spacing: 6) {
                // Anhänge stehen wie in Messengern als eigene Kacheln über dem Text, nicht in der farbigen Blase.
                if let project {
                    ForEach(bubble.attachments, id: \.self) { AttachmentPreview(file: project.appendingPathComponent($0)) }
                }
                if !bubble.plain.isEmpty || bubble.attachments.isEmpty || project == nil { textBubble(outgoing: outgoing) }
            }
            .frame(maxWidth: 680, alignment: outgoing ? .trailing : .leading)
            if !outgoing { Spacer(minLength: 120) }
        }.frame(maxWidth: .infinity, alignment: outgoing ? .trailing : .leading)
    }

    private func textBubble(outgoing: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let sender = bubble.relayedFrom {
                HStack(spacing: 6) {
                    if let avatar { MochiAvatar(key: avatar, size: 18) }
                    Text(sender).font(.system(size: 13, weight: .semibold)).foregroundStyle(avatar.map { MochiLook(key: $0).color } ?? Desk.accent)
                    Text(bubble.relayedVia ?? "").font(.system(size: 12)).foregroundStyle(Desk.dim)
                }
            }
            Text(bubble.text).font(bubble.kind == .code ? .system(size: 13, design: .monospaced) : .system(size: 15))
                .foregroundStyle(Desk.text).lineSpacing(4).textSelection(.enabled)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(outgoing ? (bubble.relayedFrom == nil ? Desk.bubble : Desk.relayed) : Desk.incoming,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Unter dem Verlauf einer laufenden Sitzung: Rückfrage des Clients oder „schreibt …“.
private struct LiveExtras: View {
    @ObservedObject var session: AgentSession
    let name: String
    let openConsole: () -> Void
    var body: some View {
        if session.isRunning {
            PromptCard(session: session, name: name, openConsole: openConsole)
            if session.working, session.prompt == nil { TypingBubble(name: name) }
        }
    }
}

/// Rückfrage des Clients als Karte: beantworten per Klick statt in der Konsole.
/// Rückfrage des Clients als Karte: Was der Agent vorhat, und die Antworten als Knöpfe.
struct PromptCard: View {
    @ObservedObject var session: AgentSession
    let name: String
    /// Öffnet die Konsole, wo das geht; sonst entfällt der Verweis.
    var openConsole: (() -> Void)?

    var body: some View {
        if let ask = session.prompt {
            // Nur echte Freigaben (Ja/Nein) bekommen deutsche Antworten; Auswahlfragen des Clients bleiben im Original.
            let permission = Self.isPermission(ask.options.map(\.label))
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: permission ? "hand.raised.fill" : "questionmark.bubble.fill").font(.system(size: 13)).foregroundStyle(Desk.warning)
                        .frame(width: 30, height: 30).background(Desk.warning.opacity(0.15), in: Circle())
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name + (permission ? " braucht deine Erlaubnis" : " hat eine Rückfrage")).font(.system(size: 14.5, weight: .semibold))
                        Text(permission ? "Lies kurz, was geplant ist, und entscheide." : "Wähle eine Antwort.").font(.system(size: 12)).foregroundStyle(Desk.dim)
                    }
                }
                if !ask.context.isEmpty {
                    Text(ask.context.joined(separator: "\n")).font(.system(size: 13)).foregroundStyle(Desk.text.opacity(0.85))
                        .lineSpacing(3).lineLimit(8).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background(Desk.canvas.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Desk.edge) }
                }
                VStack(spacing: 6) {
                    ForEach(ask.options) { option in
                        let primary = option.key == "1" || option.key == "pos:\(ask.marked ?? -1)"
                        let text = permission ? Self.wording(option.label) : (title: option.label, detail: nil)
                        Button { session.answer(option) } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(text.title).font(.system(size: 13.5, weight: .semibold))
                                if let detail = text.detail { Text(detail).font(.system(size: 11.5)).opacity(0.7).lineLimit(2) }
                            }
                            .multilineTextAlignment(.leading).foregroundStyle(primary ? Color.white : Desk.text)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.vertical, 9)
                            .background(primary ? Desk.accent : Desk.pillSelected, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
                if let openConsole {
                    Button(action: openConsole) { Label("In der Konsole ansehen", systemImage: "terminal") }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Desk.dim)
                }
            }
            .padding(18).frame(maxWidth: 560, alignment: .leading)
            .background(Desk.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Desk.warning.opacity(0.25)) }
        }
    }

    /// Eine Freigabe erkennt man an Ja- und Nein-Antworten.
    static func isPermission(_ labels: [String]) -> Bool {
        let lower = labels.map { $0.lowercased() }
        return lower.first?.hasPrefix("yes") == true && lower.contains { $0 == "no" || $0.hasPrefix("no,") || $0.hasPrefix("no ") }
    }

    /// Die Clients fragen auf Englisch. Häufige Antworten bekommen eine deutsche Überschrift; das Original steht klein darunter.
    static func wording(_ label: String) -> (title: String, detail: String?) {
        let lower = label.lowercased()
        if lower == "yes" || lower == "yes, proceed" || lower == "allow" { return ("Erlauben", nil) }
        if lower == "no" || lower.hasPrefix("no,") || lower.hasPrefix("no ") || lower == "deny" { return ("Ablehnen", lower == "no" || lower == "deny" ? nil : label) }
        if lower.hasPrefix("yes, and don't ask again") || lower.hasPrefix("yes, and dont ask again") { return ("Erlauben und nicht mehr fragen", label) }
        if lower.hasPrefix("yes, allow all") || lower.hasPrefix("yes, and allow") { return ("Für diese Sitzung immer erlauben", label) }
        if lower.hasPrefix("yes, and auto-accept") { return ("Erlauben, weitere Änderungen automatisch", label) }
        if lower.hasPrefix("yes, and manually") { return ("Erlauben, Änderungen einzeln bestätigen", label) }
        if lower.hasPrefix("yes") { return ("Erlauben", label) }
        return (label, nil)
    }
}

/// Meldet im Chat, wenn eine Sitzung nicht arbeiten kann: Anmeldung nötig oder beim Start gescheitert.
private struct SessionNotice: View {
    @ObservedObject var session: AgentSession
    let name: String
    let openConsole: () -> Void

    var body: some View {
        if session.needsLogin {
            card("person.crop.circle.badge.exclamationmark", "\(name) wartet auf deine Anmeldung",
                 "Das Programm dieses Agenten ist noch nicht angemeldet. Öffne die Konsole und melde dich mit deinem Abo an.", nil)
        } else if !session.isRunning, session.failed, session.usage.historyPath == nil {
            card("exclamationmark.triangle.fill", "\(name) konnte nicht starten", "Die Sitzung ist beendet, bevor sie arbeiten konnte.", session.screenText(lines: 6))
        }
    }

    private func card(_ symbol: String, _ title: String, _ text: String, _ output: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(Desk.warning)
                    .frame(width: 30, height: 30).background(Desk.warning.opacity(0.15), in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 14.5, weight: .semibold))
                    Text(text).font(.system(size: 12.5)).foregroundStyle(Desk.dim).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let output, !output.isEmpty {
                Text(output).font(.system(size: 12.5)).foregroundStyle(Desk.text.opacity(0.85)).lineLimit(6).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 10)
                    .background(Desk.canvas.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            Button(action: openConsole) { Label("Konsole öffnen", systemImage: "terminal") }.buttonStyle(.pill)
        }
        .padding(18).frame(maxWidth: 560, alignment: .leading)
        .background(Desk.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct EmptyChat: View {
    let agent: Agent
    let suggest: (String) -> Void
    @State private var hovered: String?

    private var examples: [(symbol: String, text: String)] {
        agent.isCoordinator
            ? [("chart.bar.xaxis", "Wie ist der Stand in meinen Projekten?"),
               ("person.badge.plus", "Welche Agenten sollte ich für dieses Projekt anlegen?"),
               ("checklist", "Was sollte ich als Nächstes erledigen lassen?")]
            : [("hand.wave", "Stell dich kurz vor und sag mir, wobei du helfen kannst."),
               ("folder", "Sieh dir das Projekt an und fasse es in fünf Sätzen zusammen."),
               ("lightbulb", "Schlag mir drei Aufgaben vor, die du übernehmen könntest.")]
    }

    var body: some View {
        VStack(spacing: 0) {
            MochiAvatar(key: agent.avatar, size: 88)
            Text(agent.name).font(.system(size: 22, weight: .semibold)).padding(.top, 14)
            Text(agent.instructions.isEmpty ? agent.jobTitle : agent.instructions)
                .font(.system(size: 14)).foregroundStyle(Desk.dim).multilineTextAlignment(.center).lineLimit(3).padding(.top, 4)
            // Vorschläge als ruhige Liste: gleiche Breite, links ausgerichtet, ein Klick übernimmt den Text.
            VStack(spacing: 0) {
                ForEach(Array(examples.enumerated()), id: \.element.text) { index, example in
                    if index > 0 { Rectangle().fill(Desk.rule).frame(height: 1).padding(.leading, 44) }
                    Button { suggest(example.text) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: example.symbol).font(.system(size: 13)).foregroundStyle(Desk.dim).frame(width: 20)
                            Text(example.text).font(.system(size: 13.5)).foregroundStyle(Desk.text).lineLimit(1)
                            Spacer(minLength: 8)
                            Image(systemName: "arrow.up.left").font(.system(size: 11, weight: .medium)).foregroundStyle(Desk.faint)
                        }
                        .padding(.horizontal, 14).frame(height: 44)
                        .background(hovered == example.text ? Desk.pillSelected.opacity(0.5) : .clear)
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain).onHover { hovered = $0 ? example.text : (hovered == example.text ? nil : hovered) }
                }
            }
            .background(Desk.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Desk.edge) }
            .padding(.top, 26)
        }.frame(maxWidth: 460).frame(maxWidth: .infinity).padding(.top, 80)
    }
}

/// Eingabe: schreibt in die laufende Sitzung oder startet eine neue.
private struct Composer: View {
    let agent: Agent
    @Binding var draft: String
    @EnvironmentObject private var manager: SessionManager
    @State private var hint: String?
    /// Dateien, die mit der nächsten Nachricht mitgehen.
    @State private var files = [URL]()
    @FocusState private var focused: Bool

    private var empty: Bool { draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && files.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let hint { Text(hint).font(.system(size: 12.5)).foregroundStyle(Desk.dim).padding(.horizontal, 20) }
            VStack(alignment: .leading, spacing: 6) {
                if !files.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(files, id: \.self) { file in
                                AttachmentPreview(file: file, compact: true)
                                    .overlay(alignment: .topTrailing) {
                                        Button { files.removeAll { $0 == file } } label: {
                                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                                                .frame(width: 16, height: 16).background(Color.black.opacity(0.75), in: Circle())
                                        }.buttonStyle(.plain).offset(x: 5, y: -5).help("Anhang entfernen")
                                    }
                            }
                        }.padding(.horizontal, 4).padding(.top, 6)
                    }
                }
                HStack(alignment: .bottom, spacing: 8) {
                    Button { files += Attachments.choose().filter { !files.contains($0) } } label: { RoundGlyph(name: "paperclip") }
                        .buttonStyle(.plain).help("Bilder oder Dateien anhängen")
                    TextField("Nachricht an " + agent.name, text: $draft, axis: .vertical)
                        .textFieldStyle(.plain).lineLimit(1...6).font(.system(size: 15)).focused($focused).onSubmit(send)
                        .padding(.vertical, 8).frame(minHeight: 34)
                    MicControl(draft: $draft)
                    Button(action: send) { SendGlyph() }.buttonStyle(.plain)
                        .keyboardShortcut(.return, modifiers: .command).disabled(empty)
                }
            }
            .composerCapsule()
            // Dateien lassen sich auch auf das Eingabefeld ziehen.
            .dropDestination(for: URL.self) { dropped, _ in
                // Ordner werden nicht angehängt; sie würden komplett ins Projekt kopiert.
                files += dropped.filter { $0.isFileURL && !$0.hasDirectoryPath && !files.contains($0) }
                return !dropped.isEmpty
            }
        }.frame(maxWidth: 960).padding(.horizontal, 24).padding(.top, 6).padding(.bottom, 24).frame(maxWidth: .infinity)
    }

    private func send() {
        guard !empty else { return }
        hint = nil
        let text: String
        do {
            let staged = try Attachments.stage(files, in: URL(fileURLWithPath: agent.project))
            text = Attachments.message(draft.trimmingCharacters(in: .whitespacesAndNewlines), files: staged)
            // Ab hier liegen die Kopien im Projekt; der Text trägt die Verweise, falls das Senden gleich warten muss.
            if !files.isEmpty { files = []; draft = text }
        } catch { hint = error.localizedDescription; return }
        if let live = manager.liveSession(for: agent.id) {
            if live.send(text) { draft = "" }
            else if live.submitPending {
                Task { @MainActor in try? await Task.sleep(for: .seconds(1.3)); send() }
            } else {
                hint = "\(agent.name) kann gerade keine Nachricht annehmen (startet noch oder wartet auf eine Antwort). Dein Text bleibt hier stehen."
            }
            return
        }
        do {
            try manager.launch(agent, task: text, parentChat: manager.resumableChat(for: agent))
            draft = ""
        } catch { manager.notice = error.localizedDescription }
    }
}

/// Das echte Terminal des Clients.
struct SessionTerminal: NSViewRepresentable {
    let session: AgentSession
    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = session.terminal
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }
    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
}
