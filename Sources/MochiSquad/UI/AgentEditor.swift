import SwiftUI

/// Edit an existing agent: look, name, job, tasks, provider, model and rights. New ones are created by AgentWizard.
struct AgentEditor: View {
    @State var agent: Agent
    let save: (Agent) -> Void
    let remove: () -> Void
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: SettingsStore
    @State private var confirmRemove = false

    private var look: MochiLook { MochiLook(key: agent.avatar) }
    @EnvironmentObject private var agents: AgentStore
    /// The name is filled in and still free in the project; otherwise it would be unclear in the team chat who is meant.
    private var valid: Bool { !agent.name.trimmingCharacters(in: .whitespaces).isEmpty && !nameTaken }
    private var nameTaken: Bool { agents.nameTaken(agent.name, by: agent) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(t("Edit agent", "Agent bearbeiten")).font(.system(size: 20, weight: .semibold))
                .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 18)
            // Who it is: the Mochi with its two buttons, name and job beside it.
            HStack(alignment: .top, spacing: 18) {
                VStack(spacing: 10) {
                    MochiAvatar(key: agent.avatar, size: 88)
                    HStack(spacing: 6) {
                        Button { agent.avatar = MochiLook.random().key } label: { Image(systemName: "dice") }.buttonStyle(.pill)
                            .help(t("Shuffle look", "Aussehen würfeln")).accessibilityLabel(t("Shuffle look", "Aussehen würfeln"))
                        lookMenu
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    labelled("Name") { textField(t("e.g. Mira", "z. B. Mira"), $agent.name) }
                    if nameTaken {
                        Text(AgentWizard.nameTakenText).font(.system(size: 12)).foregroundStyle(Desk.warning).fixedSize(horizontal: false, vertical: true)
                    }
                    labelled("Job") { textField(agent.isCoordinator ? agent.jobTitle : AgentWizard.jobPlaceholder, $agent.job).disabled(agent.isCoordinator) }
                }
            }.padding(.horizontal, 24)
            divider
            VStack(alignment: .leading, spacing: 14) {
                row(t("Tasks", "Aufgaben"), top: true) {
                    TextEditor(text: $agent.instructions).font(.system(size: 13.5)).scrollContentBackground(.hidden)
                        .padding(.horizontal, 8).padding(.vertical, 8).frame(height: 88).field(10)
                        .overlay(alignment: .topLeading) {
                            if agent.instructions.isEmpty {
                                Text(agent.isCoordinator ? t("Optional: what should the coordinator pay special attention to?", "Optional: Worauf soll der Koordinator besonders achten?")
                                     : t("What should this agent do, and what should it watch out for?", "Was soll dieser Agent tun, und worauf soll er achten?"))
                                    .font(.system(size: 13.5)).foregroundStyle(.tertiary).padding(.horizontal, 13).padding(.vertical, 9).allowsHitTesting(false)
                            }
                        }
                }
                row(t("Character", "Charakter")) {
                    textField(t("Optional, e.g. thorough and sceptical, dry humour", "Optional, z. B. gründlich und skeptisch, trockener Humor"), $agent.persona)
                }
            }.padding(.horizontal, 24)
            divider
            VStack(alignment: .leading, spacing: 14) {
                row(t("Provider", "Anbieter")) {
                    PillPicker(selection: Binding(get: { agent.provider }, set: { agent.provider = $0; agent.model = $0.defaultModel(); agent.effort = ""; agent.account = nil }),
                               options: Provider.allCases.map { ($0, $0.vendor + " · " + $0.title) })
                }
                row(t("Model", "Modell")) {
                    HStack(spacing: 8) {
                        PillMenu(title: agent.model.isEmpty ? "–" : agent.modelLabel, options: agent.models.map { ($0, agent.provider.label(for: $0, account: agent.account)) }, current: agent.model) { model in
                            agent.model = model
                            if !agent.efforts.contains(agent.effort) { agent.effort = "" }
                        }
                        PillMenu(title: agent.effort.isEmpty ? AgentWizard.autoEffort : t("Reasoning depth: \(agent.effort)", "Denktiefe: \(agent.effort)"),
                               options: [("", AgentWizard.autoEffort)] + agent.efforts.map { ($0, $0) }, current: agent.effort) { agent.effort = $0 }
                    }
                }
                if agent.provider == .codex, !settings.accounts.isEmpty {
                    row(t("ChatGPT plan", "ChatGPT-Abo")) {
                        PillMenu(title: settings.accounts.first { $0.id == agent.account }?.name ?? AgentWizard.mainPlan,
                               options: [("", AgentWizard.mainPlan)] + settings.accounts.map { ($0.id, $0.name) }, current: agent.account ?? "") { id in
                            agent.account = id.isEmpty ? nil : id
                            agent = agent.withModel()
                        }
                    }
                }
            }.padding(.horizontal, 24)
            divider
            VStack(alignment: .leading, spacing: 14) {
                row(t("Rights", "Rechte"), top: true) {
                    VStack(alignment: .leading, spacing: 8) {
                        PillPicker(selection: $agent.access, options: Agent.Access.allCases.map { ($0, $0.title) })
                        Text(agent.access.note).font(.system(size: 12)).foregroundStyle(agent.access == .full ? Desk.warning : Desk.dim)
                            .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                    }
                }
                row(t("Computer", "Computer")) {
                    HStack(spacing: 10) {
                        Text(AgentWizard.computerUseLabel(agent.provider)).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Toggle("", isOn: Binding(get: { agent.computerUse == true }, set: { agent.computerUse = $0 ? true : nil }))
                            .toggleStyle(.switch).controlSize(.small).labelsHidden()
                            .accessibilityLabel(AgentWizard.computerUseLabel(agent.provider))
                    }
                }
            }.padding(.horizontal, 24)
            Rectangle().fill(Desk.rule).frame(height: 1).padding(.top, 20)
            HStack(spacing: 10) {
                if !agent.isCoordinator {
                    Button { confirmRemove = true } label: { Image(systemName: "trash") }.buttonStyle(.pill).help(t("Remove agent", "Agent entfernen"))
                        .accessibilityLabel(t("Remove agent", "Agent entfernen"))
                        .confirmationDialog(t("Remove \(agent.name)?", "\(agent.name) entfernen?"), isPresented: $confirmRemove) {
                            Button(t("Remove agent", "Agent entfernen"), role: .destructive) { remove(); dismiss() }
                            Button(t("Cancel", "Abbrechen"), role: .cancel) {}
                        } message: {
                            Text(t("Its routines are removed with it. Its chat histories stay under “More chats”.",
                                   "Seine Routinen werden mit entfernt. Seine Verläufe bleiben unter „Weitere Chats“ erhalten."))
                        }
                }
                Spacer()
                Button(t("Cancel", "Abbrechen")) { dismiss() }.buttonStyle(.pill).keyboardShortcut(.cancelAction)
                Button(t("Save", "Speichern")) {
                    agent.name = agent.name.trimmingCharacters(in: .whitespaces)
                    save(agent); dismiss()
                }.buttonStyle(.primaryPill).keyboardShortcut(.defaultAction).disabled(!valid).opacity(valid ? 1 : 0.5)
            }.padding(.horizontal, 24).padding(.vertical, 16)
        }
        .frame(width: 560)
    }

    private var divider: some View { Rectangle().fill(Desk.rule).frame(height: 1).padding(.horizontal, 24).padding(.vertical, 18) }

    /// The parts of the Mochi's look, behind one small button.
    private var lookMenu: some View {
        Menu {
            part(t("Body", "Körper"), Self.builds, look.build.rawValue, set { $0.build = .init(rawValue: $1)! })
            part(t("Head", "Kopf"), Self.tops, look.top.rawValue, set { $0.top = .init(rawValue: $1)! })
            part(t("Eyes", "Augen"), Self.eyes, look.eyes.rawValue, set { $0.eyes = .init(rawValue: $1)! })
            part("Extra", Self.extras, look.extra.rawValue, set { $0.extra = .init(rawValue: $1)! })
            Menu(t("Colour", "Farbe")) {
                ForEach(MochiLook.palette, id: \.hex) { color in
                    Button { var next = look; next.hex = color.hex; agent.avatar = next.key } label: {
                        if look.hex == color.hex { Label(color.name, systemImage: "checkmark") } else { Text(color.name) }
                    }
                }
            }
        } label: {
            Image(systemName: "paintbrush").font(.system(size: 13, weight: .medium)).foregroundStyle(Desk.text)
                .padding(.horizontal, 13).frame(height: 30).background(Desk.hover, in: Capsule()).overlay { Capsule().strokeBorder(Desk.edge) }
                .contentShape(Capsule())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help(t("Customise look", "Aussehen anpassen")).accessibilityLabel(t("Customise look", "Aussehen anpassen"))
    }

    private func textField(_ placeholder: String, _ text: Binding<String>) -> some View {
        TextField(placeholder, text: text).textFieldStyle(.plain).font(.system(size: 13.5))
            .padding(.horizontal, 12).frame(height: 36).field(10)
    }

    /// A field with its label above it (used beside the avatar).
    private func labelled<Field: View>(_ title: String, @ViewBuilder field: () -> Field) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 12)).foregroundStyle(Desk.dim)
            field()
        }
    }

    /// A choice from a short list, drawn in the app's own style instead of the system's pop-up button.
    // Names of the look's parts, in the order of their raw values.
    private static var builds: [String] { [t("Classic", "Klassisch"), t("Tall", "Groß"), t("Wide", "Breit"), t("Small", "Klein")] }
    private static var tops: [String] {
        [t("None", "Nichts"), t("Bear ears", "Bärenohren"), t("Cat ears", "Katzenohren"), t("Bunny ears", "Hasenohren"), t("Antenna", "Antenne"),
         t("Little horns", "Hörnchen"), t("Tuft of hair", "Haarbüschel"), t("Sprout", "Sprössling"), t("Headphones", "Kopfhörer"), "Cap",
         t("Beanie", "Mütze"), t("Crown", "Krone"), t("Propeller hat", "Propellermütze"), t("Flower", "Blume"), t("Spikes", "Stacheln")]
    }
    private static var eyes: [String] {
        ["Oval", t("Happy", "Fröhlich"), t("Winking", "Zwinkern"), t("Big", "Groß"), t("Sleepy", "Verschlafen"), t("Shiny", "Glänzend"),
         t("Focused", "Konzentriert"), t("Stars", "Sterne")]
    }
    private static var extras: [String] {
        [t("None", "Nichts"), t("Glasses", "Brille"), t("Rosy cheeks", "Bäckchen"), t("Bow", "Schleife"), t("Scarf", "Schal"),
         t("Freckles", "Sommersprossen"), t("Moustache", "Schnurrbart"), t("Star", "Stern")]
    }

    private func set(_ change: @escaping (inout MochiLook, Int) -> Void) -> (Int) -> Void {
        { index in var next = look; change(&next, index); agent.avatar = next.key }
    }

    private func part(_ title: String, _ names: [String], _ current: Int, _ choose: @escaping (Int) -> Void) -> some View {
        Menu(title) {
            ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                Button { choose(index) } label: { if index == current { Label(name, systemImage: "checkmark") } else { Text(name) } }
            }
        }
    }

    private func row<Field: View>(_ title: String, top: Bool = false, @ViewBuilder field: () -> Field) -> some View {
        HStack(alignment: top ? .top : .center, spacing: 0) {
            Text(title).font(.system(size: 13)).foregroundStyle(Desk.dim).frame(width: 106, alignment: .leading).padding(.top, top ? 8 : 0)
            field().frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
