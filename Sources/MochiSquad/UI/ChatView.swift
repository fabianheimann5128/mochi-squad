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
                    if let session { LiveExtras(session: session, name: agent.name) { console = true } }
                }
                Composer(agent: agent, session: session, draft: $draft, openConsole: { console = true })
            }
        }
        .background(Desk.canvas)
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
            Text(task).font(.system(size: 15)).foregroundStyle(Desk.text).lineSpacing(4)
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
        await transcript.load(current, provider: fresh.provider, earlier: journals.filter { $0 != current }, more: more)
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

struct BubbleView: View, Equatable {
    let bubble: Bubble
    let avatar: String?

    var body: some View {
        let outgoing = bubble.kind == .user
        HStack(spacing: 0) {
            if outgoing { Spacer(minLength: 120) }
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
            .frame(maxWidth: 680, alignment: outgoing ? .trailing : .leading)
            if !outgoing { Spacer(minLength: 120) }
        }.frame(maxWidth: .infinity, alignment: outgoing ? .trailing : .leading)
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
struct PromptCard: View {
    @ObservedObject var session: AgentSession
    let name: String
    let openConsole: () -> Void

    var body: some View {
        if let ask = session.prompt {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "hand.raised.fill").font(.system(size: 13)).foregroundStyle(Desk.warning)
                    Text(name + " möchte fortfahren").font(.system(size: 14.5, weight: .semibold))
                    Spacer()
                    Text("Freigabe").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Desk.warning)
                        .padding(.horizontal, 8).padding(.vertical, 3).background(Desk.warning.opacity(0.14), in: Capsule())
                }
                if !ask.context.isEmpty {
                    Text(ask.context.joined(separator: "\n")).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(Desk.dim)
                        .lineLimit(8).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10).background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 10))
                }
                ForEach(ask.options) { option in
                    let primary = option.key == "1" || option.key == "pos:\(ask.marked ?? -1)"
                    Button { session.answer(option) } label: {
                        Text(option.label).font(.system(size: 13.5, weight: .medium)).multilineTextAlignment(.leading)
                            .foregroundStyle(primary ? Desk.onPrimary : Desk.text)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.vertical, 9)
                            .background(primary ? Desk.primary : Desk.selected, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                Button("In der Konsole ansehen", action: openConsole).buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Desk.dim)
            }
            .padding(.horizontal, 20).padding(.vertical, 16).frame(maxWidth: 620, alignment: .leading)
            .background(Desk.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
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
    let session: AgentSession?
    @Binding var draft: String
    let openConsole: () -> Void
    @EnvironmentObject private var manager: SessionManager
    @State private var hint: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let hint { Text(hint).font(.system(size: 12.5)).foregroundStyle(Desk.dim).padding(.horizontal, 20) }
            HStack(alignment: .bottom, spacing: 10) {
                Button(action: openConsole) { RoundGlyph(name: "terminal") }.buttonStyle(.plain)
                    .help("Konsole des Agenten öffnen").disabled(session == nil).opacity(session == nil ? 0.4 : 1)
                TextField("Nachricht an " + agent.name, text: $draft, axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(1...6).font(.system(size: 15)).onSubmit(send)
                    .padding(.vertical, 8).frame(minHeight: 34)
                Button(action: send) { SendGlyph() }.buttonStyle(.plain)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.composerCapsule()
        }.frame(maxWidth: 960).padding(.horizontal, 24).padding(.top, 6).padding(.bottom, 24).frame(maxWidth: .infinity)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        hint = nil
        if let live = manager.liveSession(for: agent.id) {
            if live.send(text) { draft = "" }
            else if live.submitPending {
                Task { @MainActor in try? await Task.sleep(for: .seconds(1.3)); send() }
            } else {
                hint = "\(agent.name) wartet gerade auf eine Eingabe in der Konsole. Dein Text bleibt hier stehen."
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
