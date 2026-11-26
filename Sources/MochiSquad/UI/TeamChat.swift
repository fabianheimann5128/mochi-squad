import SwiftUI

/// Gruppenchat eines Projekts: Der Nutzer holt Agenten mit @Name dazu, sie antworten für alle sichtbar.
struct TeamChat: View {
    let project: URL
    @Binding var showRail: Bool
    @EnvironmentObject private var agents: AgentStore
    @EnvironmentObject private var team: TeamLog
    @EnvironmentObject private var manager: SessionManager
    @State private var draft = ""
    @FocusState private var focused: Bool

    /// Der Koordinator steht vorn: Er antwortet, wenn niemand angesprochen ist.
    private var members: [Agent] { agents.agents(in: project).sorted { $0.isCoordinator && !$1.isCoordinator } }
    private var typing: [String] { manager.teamTyping[project.path] ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            ChatHeader(showRail: $showRail) {
                GlassPill {
                    GroupAvatar(keys: members.prefix(3).map(\.avatar), size: 30, round: true)
                    Text("Team " + project.lastPathComponent).font(.system(size: 15, weight: .medium)).lineLimit(1)
                    if !typing.isEmpty {
                        Text(typing.joined(separator: ", ") + (typing.count == 1 ? " schreibt …" : " schreiben …"))
                            .font(.system(size: 12)).foregroundStyle(Desk.success).lineLimit(1)
                    }
                }
            } trailing: { EmptyView() }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if team.lines.isEmpty { intro }
                        ForEach(Array(team.lines.enumerated()), id: \.element.id) { index, line in
                            let head = index == 0 || team.lines[index - 1].from != line.from || team.lines[index - 1].kind != line.kind
                            TeamLineView(line: line, agent: members.first { $0.name == line.from }, names: members.map(\.name), head: head)
                                .equatable().padding(.top, head ? 14 : 4)
                        }
                        ForEach(manager.teamPrompts(project: project)) { session in
                            PromptCard(session: session, name: agents.agent(session.agentID)?.name ?? "Agent") {}.padding(.top, 12)
                        }
                        if !typing.isEmpty { TypingBubble(name: typing[0]).padding(.top, 10) }
                        Color.clear.frame(height: 1).id("end")
                    }.frame(maxWidth: 960, alignment: .leading).padding(.horizontal, 24).padding(.vertical, 18).frame(maxWidth: .infinity)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: team.lines.count) { _, _ in
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(150))
                        proxy.scrollTo("end", anchor: .bottom)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(members) { chip("@" + $0.name, avatar: $0.avatar, job: $0.jobTitle) }
                        if members.count > 1 { chip("@alle", avatar: nil, job: nil) }
                    }.padding(.horizontal, 4)
                }
                HStack(alignment: .bottom, spacing: 10) {
                    RoundGlyph(name: "at").accessibilityHidden(true)
                    TextField("Nachricht ans Team, @Name holt einen Agenten dazu", text: $draft, axis: .vertical)
                        .textFieldStyle(.plain).lineLimit(1...6).font(.system(size: 15)).focused($focused).onSubmit(send)
                        .padding(.vertical, 8).frame(minHeight: 34)
                    MicControl(draft: $draft)
                    Button(action: send) { SendGlyph() }.buttonStyle(.plain).keyboardShortcut(.return, modifiers: .command)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.composerCapsule()
            }.frame(maxWidth: 960).padding(.horizontal, 24).padding(.top, 6).padding(.bottom, 24).frame(maxWidth: .infinity)
        }.background(Desk.canvas)
    }

    private var intro: some View {
        VStack(spacing: 12) {
            HStack(spacing: -8) { ForEach(members.prefix(4)) { MochiAvatar(key: $0.avatar, size: 44) } }
            Text("Schreib einfach los").font(.system(size: 17, weight: .semibold))
            Text("Ohne Anrede antwortet \(members.first?.name ?? "dein Koordinator"). Mit @Name holst du einen bestimmten Agenten dazu, mit @alle das ganze Team. Jeder kennt den Verlauf und kann selbst Kollegen einbeziehen.")
                .font(.system(size: 14)).foregroundStyle(Desk.dim).multilineTextAlignment(.center)
        }.frame(maxWidth: 460).frame(maxWidth: .infinity).padding(.top, 110)
    }

    private func chip(_ mention: String, avatar: String?, job: String?) -> some View {
        Button {
            if !Mention.contains(draft, String(mention.dropFirst())) { draft = mention + " " + draft }
            focused = true
        } label: {
            HStack(spacing: 6) {
                if let avatar { MochiAvatar(key: avatar, size: 18, round: true) }
                Text(mention).font(.system(size: 13, weight: .medium))
                if let job { Text(job).font(.system(size: 12)).foregroundStyle(Desk.faint) }
            }.padding(.leading, avatar == nil ? 12 : 6).padding(.trailing, 12).frame(height: 30)
                .background(Desk.card, in: Capsule()).overlay { Capsule().strokeBorder(Desk.edge) }.contentShape(Capsule())
        }.buttonStyle(.plain)
    }

    private func send() {
        manager.sendToTeam(draft, project: project)
        draft = ""
    }
}

private struct TeamLineView: View, Equatable {
    let line: TeamLine
    let agent: Agent?
    let names: [String]
    let head: Bool

    static func == (a: TeamLineView, b: TeamLineView) -> Bool {
        a.line == b.line && a.head == b.head && a.agent?.avatar == b.agent?.avatar && a.names == b.names
    }

    var body: some View {
        switch line.kind {
        case .notice:
            NoticeLine(text: line.text)
        case .user, .agent:
            let mine = line.kind == .user
            VStack(alignment: mine ? .trailing : .leading, spacing: 6) {
                if !mine && head {
                    HStack(spacing: 6) {
                        MochiAvatar(key: agent?.avatar ?? line.from, size: 20)
                        Text(line.from).font(.system(size: 14, weight: .semibold)).foregroundStyle(agent.map { MochiLook(key: $0.avatar).color } ?? Desk.accent)
                        if let job = agent?.jobTitle { Text(job).font(.system(size: 12)).foregroundStyle(Desk.faint) }
                    }
                }
                HStack(spacing: 0) {
                    if mine { Spacer(minLength: 120) }
                    Text(rich).font(.system(size: 15)).foregroundStyle(Desk.text).lineSpacing(4).textSelection(.enabled)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(mine ? Desk.bubble : Desk.incoming, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .frame(maxWidth: 680, alignment: mine ? .trailing : .leading)
                    if !mine { Spacer(minLength: 120) }
                }
            }.frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        }
    }

    /// Markdown der Antwort, Erwähnungen farbig.
    private var rich: AttributedString {
        var text = line.kind == .user ? AttributedString(line.text)
            : (try? AttributedString(markdown: line.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(line.text)
        for name in names + ["alle", "team"] where Mention.contains(line.text, name) {
            var cursor = text.startIndex
            while let range = text[cursor...].range(of: "@" + name, options: .caseInsensitive) {
                // Auf der blauen eigenen Blase hebt Fettdruck die Erwähnung hervor, sonst die Akzentfarbe.
                if line.kind == .user { text[range].font = .system(size: 15, weight: .semibold) } else { text[range].foregroundColor = Desk.accent }
                cursor = range.upperBound
            }
        }
        return text
    }
}
