import SwiftUI

/// Neuen Agenten anlegen, Schritt für Schritt: je Seite eine Frage, mit Eingabetaste geht es weiter.
struct AgentWizard: View {
    @State var agent: Agent
    let save: (Agent) -> Void
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: SettingsStore
    @State private var step = Step.name
    @FocusState private var focus: Step?

    private enum Step: Int, CaseIterable { case name, job, tasks, manner, engine, rights }
    private static let names = ["Mira", "Otto", "Juna", "Finn", "Lia", "Nico", "Ida", "Theo", "Emil", "Nora"]

    /// Weiter geht es erst, wenn die Frage der Seite beantwortet ist.
    private var canContinue: Bool {
        func filled(_ text: String) -> Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        switch step {
        case .name: return filled(agent.name)
        case .job: return filled(agent.job)
        case .tasks: return filled(agent.instructions)
        case .manner: return filled(agent.persona)
        case .engine: return !agent.model.isEmpty
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
                Button("Abbrechen") { dismiss() }.buttonStyle(.pill).keyboardShortcut(.cancelAction)
                Spacer()
                if step != .name { Button("Zurück") { go(-1) }.buttonStyle(.pill) }
                Button(step == .rights ? "Mochi anlegen" : "Weiter") { step == .rights ? finish() : go(1) }
                    .buttonStyle(.primaryPill).keyboardShortcut(.defaultAction).disabled(!canContinue).opacity(canContinue ? 1 : 0.5)
            }.padding(.horizontal, 22).padding(.vertical, 16)
        }
        .frame(width: 520)
        .onAppear {
            if agent.name.isEmpty { agent.name = Self.names.randomElement() ?? "" }
            focus = .name
        }
    }

    // MARK: Schritte

    private var name: some View {
        VStack(spacing: 14) {
            question("Wie soll dein Mochi heißen?", "Mit diesem Namen sprichst du ihn im Team-Chat an.")
            TextField("Name", text: $agent.name).textFieldStyle(.plain).font(.system(size: 15)).multilineTextAlignment(.center)
                .focused($focus, equals: .name).padding(.horizontal, 14).frame(width: 240, height: 40).field(12)
            Button { agent.avatar = MochiLook.random().key } label: { Label("Aussehen würfeln", systemImage: "dice") }.buttonStyle(.pill)
        }
    }

    private var job: some View {
        VStack(spacing: 14) {
            question("Wie ist \(shownName)s Jobbezeichnung?", "Tipp eine eigene ein oder nimm einen Vorschlag.")
            TextField("z. B. Researcherin, Entwickler, Lektor", text: $agent.job).textFieldStyle(.plain).font(.system(size: 15))
                .multilineTextAlignment(.center).focused($focus, equals: .job).padding(.horizontal, 14).frame(width: 320, height: 40).field(12)
            HStack(spacing: 6) {
                ForEach(AgentTemplate.all.filter { !$0.job.isEmpty }) { template in
                    Button {
                        // Ein Vorschlag bringt passende Aufgaben und Rechte mit; beides lässt sich in den nächsten Schritten ändern.
                        agent.job = template.job; agent.instructions = template.instructions; agent.canEdit = template.canEdit
                    } label: { Label(template.job, systemImage: template.symbol) }.buttonStyle(.pill)
                }
            }
        }
    }

    private var tasks: some View {
        VStack(spacing: 14) {
            question("Was ist \(shownName)s Aufgabe?", "Wiederkehrende Aufgaben legst du später als Routinen fest.")
            TextEditor(text: $agent.instructions).font(.system(size: 14)).scrollContentBackground(.hidden).focused($focus, equals: .tasks)
                .padding(.horizontal, 9).padding(.vertical, 8).frame(height: 130).field(10)
        }
    }

    private var manner: some View {
        VStack(spacing: 14) {
            question("Wie soll \(shownName) sich verhalten?", "Ein paar Stichworte zu Ton und Arbeitsweise genügen.")
            TextField("z. B. gründlich und skeptisch, trockener Humor", text: $agent.persona).textFieldStyle(.plain).font(.system(size: 15))
                .multilineTextAlignment(.center).focused($focus, equals: .manner).padding(.horizontal, 14).frame(width: 360, height: 40).field(12)
        }
    }

    private var engine: some View {
        VStack(spacing: 16) {
            question("Welchen Anbieter und welches Modell soll \(shownName) haben?", "Beide laufen über dein bestehendes Abo. Du kannst das jederzeit ändern.")
            PillPicker(selection: Binding(get: { agent.provider }, set: { agent.provider = $0; agent.model = ""; agent.effort = ""; agent.account = nil }),
                       options: Provider.allCases.map { ($0, $0.vendor + " · " + $0.title) })
            HStack(spacing: 8) {
                Picker("", selection: $agent.model) {
                    Text("Modell wählen").tag("")
                    ForEach(agent.provider.models, id: \.self) { Text($0).tag($0) }
                }.labelsHidden().fixedSize()
                    .onChange(of: agent.model) { _, model in if !agent.provider.efforts(for: model).contains(agent.effort) { agent.effort = "" } }
                Picker("", selection: $agent.effort) {
                    Text("Denktiefe automatisch").tag("")
                    ForEach(agent.provider.efforts(for: agent.model), id: \.self) { Text($0).tag($0) }
                }.labelsHidden().fixedSize()
            }
            if agent.provider == .codex, !settings.accounts.isEmpty {
                HStack(spacing: 8) {
                    Text("ChatGPT-Abo").font(.system(size: 13)).foregroundStyle(Desk.dim)
                    Picker("", selection: Binding(get: { agent.account ?? "" }, set: { agent.account = $0.isEmpty ? nil : $0 })) {
                        Text("Standard-Abo").tag("")
                        ForEach(settings.accounts) { Text($0.name).tag($0.id) }
                    }.labelsHidden().fixedSize()
                }
            }
            Text("Wähle ein Modell. Die Denktiefe kann auf automatisch bleiben.").font(.system(size: 12.5)).foregroundStyle(Desk.dim)
        }
    }

    private var rights: some View {
        VStack(spacing: 16) {
            question("Was darf \(shownName)?", "Das kannst du später jederzeit umstellen.")
            PillPicker(selection: $agent.access, options: Agent.Access.allCases.map { ($0, $0.title) })
            Text(agent.access.note).font(.system(size: 12.5)).foregroundStyle(agent.access == .full ? Desk.warning : Desk.dim)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Hilfen

    private var shownName: String {
        let trimmed = agent.name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "dein Agent" : trimmed
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
