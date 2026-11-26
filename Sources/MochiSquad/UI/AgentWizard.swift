import SwiftUI

/// Create a new agent, step by step: one question per page, Return moves on.
struct AgentWizard: View {
    @State var agent: Agent
    let save: (Agent) -> Void
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var agents: AgentStore
    @State private var step = Step.name
    @FocusState private var focus: Step?

    private enum Step: Int, CaseIterable { case name, job, tasks, manner, engine, rights }
    private static let names = ["Mira", "Otto", "Juna", "Finn", "Lia", "Nico", "Ida", "Theo", "Emil", "Nora"]

    /// It only moves on once the page's question is answered.
    private var canContinue: Bool {
        func filled(_ text: String) -> Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        switch step {
        case .name: return filled(agent.name) && !nameTaken
        case .job: return filled(agent.job)
        case .tasks: return filled(agent.instructions)
        case .manner: return filled(agent.persona)
        // If Codex does not know its models yet (fresh install), it goes on with Codex's own default.
        case .engine: return !agent.model.isEmpty || agent.models.isEmpty
        case .rights: return true
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            MochiAvatar(key: agent.avatar, size: 84).padding(.top, 26)
            Group {
                switch step {
                case .name: name
                case .job: job
                case .tasks: tasks
                case .manner: manner
                case .engine: engine
                case .rights: rights
                }
            }.padding(.horizontal, 34).padding(.top, 16).frame(height: 268, alignment: .top)
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.self) { item in
                    Capsule().fill(item == step ? Desk.text : Desk.edge).frame(width: item == step ? 18 : 6, height: 6)
                }
            }.padding(.bottom, 14).accessibilityHidden(true)
            Rectangle().fill(Desk.rule).frame(height: 1)
            HStack(spacing: 10) {
                Button(t("Cancel", "Abbrechen")) { dismiss() }.buttonStyle(.pill).keyboardShortcut(.cancelAction)
                Spacer()
                if step != .name { Button(t("Back", "Zurück")) { go(-1) }.buttonStyle(.pill) }
                Button(step == .rights ? t("Create Mochi", "Mochi anlegen") : t("Continue", "Weiter")) { step == .rights ? finish() : go(1) }
                    .buttonStyle(.primaryPill).keyboardShortcut(.defaultAction).disabled(!canContinue).opacity(canContinue ? 1 : 0.5)
            }.padding(.horizontal, 22).padding(.vertical, 16)
        }
        .frame(width: 520)
        .onAppear {
            // A suggestion that is still free in the project.
            if agent.name.isEmpty { agent.name = Self.names.filter { !taken.contains($0.lowercased()) }.randomElement() ?? "" }
            focus = .name
        }
    }

    // MARK: Steps

    private var name: some View {
        VStack(spacing: 14) {
            question(t("What should your Mochi be called?", "Wie soll dein Mochi heißen?"),
                     t("You address it by this name in the team chat.", "Mit diesem Namen sprichst du ihn im Team-Chat an."))
            TextField("Name", text: $agent.name).textFieldStyle(.plain).font(.system(size: 15)).multilineTextAlignment(.center)
                .focused($focus, equals: .name).padding(.horizontal, 14).frame(width: 240, height: 40).field(12)
            if nameTaken {
                Text(Self.nameTakenText)
                    .font(.system(size: 12.5)).foregroundStyle(Desk.warning).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            Button { agent.avatar = MochiLook.random().key } label: { Label(t("Shuffle look", "Aussehen würfeln"), systemImage: "dice") }.buttonStyle(.pill)
        }
    }

    private var job: some View {
        VStack(spacing: 14) {
            question(t("What is \(shownName)'s job title?", "Wie ist \(shownName)s Jobbezeichnung?"),
                     t("Type your own or take a suggestion.", "Tipp eine eigene ein oder nimm einen Vorschlag."))
            TextField(Self.jobPlaceholder, text: $agent.job).textFieldStyle(.plain).font(.system(size: 15))
                .multilineTextAlignment(.center).focused($focus, equals: .job).padding(.horizontal, 14).frame(width: 320, height: 40).field(12)
            HStack(spacing: 6) {
                ForEach(AgentTemplate.all) { template in
                    Button {
                        // A suggestion brings fitting tasks and rights along; both can be changed in the next steps.
                        agent.job = template.job; agent.instructions = template.instructions; agent.canEdit = template.canEdit
                    } label: { Label(template.job, systemImage: template.symbol) }.buttonStyle(.pill)
                }
            }
        }
    }

    private var tasks: some View {
        VStack(spacing: 14) {
            question(t("What is \(shownName)'s task?", "Was ist \(shownName)s Aufgabe?"),
                     t("Recurring tasks are set up later as routines.", "Wiederkehrende Aufgaben legst du später als Routinen fest."))
            TextEditor(text: $agent.instructions).font(.system(size: 14)).scrollContentBackground(.hidden).focused($focus, equals: .tasks)
                .padding(.horizontal, 9).padding(.vertical, 8).frame(height: 130).field(10)
        }
    }

    private var manner: some View {
        VStack(spacing: 14) {
            question(t("How should \(shownName) behave?", "Wie soll \(shownName) sich verhalten?"),
                     t("A few keywords on tone and way of working are enough.", "Ein paar Stichworte zu Ton und Arbeitsweise genügen."))
            TextField(t("e.g. thorough and sceptical, dry humour", "z. B. gründlich und skeptisch, trockener Humor"), text: $agent.persona).textFieldStyle(.plain).font(.system(size: 15))
                .multilineTextAlignment(.center).focused($focus, equals: .manner).padding(.horizontal, 14).frame(width: 360, height: 40).field(12)
        }
    }

    private var engine: some View {
        VStack(spacing: 16) {
            question(t("Which provider and model should \(shownName) use?", "Welchen Anbieter und welches Modell soll \(shownName) haben?"),
                     t("Both run on your existing subscription. You can change this at any time.", "Beide laufen über dein bestehendes Abo. Du kannst das jederzeit ändern."))
            PillPicker(selection: Binding(get: { agent.provider }, set: { agent.provider = $0; agent.model = ""; agent.effort = ""; agent.account = nil }),
                       options: Provider.allCases.map { ($0, $0.vendor + " · " + $0.title) })
            HStack(spacing: 8) {
                Picker("", selection: $agent.model) {
                    Text(t("Choose a model", "Modell wählen")).tag("")
                    ForEach(agent.models, id: \.self) { Text($0).tag($0) }
                }.labelsHidden().fixedSize()
                    .onChange(of: agent.model) { _, _ in if !agent.efforts.contains(agent.effort) { agent.effort = "" } }
                Picker("", selection: $agent.effort) {
                    Text(Self.autoEffort).tag("")
                    ForEach(agent.efforts, id: \.self) { Text($0).tag($0) }
                }.labelsHidden().fixedSize()
            }
            if agent.provider == .codex, !settings.accounts.isEmpty {
                HStack(spacing: 8) {
                    Text(t("ChatGPT plan", "ChatGPT-Abo")).font(.system(size: 13)).foregroundStyle(Desk.dim)
                    Picker("", selection: Binding(get: { agent.account ?? "" }, set: { agent.account = $0.isEmpty ? nil : $0; agent.model = "" })) {
                        Text(Self.mainPlan).tag("")
                        ForEach(settings.accounts) { Text($0.name).tag($0.id) }
                    }.labelsHidden().fixedSize()
                }
            }
            Text(t("Choose a model. The reasoning depth can stay on automatic.", "Wähle ein Modell. Die Denktiefe kann auf automatisch bleiben.")).font(.system(size: 12.5)).foregroundStyle(Desk.dim)
        }
    }

    private var rights: some View {
        VStack(spacing: 16) {
            question(t("What may \(shownName) do?", "Was darf \(shownName)?"), t("You can change this at any time later.", "Das kannst du später jederzeit umstellen."))
            PillPicker(selection: $agent.access, options: Agent.Access.allCases.map { ($0, $0.title) })
            Text(agent.access.note).font(.system(size: 12.5)).foregroundStyle(agent.access == .full ? Desk.warning : Desk.dim)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Toggle(Self.computerUseLabel(agent.provider),
                   isOn: Binding(get: { agent.computerUse == true }, set: { agent.computerUse = $0 ? true : nil }))
                .toggleStyle(.checkbox).font(.system(size: 13))
        }
    }

    // MARK: Helpers

    /// Names of the other agents in the project, lowercased (for the name suggestion).
    private var taken: Set<String> {
        Set(agents.agents(in: URL(fileURLWithPath: agent.project)).filter { $0.id != agent.id }.map { $0.name.lowercased() })
    }
    private var nameTaken: Bool { agents.nameTaken(agent.name, by: agent) }

    private var shownName: String {
        let trimmed = agent.name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? t("your agent", "dein Agent") : trimmed
    }

    // Texts shared with the editor.
    static var nameTakenText: String {
        t("This name already exists in this project. In the team chat it would be unclear who is meant.",
          "Diesen Namen gibt es in diesem Projekt schon. Im Team-Chat wäre unklar, wer gemeint ist.")
    }
    static var jobPlaceholder: String { t("e.g. researcher, developer, editor", "z. B. Researcherin, Entwickler, Lektor") }
    static var autoEffort: String { t("Reasoning depth: automatic", "Denktiefe automatisch") }
    static var mainPlan: String { t("Main plan", "Haupt-Abo") }
    static func computerUseLabel(_ provider: Provider) -> String {
        t("May operate the computer (screen, apps and browser)", "Darf den Computer bedienen (Bildschirm, Programme und Browser)")
    }

    private func go(_ delta: Int) {
        guard delta < 0 || canContinue, let next = Step(rawValue: step.rawValue + delta) else { return }
        step = next
        focus = next
    }

    private func finish() {
        agent.name = agent.name.trimmingCharacters(in: .whitespaces)
        save(agent)
        dismiss()
    }

    private func question(_ title: String, _ hint: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.system(size: 19, weight: .semibold)).multilineTextAlignment(.center)
            Text(hint).font(.system(size: 13)).foregroundStyle(Desk.dim).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
    }
}
