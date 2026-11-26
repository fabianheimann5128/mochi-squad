import SwiftTerm
import SwiftUI

/// Chat with an agent: header, history or console, input.
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
    /// History file the transcript currently shows.
    @State private var shownHistory: String?

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
                }.buttonStyle(.plain).help(t("Edit agent", "Agent bearbeiten"))
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
                }.buttonStyle(.plain).help(t("The agent's computer", "Computer des Agenten"))
            }
            if console, let session {
                SessionTerminal(session: session).padding(.horizontal, 12).padding(.bottom, 12)
            } else {
                TranscriptList(agentName: agent.name, peers: peers, loadEarlier: { Task { await refresh(more: true) } }) {
                    if session == nil, transcript.bubbles.isEmpty, !transcript.loading { EmptyChat(agent: agent) { draft = $0 } }
                    // Until the client has written the new message into its history, it is shown here, below the earlier chat.
                    if let session, !sent(session) { pending(session.task) }
                    if let session {
                        SessionNotice(session: session, name: agent.name) { console = true }
                        LiveExtras(session: session, name: agent.name) { console = true }
                    }
                }
                // Changed settings apply only after the session restarts; here that is always visible.
                if let live = manager.liveSession(for: agent.id), live.signature != (agents.agent(agent.id) ?? agent).sessionSignature {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 12)).foregroundStyle(Desk.dim)
                        Text(t("You changed \(agent.name). The running session still works with the old settings.",
                               "Du hast \(agent.name) geändert. Die laufende Sitzung arbeitet noch mit den alten Einstellungen.")
                             + (agent.provider == .codex ? t(" Codex starts a new chat on restart.", " Codex beginnt beim Neustart einen neuen Chat.") : ""))
                            .font(.system(size: 12.5)).foregroundStyle(Desk.dim)
                        Spacer(minLength: 8)
                        Button(t("Restart session", "Sitzung neu starten")) { manager.restart(agents.agent(agent.id) ?? agent) }.buttonStyle(.pill)
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

    /// Has the client taken the session's first message into its history yet?
    private func sent(_ session: AgentSession) -> Bool {
        guard let path = session.usage.historyPath, shownHistory == path else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    private func pending(_ task: String) -> some View {
        HStack {
            Spacer(minLength: 120)
            Text(Attachments.split(RelayedMessage.parse(task)?.body ?? task).text).font(.system(size: 15)).foregroundStyle(Desk.text).lineSpacing(4)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Desk.bubble, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }.frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// Reads the history while this chat is open.
    private func follow() async {
        transcript.reset()
        // The session on screen is kept even when it ends; earlier sessions of this agent are released.
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
        // A session that has just started has no history file yet: until it has, the agent's earlier chat stays on screen.
        let live = manager.latestSession(for: agent.id)?.usage.historyPath
        guard let current = live.flatMap({ FileManager.default.fileExists(atPath: $0) ? $0 : nil }) ?? journals.last else { return }
        shownHistory = current
        // The history belongs to the program that wrote it, even if the agent has switched provider since.
        let writer: Provider = URL(fileURLWithPath: current).lastPathComponent.hasPrefix("rollout-") ? .codex : .claude
        await transcript.load(current, provider: writer, earlier: journals.filter { $0 != current }, more: more)
    }
}

/// Earlier chat without an agent (read only).
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
            TranscriptList(agentName: entry.providerKind.title, peers: [:], loadEarlier: { Task { await load(more: true) } }) { EmptyView() }
            Text(t("This chat was held outside Mochi Squad and can only be read here.",
                   "Dieser Chat wurde außerhalb von Mochi Squad geführt und lässt sich hier nur lesen."))
                .font(.system(size: 12.5)).foregroundStyle(Desk.dim).padding(.bottom, 18)
        }
        .background(Desk.canvas)
        .task {
            transcript.reset()
            await load()
        }
    }

    private func load(more: Bool = false) async {
        await transcript.load(entry.path, provider: entry.providerKind, more: more)
    }
}

/// Header: title in the middle, buttons on the right.
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
                    }.buttonStyle(.plain).help(t("Show chat list", "Chatliste einblenden")).accessibilityLabel(t("Show chat list", "Chatliste einblenden"))
                }
                Spacer()
                trailing()
            }.padding(.horizontal, 22)
        }.padding(.top, 8).padding(.bottom, 12).frame(height: 66)
    }
}

