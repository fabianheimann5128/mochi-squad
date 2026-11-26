import SwiftUI

/// Group chat of a project: the user brings in agents with @name, and they answer for everyone to see.
struct TeamChat: View {
    let project: URL
    @Binding var showRail: Bool
    @EnvironmentObject private var agents: AgentStore
    @EnvironmentObject private var team: TeamLog
    @EnvironmentObject private var manager: SessionManager
    @State private var draft = ""
    @FocusState private var focused: Bool

    /// The coordinator comes first: it answers when nobody is addressed.
    private var members: [Agent] { agents.agents(in: project).sorted { $0.isCoordinator && !$1.isCoordinator } }
    private var typing: [String] { manager.teamTyping[project.path] ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            ChatHeader(showRail: $showRail) {
                GlassPill {
                    GroupAvatar(keys: members.prefix(3).map(\.avatar), size: 30, round: true)
                    Text("Team " + project.lastPathComponent).font(.system(size: 15, weight: .medium)).lineLimit(1)
                    if !typing.isEmpty {
                        Text(typingText(typing))
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
                            TeamLineView(line: line, agent: author(of: line), names: members.map(\.name), head: head)
                                .equatable().padding(.top, head ? 14 : 4)
                        }
                        ForEach(manager.teamPrompts(project: project)) { session in
                            PromptCard(session: session, name: agents.agent(session.agentID)?.name ?? "Agent").padding(.top, 12)
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
                        if members.count > 1 { chip(t("@all", "@alle"), avatar: nil, job: nil) }
                    }.padding(.horizontal, 4)
                }
                HStack(alignment: .bottom, spacing: 10) {
                    RoundGlyph(name: "at").accessibilityHidden(true)
                    TextField(t("Message the team, @name brings in an agent", "Nachricht ans Team, @Name holt einen Agenten dazu"), text: $draft, axis: .vertical)
                        .textFieldStyle(.plain).lineLimit(1...6).font(.system(size: 15)).focused($focused).onSubmit(send)
                        .padding(.vertical, 8).frame(minHeight: 34)
                    MicControl(draft: $draft)
                    Button(action: send) { SendGlyph() }.buttonStyle(.plain).keyboardShortcut(.return, modifiers: .command)
                        .accessibilityLabel(t("Send", "Senden"))
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.composerCapsule()
            }.frame(maxWidth: 960).padding(.horizontal, 24).padding(.top, 6).padding(.bottom, 24).frame(maxWidth: .infinity)
        }.background(Desk.canvas)
    }

    /// The agent that wrote a line: by its id, or by name for lines from before ids were stored.
    private func author(of line: TeamLine) -> Agent? {
        if let id = line.agent { return members.first { $0.id == id } }
        return members.first { $0.name == line.from }
    }

    private var intro: some View {
        VStack(spacing: 12) {
            HStack(spacing: -8) { ForEach(members.prefix(4)) { MochiAvatar(key: $0.avatar, size: 44) } }
            Text(t("Just start typing", "Schreib einfach los")).font(.system(size: 17, weight: .semibold))
            Text(t("Without a mention, \(members.first?.name ?? "your coordinator") answers. With @name you bring in a specific agent, with @all the whole team. Everyone knows the conversation and can bring in colleagues.",
                   "Ohne Anrede antwortet \(members.first?.name ?? "dein Koordinator"). Mit @Name holst du einen bestimmten Agenten dazu, mit @alle das ganze Team. Jeder kennt den Verlauf und kann selbst Kollegen einbeziehen."))
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
                if mine, let via = line.via {
                    Label(via, systemImage: "iphone").font(.system(size: 11.5)).foregroundStyle(Desk.faint)
                }
                HStack(spacing: 0) {
                    if mine { Spacer(minLength: 120) }
                    RowsView(rows: rows)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(mine ? Desk.bubble : Desk.incoming, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .frame(maxWidth: 620, alignment: mine ? .trailing : .leading)
                    if !mine { Spacer(minLength: 120) }
                }
            }.frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        }
    }

    /// The answer's Markdown as rows, mentions highlighted.
    private var rows: [TextRow] {
        let called = (names + Mention.everyone).filter { Mention.contains(line.text, $0) }
        let base = line.kind == .user ? [TextRow(id: 0, marker: nil, text: AttributedString(line.text))] : TextRow.rows(line.text)
        return base.map { row in
            var row = row
            for name in called {
                var cursor = row.text.startIndex
                while let range = row.text[cursor...].range(of: "@" + name, options: .caseInsensitive) {
                    // On the blue bubble of the user bold type marks the mention, elsewhere the accent colour.
                    if line.kind == .user { row.text[range].font = .system(size: 15, weight: .semibold) } else { row.text[range].foregroundColor = Desk.accent }
                    cursor = range.upperBound
                }
            }
            return row
        }
    }
}
