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
        VStack(spacing: 0) {
            Text(t("Edit agent", "Agent bearbeiten")).font(.system(size: 17, weight: .semibold)).padding(.top, 20)
            HStack(spacing: 16) {
                MochiAvatar(key: agent.avatar, size: 92)
                VStack(alignment: .leading, spacing: 8) {
                    Button { agent.avatar = MochiLook.random().key } label: { Label(t("Shuffle", "Neu würfeln"), systemImage: "dice") }.buttonStyle(.pill)
                    Menu(t("Customise", "Anpassen")) {
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
                    }.menuStyle(.borderlessButton).fixedSize()
                }
                Spacer()
            }.padding(.horizontal, 26).padding(.top, 16).padding(.bottom, 14)
            VStack(spacing: 12) {
                row("Name") {
                    TextField(t("e.g. Mira", "z. B. Mira"), text: $agent.name).textFieldStyle(.plain).font(.system(size: 13.5))
                        .padding(.horizontal, 12).frame(height: 32).field(8)
                }
                if nameTaken {
                    row("") {
                        Text(AgentWizard.nameTakenText)
                            .font(.system(size: 12)).foregroundStyle(Desk.warning).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                row("Job") {
                    TextField(agent.isCoordinator ? agent.jobTitle : AgentWizard.jobPlaceholder, text: $agent.job).textFieldStyle(.plain).font(.system(size: 13.5))
                        .padding(.horizontal, 12).frame(height: 32).field(8).disabled(agent.isCoordinator)
                }
                row(t("Tasks", "Aufgaben"), top: true) {
                    TextEditor(text: $agent.instructions).font(.system(size: 13.5)).scrollContentBackground(.hidden)
                        .padding(.horizontal, 7).padding(.vertical, 6).frame(height: 84).field(8)
                        .overlay(alignment: .topLeading) {
                            if agent.instructions.isEmpty {
                                Text(agent.isCoordinator ? t("Optional: what should the coordinator pay special attention to?", "Optional: Worauf soll der Koordinator besonders achten?")
                                     : t("What should this agent do, and what should it watch out for?", "Was soll dieser Agent tun, und worauf soll er achten?"))
                                    .font(.system(size: 13.5)).foregroundStyle(.tertiary).padding(.horizontal, 12).padding(.vertical, 7).allowsHitTesting(false)
                            }
                        }
                }
                row(t("Character", "Charakter")) {
                    TextField(t("Optional, e.g. thorough and sceptical, dry humour", "Optional, z. B. gründlich und skeptisch, trockener Humor"), text: $agent.persona).textFieldStyle(.plain)
                        .font(.system(size: 13.5)).padding(.horizontal, 12).frame(height: 32).field(8)
                }
                row(t("Provider", "Anbieter")) {
                    PillPicker(selection: Binding(get: { agent.provider }, set: { agent.provider = $0; agent.model = $0.models().first ?? ""; agent.effort = ""; agent.account = nil }),
                               options: Provider.allCases.map { ($0, $0.vendor + " · " + $0.title) })
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                row(t("Model", "Modell")) {
                    HStack(spacing: 8) {
                        Picker("", selection: $agent.model) {
                            ForEach(agent.models, id: \.self) { Text($0).tag($0) }
                        }.labelsHidden().fixedSize()
                            .onChange(of: agent.model) { _, _ in if !agent.efforts.contains(agent.effort) { agent.effort = "" } }
                        Picker("", selection: $agent.effort) {
                            Text(AgentWizard.autoEffort).tag("")
                            ForEach(agent.efforts, id: \.self) { Text($0).tag($0) }
                        }.labelsHidden().fixedSize()
                        Spacer()
                    }
                }
                if agent.provider == .codex, !settings.accounts.isEmpty {
                    row(t("ChatGPT plan", "ChatGPT-Abo")) {
                        Picker("", selection: Binding(get: { agent.account ?? "" }, set: { agent.account = $0.isEmpty ? nil : $0; agent = agent.withModel() })) {
                            Text(AgentWizard.mainPlan).tag("")
                            ForEach(settings.accounts) { Text($0.name).tag($0.id) }
                        }.labelsHidden().fixedSize()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                do {
                    row(t("Rights", "Rechte"), top: true) {
                        VStack(alignment: .leading, spacing: 4) {
                            PillPicker(selection: $agent.access, options: Agent.Access.allCases.map { ($0, $0.title) })
                            Text(agent.access.note).font(.system(size: 12)).foregroundStyle(agent.access == .full ? Desk.warning : Desk.dim)
                                .fixedSize(horizontal: false, vertical: true)
                            Toggle(AgentWizard.computerUseLabel(agent.provider),
                                   isOn: Binding(get: { agent.computerUse == true }, set: { agent.computerUse = $0 ? true : nil }))
                                .toggleStyle(.checkbox).font(.system(size: 13)).padding(.top, 2)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }.padding(.horizontal, 26)
            Rectangle().fill(Desk.rule).frame(height: 1).padding(.top, 18)
            HStack(spacing: 10) {
                if !agent.isCoordinator {
                    Button { confirmRemove = true } label: { Image(systemName: "trash") }.buttonStyle(.pill).help(t("Remove agent", "Agent entfernen"))
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
            }.padding(.horizontal, 22).padding(.vertical, 16)
        }
        .frame(width: 560)
    }

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
            Text(title).font(.system(size: 13)).foregroundStyle(Desk.dim).frame(width: 92, alignment: .leading).padding(.top, top ? 7 : 0)
            field().frame(maxWidth: .infinity)
        }
    }
}