private struct SessionStatus: View {
    @ObservedObject var session: AgentSession
    var body: some View {
        if session.isRunning {
            let (text, color): (String, SwiftUI.Color) = session.prompt != nil ? (t("waiting for you", "wartet auf dich"), Desk.warning)
                : session.working ? (t("typing …", "schreibt …"), Desk.success) : ("online", Desk.dim)
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
        PillPicker(selection: $console, options: [(false, "Chat"), (true, t("Console", "Konsole"))])
        Button(action: close) {
            Image(systemName: "xmark").font(.system(size: 13)).foregroundStyle(Desk.dim).frame(width: 28, height: 28).contentShape(Rectangle())
        }.buttonStyle(.plain).help(session.isRunning ? t("End session", "Sitzung beenden") : t("Close session", "Sitzung schließen"))
    }
}

/// The history as a list of bubbles. The bubbles are prepared in advance; here they are only drawn.
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
                        Button(t("Load earlier messages", "Frühere Nachrichten laden"), action: reload).buttonStyle(.pill).frame(maxWidth: .infinity).padding(.bottom, 10)
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
            .defaultScrollAnchor(.bottom)
            .onChange(of: transcript.lineCount) { _, _ in
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(150))
                    proxy.scrollTo("end", anchor: .bottom)
                }
            }
        }
    }
}

/// Project folder of the chat on screen, to find attached files.
private struct ProjectFolderKey: EnvironmentKey { static let defaultValue: URL? = nil }
extension EnvironmentValues {
    var projectFolder: URL? {
        get { self[ProjectFolderKey.self] }
        set { self[ProjectFolderKey.self] = newValue }
    }
}

/// Preview of an attached file: images as a fitted tile, everything else with icon and name. A click opens it.
struct AttachmentPreview: View {
    let file: URL
    /// Small square tile for the input field instead of the large view in the history.
    var compact = false

    /// Largest size in the history; the image keeps its aspect ratio.
    private static let limit = CGSize(width: 320, height: 240)

