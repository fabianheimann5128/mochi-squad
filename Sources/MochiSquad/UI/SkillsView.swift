import AppKit
import SwiftUI

/// The skill library: what agents know how to do. Add a skill with one click from what is already on the Mac,
/// or drop a folder or .zip here. A new skill is for every agent until you narrow it down.
struct SkillsView: View {
    @EnvironmentObject private var store: SkillStore
    @EnvironmentObject private var agents: AgentStore
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var found = [FoundSkill]()
    @State private var notice: String?
    @State private var dropping = false
    @State private var showFound = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Skills").font(.system(size: 22, weight: .semibold))
                Spacer()
                Button { choose() } label: { Label(t("Import …", "Importieren …"), systemImage: "square.and.arrow.down") }.buttonStyle(.pill)
                Button(t("Done", "Fertig")) { dismiss() }.buttonStyle(.primaryPill).keyboardShortcut(.cancelAction)
            }
            Text(t("A skill teaches your agents one kind of work, for example how you want reviews written or how a tool is used. It works for Claude and Codex agents alike. Drop a skill folder or .zip here, or take one that is already on your Mac.",
                   "Ein Skill bringt deinen Agenten eine Art von Arbeit bei, zum Beispiel wie du Reviews haben willst oder wie ein Werkzeug benutzt wird. Er funktioniert für Claude- und Codex-Agenten gleich. Zieh einen Skill-Ordner oder eine .zip hierher, oder nimm einen, der schon auf deinem Mac liegt."))
                .font(.system(size: 12.5)).foregroundStyle(Desk.dim).fixedSize(horizontal: false, vertical: true)
            if let notice { Label(notice, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12.5)).foregroundStyle(Desk.warning).fixedSize(horizontal: false, vertical: true) }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if store.skills.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "wand.and.stars").font(.system(size: 26, weight: .light)).foregroundStyle(Desk.dim)
                            Text(t("No skills yet", "Noch keine Skills")).font(.system(size: 15, weight: .semibold))
                            Text(found.isEmpty ? t("Drop a skill here to add it.", "Zieh einen Skill hierher, um ihn hinzuzufügen.")
                                               : t("Take one from the list below, or drop a skill here.", "Nimm einen aus der Liste unten oder zieh einen Skill hierher."))
                                .font(.system(size: 12.5)).foregroundStyle(Desk.dim)
                        }.frame(maxWidth: .infinity).padding(.vertical, 26)
                    }
                    ForEach(store.skills) { skill in row(skill) }
                    if !found.isEmpty { foundSection }
                }
            }.frame(height: 400)
            Text(t("A skill is instructions and sometimes scripts that your agents follow. Add only skills from sources you trust.",
                   "Ein Skill besteht aus Anweisungen und manchmal Skripten, denen deine Agenten folgen. Füge nur Skills aus Quellen hinzu, denen du vertraust."))
                .font(.system(size: 12)).foregroundStyle(Desk.faint).fixedSize(horizontal: false, vertical: true)
        }
        .padding(22).frame(width: 560)
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Desk.accent, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .background(Desk.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous)).padding(8).allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            urls.filter(\.isFileURL).forEach(add)
            return !urls.isEmpty
        } isTargeted: { dropping = $0 }
        .onAppear { found = store.found() }
    }

    private func row(_ skill: Skill) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "wand.and.stars").font(.system(size: 13)).foregroundStyle(Desk.accent)
                .frame(width: 34, height: 34).background(Desk.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(skill.name).font(.system(size: 13.5, weight: .semibold))
                if !skill.description.isEmpty {
                    Text(skill.description).font(.system(size: 12)).foregroundStyle(Desk.dim).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                audience(skill).padding(.top, 2)
            }
            Spacer(minLength: 6)
            Button { store.remove(skill); found = store.found() } label: { Image(systemName: "trash") }.buttonStyle(.pill)
                .help(t("Remove skill", "Skill entfernen")).accessibilityLabel(t("Remove \(skill.name)", "\(skill.name) entfernen"))
        }.padding(12).field(12)
    }

    /// Who gets the skill: everyone, or the agents ticked in the menu.
    private func audience(_ skill: Skill) -> some View {
        let everyone = agents.agents
        let chosen = skill.agents.map { ids in everyone.filter { ids.contains($0.id) } }
        let label = chosen.map { $0.isEmpty ? t("No agent", "Kein Agent") : $0.map(\.name).joined(separator: ", ") } ?? t("All agents", "Alle Agenten")
        return Menu {
            Button { store.assign(skill, to: nil) } label: {
                if skill.agents == nil { Label(t("All agents", "Alle Agenten"), systemImage: "checkmark") } else { Text(t("All agents", "Alle Agenten")) }
            }
            Divider()
            ForEach(everyone) { agent in
                let on = skill.agents?.contains(agent.id) ?? false
                Button {
                    // From "all agents", the first tick narrows the skill down to that one agent.
                    var ids = skill.agents ?? []
                    if on { ids.removeAll { $0 == agent.id } } else { ids.append(agent.id) }
                    store.assign(skill, to: ids)
                } label: {
                    let title = agent.name + (settings.projects.count > 1 ? " · " + URL(fileURLWithPath: agent.project).lastPathComponent : "")
                    if on { Label(title, systemImage: "checkmark") } else { Text(title) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "person.2").font(.system(size: 10))
                Text(label).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }.foregroundStyle(Desk.dim).padding(.horizontal, 8).frame(height: 22).background(Desk.selected, in: Capsule()).contentShape(Capsule())
        }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel(t("Agents that get \(skill.name): \(label)", "Agenten mit \(skill.name): \(label)"))
    }

    private var foundSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button { withAnimation(.easeInOut(duration: 0.2)) { showFound.toggle() } } label: {
                    HStack(spacing: 6) {
                        Text(t("Already on this Mac (\(found.count))", "Schon auf diesem Mac (\(found.count))")).font(.system(size: 12.5, weight: .medium))
                        Image(systemName: showFound || store.skills.isEmpty ? "chevron.down" : "chevron.right").font(.system(size: 9.5, weight: .semibold))
                    }.foregroundStyle(Desk.dim).contentShape(Rectangle())
                }.buttonStyle(.plain)
                Spacer()
                if showFound || store.skills.isEmpty {
                    Button(t("Add all", "Alle hinzufügen")) { found.forEach { add($0.folder) } }.buttonStyle(.pill)
                }
            }.padding(.top, 10)
            if showFound || store.skills.isEmpty {
                ForEach(found) { skill in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            (Text(skill.name).font(.system(size: 13, weight: .medium)) + Text("  " + skill.source).font(.system(size: 11.5)).foregroundColor(Desk.faint))
                            if !skill.description.isEmpty { Text(skill.description).font(.system(size: 12)).foregroundStyle(Desk.dim).lineLimit(1) }
                        }
                        Spacer(minLength: 6)
                        Button(t("Add", "Hinzufügen")) { add(skill.folder) }.buttonStyle(.pill)
                    }.padding(.horizontal, 12).padding(.vertical, 8).background(Desk.card.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
    }

    private func add(_ source: URL) {
        do { try store.add(from: source); notice = nil } catch { notice = error.localizedDescription }
        found = store.found()
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.prompt = t("Import", "Importieren")
        panel.message = t("Choose skill folders, .zip archives or SKILL.md files.", "Wähle Skill-Ordner, .zip-Archive oder SKILL.md-Dateien.")
        if panel.runModal() == .OK { panel.urls.forEach(add) }
    }
}
