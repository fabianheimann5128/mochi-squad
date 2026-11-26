import SwiftUI

/// Bestehenden Agenten bearbeiten: Aussehen, Name, Job, Aufgaben, Anbieter, Modell und Rechte. Neue legt AgentWizard an.
struct AgentEditor: View {
    @State var agent: Agent
    let save: (Agent) -> Void
    let remove: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmRemove = false

    private var look: MochiLook { MochiLook(key: agent.avatar) }
    private var valid: Bool { !agent.name.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            Text("Agent bearbeiten").font(.system(size: 17, weight: .semibold)).padding(.top, 20)
            HStack(spacing: 16) {
                MochiAvatar(key: agent.avatar, size: 92)
                VStack(alignment: .leading, spacing: 8) {
                    Button { agent.avatar = MochiLook.random().key } label: { Label("Neu würfeln", systemImage: "dice") }.buttonStyle(.pill)
                    Menu("Anpassen") {
                        part("Körper", ["Klassisch", "Groß", "Breit", "Klein"], look.build.rawValue, set { $0.build = .init(rawValue: $1)! })
                        part("Kopf", ["Nichts", "Bärenohren", "Katzenohren", "Hasenohren", "Antenne", "Hörnchen", "Haarbüschel", "Sprössling",
                                      "Kopfhörer", "Cap", "Mütze", "Krone", "Propellermütze", "Blume", "Stacheln"], look.top.rawValue, set { $0.top = .init(rawValue: $1)! })
                        part("Augen", ["Oval", "Fröhlich", "Zwinkern", "Groß", "Verschlafen", "Glänzend", "Konzentriert", "Sterne"], look.eyes.rawValue, set { $0.eyes = .init(rawValue: $1)! })
                        part("Extra", ["Nichts", "Brille", "Bäckchen", "Schleife", "Schal", "Sommersprossen", "Schnurrbart", "Stern"], look.extra.rawValue, set { $0.extra = .init(rawValue: $1)! })
                        Menu("Farbe") {
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
                    TextField("z. B. Mira", text: $agent.name).textFieldStyle(.plain).font(.system(size: 13.5))
                        .padding(.horizontal, 12).frame(height: 32).field(8)
                }
                row("Job") {
                    TextField("z. B. Researcherin, Entwickler, Lektor", text: $agent.job).textFieldStyle(.plain).font(.system(size: 13.5))
                        .padding(.horizontal, 12).frame(height: 32).field(8).disabled(agent.isCoordinator)
                }
                row("Aufgaben", top: true) {
                    TextEditor(text: $agent.instructions).font(.system(size: 13.5)).scrollContentBackground(.hidden)
                        .padding(.horizontal, 7).padding(.vertical, 6).frame(height: 84).field(8)
                        .overlay(alignment: .topLeading) {
                            if agent.instructions.isEmpty {
                                Text(agent.isCoordinator ? "Optional: Worauf soll der Koordinator besonders achten?" : "Was soll dieser Agent tun, und worauf soll er achten?")
                                    .font(.system(size: 13.5)).foregroundStyle(.tertiary).padding(.horizontal, 12).padding(.vertical, 7).allowsHitTesting(false)
                            }
                        }
                }
                row("Charakter") {
                    TextField("Optional, z. B. gründlich und skeptisch, trockener Humor", text: $agent.persona).textFieldStyle(.plain)
                        .font(.system(size: 13.5)).padding(.horizontal, 12).frame(height: 32).field(8)
                }
                row("Anbieter") {
                    PillPicker(selection: Binding(get: { agent.provider }, set: { agent.provider = $0; agent.model = ""; agent.effort = "" }),
                               options: Provider.allCases.map { ($0, $0.vendor + " · " + $0.title) })
                        .frame(maxWidth: .infinity, alignment: .leading).disabled(agent.isCoordinator)
                }
                row("Modell") {
                    HStack(spacing: 8) {
                        Picker("", selection: $agent.model) {
                            Text("Standard des Clients").tag("")
                            ForEach(agent.provider.models, id: \.self) { Text($0).tag($0) }
                        }.labelsHidden().fixedSize()
                            .onChange(of: agent.model) { _, model in if !agent.provider.efforts(for: model).contains(agent.effort) { agent.effort = "" } }
                        Picker("", selection: $agent.effort) {
                            Text("Denktiefe automatisch").tag("")
                            ForEach(agent.provider.efforts(for: agent.model), id: \.self) { Text($0).tag($0) }
                        }.labelsHidden().fixedSize()
                        Spacer()
                    }
                }
                do {
                    row("Rechte", top: true) {
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle("Darf Dateien im Projekt anlegen und ändern", isOn: $agent.canEdit).toggleStyle(.checkbox).font(.system(size: 13))
                            Text(agent.canEdit ? "Befehle laufen in einer Sandbox, die nur ins Projekt schreiben darf. Lege wichtige Projekte unter Versionsverwaltung."
                                 : "Der Agent liest nur. Für alles andere fragt er dich im Chat.")
                                .font(.system(size: 12)).foregroundStyle(Desk.dim).fixedSize(horizontal: false, vertical: true)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }.padding(.horizontal, 26)
            Rectangle().fill(Desk.rule).frame(height: 1).padding(.top, 18)
            HStack(spacing: 10) {
                if !agent.isCoordinator {
                    Button { confirmRemove = true } label: { Image(systemName: "trash") }.buttonStyle(.pill).help("Agent entfernen")
                        .confirmationDialog(agent.name + " entfernen?", isPresented: $confirmRemove) {
                            Button("Agent entfernen", role: .destructive) { remove(); dismiss() }
                            Button("Abbrechen", role: .cancel) {}
                        } message: { Text("Seine Verläufe bleiben unter „Weitere Chats“ erhalten.") }
                }
                Spacer()
                Button("Abbrechen") { dismiss() }.buttonStyle(.pill).keyboardShortcut(.cancelAction)
                Button("Speichern") {
                    agent.name = agent.name.trimmingCharacters(in: .whitespaces)
                    save(agent); dismiss()
                }.buttonStyle(.primaryPill).keyboardShortcut(.defaultAction).disabled(!valid).opacity(valid ? 1 : 0.5)
            }.padding(.horizontal, 22).padding(.vertical, 16)
        }
        .frame(width: 560)
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