    var body: some View {
        // Images open in Preview; everything else is only revealed in Finder, never run directly.
        Button {
            if Attachments.isImage(file) { NSWorkspace.shared.open(file) } else { NSWorkspace.shared.activateFileViewerSelecting([file]) }
        } label: {
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

/// Draws the rows of a message: paragraphs, and list items with their marker set off so wrapped lines stay aligned.
struct RowsView: View {
    let rows: [TextRow]
    var font: Font = .system(size: 15)

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(rows) { row in
                if let marker = row.marker {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(marker).monospacedDigit().foregroundStyle(Desk.dim).frame(minWidth: 12, alignment: .trailing)
                        Text(row.text).frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    Text(row.text)
                }
            }
        }
        .font(font).foregroundStyle(Desk.text).lineSpacing(4).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
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
                // As in messengers, attachments are tiles of their own above the text, not inside the coloured bubble.
                if let project {
                    ForEach(bubble.attachments.compactMap { Attachments.resolve($0, in: project) }, id: \.self) { AttachmentPreview(file: $0) }
                }
                if !bubble.plain.isEmpty || bubble.attachments.isEmpty || project == nil { textBubble(outgoing: outgoing) }
            }
            .frame(maxWidth: 620, alignment: outgoing ? .trailing : .leading)
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
            RowsView(rows: bubble.rows, font: bubble.kind == .code ? .system(size: 13, design: .monospaced) : .system(size: 15))
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(outgoing ? (bubble.relayedFrom == nil ? Desk.bubble : Desk.relayed) : Desk.incoming,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Below the history of a running session: the client's question or "typing …".
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

/// The client's question as a card: what the agent intends to do, and the answers as buttons.
struct PromptCard: View {
    @ObservedObject var session: AgentSession
    let name: String
    /// Opens the console where that is possible; otherwise the link is left out.
    var openConsole: (() -> Void)?

    var body: some View {
        if let ask = session.prompt {
            // Only real approvals (yes/no) get our own wording; other questions of the client stay as they are.
            let permission = Self.isPermission(ask.options.map(\.label))
            let notice = ask.options.map(\.key) == [TerminalPromptScanner.continueKey]
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: permission ? "hand.raised.fill" : "questionmark.bubble.fill").font(.system(size: 13)).foregroundStyle(Desk.warning)
                        .frame(width: 30, height: 30).background(Desk.warning.opacity(0.15), in: Circle())
                    VStack(alignment: .leading, spacing: 1) {
                        Text(permission ? t("\(name) needs your permission", "\(name) braucht deine Erlaubnis")
                             : notice ? t("\(name)'s program shows a notice", "Das Programm von \(name) zeigt einen Hinweis")
                             : t("\(name) has a question", "\(name) hat eine Rückfrage")).font(.system(size: 14.5, weight: .semibold))
                        Text(permission ? t("Read what is planned, then decide.", "Lies kurz, was geplant ist, und entscheide.")
                             : notice ? t("Confirm it so the work can go on.", "Bestätige ihn, damit es weitergeht.") : t("Choose an answer.", "Wähle eine Antwort.")).font(.system(size: 12)).foregroundStyle(Desk.dim)
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
                        let primary = notice || option.key == "1" || option.key == "pos:\(ask.marked ?? -1)"
                        let text = notice ? (title: t("Continue", "Weiter"), detail: nil) : permission ? Self.wording(option.label) : (title: option.label, detail: nil)
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
                    Button(action: openConsole) { Label(t("View in the console", "In der Konsole ansehen"), systemImage: "terminal") }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Desk.dim)
                }
            }
            .padding(18).frame(maxWidth: 560, alignment: .leading)
            .background(Desk.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Desk.warning.opacity(0.25)) }
        }
    }

    /// An approval is recognised by yes and no answers.
    static func isPermission(_ labels: [String]) -> Bool {
        let lower = labels.map { $0.lowercased() }
        return lower.first?.hasPrefix("yes") == true && lower.contains { $0 == "no" || $0.hasPrefix("no,") || $0.hasPrefix("no ") }
    }

    /// The clients ask in their own wording. Common answers get a short title in the interface language; the original is shown small below it.
    static func wording(_ label: String) -> (title: String, detail: String?) {
        let lower = label.lowercased()
        if lower == "yes" || lower == "yes, proceed" || lower == "allow" { return (t("Allow", "Erlauben"), nil) }
        if lower == "no" || lower.hasPrefix("no,") || lower.hasPrefix("no ") || lower == "deny" { return (t("Deny", "Ablehnen"), lower == "no" || lower == "deny" ? nil : label) }
        if lower.hasPrefix("yes, and don't ask again") || lower.hasPrefix("yes, and dont ask again") { return (t("Allow and don't ask again", "Erlauben und nicht mehr fragen"), label) }
        if lower.hasPrefix("yes, allow all") || lower.hasPrefix("yes, and allow") { return (t("Always allow for this session", "Für diese Sitzung immer erlauben"), label) }
        if lower.hasPrefix("yes, and auto-accept") { return (t("Allow, accept further edits automatically", "Erlauben, weitere Änderungen automatisch"), label) }
        if lower.hasPrefix("yes, and manually") { return (t("Allow, confirm edits one by one", "Erlauben, Änderungen einzeln bestätigen"), label) }
        if lower.hasPrefix("yes") { return (t("Allow", "Erlauben"), label) }
        return (label, nil)
    }
}

/// Tells in the chat when a session cannot work: sign-in needed or failed at start.
private struct SessionNotice: View {
    @ObservedObject var session: AgentSession
    let name: String
    let openConsole: () -> Void

    var body: some View {
        if session.needsLogin {
            card("person.crop.circle.badge.exclamationmark", t("\(name) is waiting for you to sign in", "\(name) wartet auf deine Anmeldung"),
                 t("This agent's program is not signed in yet. Open the console and sign in with your subscription.",
                   "Das Programm dieses Agenten ist noch nicht angemeldet. Öffne die Konsole und melde dich mit deinem Abo an."), nil)
        } else if !session.isRunning, session.failed, !(session.usage.historyPath.map(FileManager.default.fileExists(atPath:)) ?? false) {
            card("exclamationmark.triangle.fill", t("\(name) could not start", "\(name) konnte nicht starten"),
                 t("The session ended before it could work.", "Die Sitzung ist beendet, bevor sie arbeiten konnte."), session.screenText(lines: 6))
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
            Button(action: openConsole) { Label(t("Open console", "Konsole öffnen"), systemImage: "terminal") }.buttonStyle(.pill)
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
            ? [("chart.bar.xaxis", t("What is the status of my projects?", "Wie ist der Stand in meinen Projekten?")),
               ("person.badge.plus", t("Which agents should I create for this project?", "Welche Agenten sollte ich für dieses Projekt anlegen?")),
               ("checklist", t("What should I have done next?", "Was sollte ich als Nächstes erledigen lassen?"))]
            : [("hand.wave", t("Introduce yourself briefly and tell me what you can help with.", "Stell dich kurz vor und sag mir, wobei du helfen kannst.")),
               ("folder", t("Look at the project and summarise it in five sentences.", "Sieh dir das Projekt an und fasse es in fünf Sätzen zusammen.")),
               ("lightbulb", t("Suggest three tasks you could take on.", "Schlag mir drei Aufgaben vor, die du übernehmen könntest."))]
    }

    var body: some View {
        VStack(spacing: 0) {
            MochiAvatar(key: agent.avatar, size: 88)
            Text(agent.name).font(.system(size: 22, weight: .semibold)).padding(.top, 14)
            Text(agent.instructions.isEmpty ? agent.jobTitle : agent.instructions)
                .font(.system(size: 14)).foregroundStyle(Desk.dim).multilineTextAlignment(.center).lineLimit(3).padding(.top, 4)
            // Suggestions as a calm list: same width, left-aligned, one click takes the text.
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

/// Input: writes to the running session or starts a new one.
private struct Composer: View {
    let agent: Agent
    @Binding var draft: String
    @EnvironmentObject private var manager: SessionManager
    @State private var hint: String?
    /// Files that go along with the next message.
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
                                        }.buttonStyle(.plain).offset(x: 5, y: -5).help(t("Remove attachment", "Anhang entfernen"))
                                    }
                            }
                        }.padding(.horizontal, 4).padding(.top, 6)
                    }
                }
                HStack(alignment: .bottom, spacing: 8) {
                    Button { files += Attachments.choose().filter { !files.contains($0) } } label: { RoundGlyph(name: "paperclip") }
                        .buttonStyle(.plain).help(t("Attach images or files", "Bilder oder Dateien anhängen")).accessibilityLabel(t("Attach images or files", "Bilder oder Dateien anhängen"))
                    TextField(t("Message \(agent.name)", "Nachricht an \(agent.name)"), text: $draft, axis: .vertical)
                        .textFieldStyle(.plain).lineLimit(1...6).font(.system(size: 15)).focused($focused).onSubmit(send)
                        .padding(.vertical, 8).frame(minHeight: 34)
                    MicControl(draft: $draft)
                    Button(action: send) { SendGlyph() }.buttonStyle(.plain)
                        .keyboardShortcut(.return, modifiers: .command).disabled(empty).accessibilityLabel(t("Send", "Senden"))
                }
            }
            .composerCapsule()
            // Files can also be dragged onto the input field.
            .dropDestination(for: URL.self) { dropped, _ in
                // Folders are not attached; they would be copied into the project as a whole.
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
            // From here on the copies are in the project; the text carries the references in case sending has to wait.
            if !files.isEmpty { files = []; draft = text }
        } catch { hint = error.localizedDescription; return }
        if let live = manager.liveSession(for: agent.id) {
            if live.send(text) { draft = "" }
            else if live.submitPending {
                Task { @MainActor in try? await Task.sleep(for: .seconds(1.3)); send() }
            } else {
                hint = t("\(agent.name) cannot take a message right now (still starting or waiting for an answer). Your text stays here.",
                         "\(agent.name) kann gerade keine Nachricht annehmen (startet noch oder wartet auf eine Antwort). Dein Text bleibt hier stehen.")
            }
            return
        }
        do {
            try manager.launch(agent, task: text, parentChat: manager.resumableChat(for: agent))
            draft = ""
        } catch { manager.notice = error.localizedDescription }
    }
}

/// The client's real terminal.
struct SessionTerminal: NSViewRepresentable {
    let session: AgentSession
    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = session.terminal
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }
    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
}
