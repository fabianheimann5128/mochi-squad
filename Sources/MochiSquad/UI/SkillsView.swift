import AppKit
import SwiftUI

/// The skill library: what agents know how to do. Skills the user already has in Claude Code or Codex are linked
/// by themselves; more come in by dropping a folder or .zip here. A skill is for every agent until narrowed down.
struct SkillsView: View {
    @EnvironmentObject private var store: SkillStore
    @EnvironmentObject private var agents: AgentStore
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var notice: String?
    @State private var dropping = false
    @State private var search = ""
    @State private var group = Group.all

    enum Group: Hashable { case all, claude, codex, own }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if !store.skills.isEmpty { filters }
            if let notice {
                Label(notice, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12.5)).foregroundStyle(Desk.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            list
            footer
        }
        .padding(24).frame(width: 640)
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
        // Opening the library is a good moment to pick up skills that changed in the clients meanwhile.
        .onAppear { store.sync() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Skills").font(.system(size: 22, weight: .semibold))
                if !store.skills.isEmpty {
                    Text("\(store.skills.count)").font(.system(size: 13, weight: .medium).monospacedDigit()).foregroundStyle(Desk.dim)
                        .padding(.horizontal, 8).frame(height: 20).background(Desk.card, in: Capsule())
                }
                Spacer()
                Button { choose() } label: { Label(t("Add skill …", "Skill hinzufügen …"), systemImage: "plus") }.buttonStyle(.pill)
                Button(t("Done", "Fertig")) { dismiss() }.buttonStyle(.primaryPill).keyboardShortcut(.cancelAction)
            }
            Text(t("Your agents use a skill on their own when a task fits it. Skills you have in Claude Code or Codex are linked automatically and stay up to date, for Claude and Codex agents alike.",
                   "Deine Agenten nutzen einen Skill von selbst, wenn eine Aufgabe dazu passt. Skills, die du in Claude Code oder Codex hast, werden automatisch verknüpft und bleiben aktuell, für Claude- und Codex-Agenten gleichermaßen."))
                .font(.system(size: 12.5)).foregroundStyle(Desk.dim).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var filters: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Desk.faint)
                TextField(t("Search skills", "Skills suchen"), text: $search).textFieldStyle(.plain).font(.system(size: 13))
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Desk.faint) }.buttonStyle(.plain)
                        .accessibilityLabel(t("Clear search", "Suche leeren"))
                }
            }.padding(.horizontal, 12).frame(height: 32).field(10)
            // Only the groups that exist are offered.
            if groups.count > 2 {
                PillPicker(selection: $group, options: groups.map { ($0, title($0)) }).fixedSize()
            }
        }
    }

    private var groups: [Group] {
        [.all] + [Group.claude, .codex, .own].filter { candidate in store.skills.contains { kind(of: $0) == candidate } }
    }

    private func title(_ group: Group) -> String {
        switch group {
        case .all: return t("All", "Alle")
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .own: return t("Added by you", "Von dir")
        }
    }

    private func kind(of skill: Skill) -> Group {
        switch skill.origin {
        case "Claude Code": return .claude
        case "Codex": return .codex
        default: return .own
        }
    }

    private var shown: [Skill] {
        let words = search.lowercased().split(separator: " ")
        return store.skills
            .filter { group == .all || kind(of: $0) == group }
            .filter { skill in words.allSatisfy { (skill.name + " " + skill.description).lowercased().contains($0) } }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                if store.skills.isEmpty {
                    empty
                } else if shown.isEmpty {
                    Text(t("No skill matches “\(search)”.", "Kein Skill passt zu „\(search)“."))
                        .font(.system(size: 13)).foregroundStyle(Desk.dim).frame(maxWidth: .infinity).padding(.vertical, 40)
                }
                ForEach(shown) { skill in row(skill) }
            }.padding(.vertical, 2)
        }.frame(height: 420)
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "graduationcap").font(.system(size: 30, weight: .light)).foregroundStyle(Desk.dim)
            Text(t("No skills yet", "Noch keine Skills")).font(.system(size: 16, weight: .semibold))
            Text(t("Skills you install in Claude Code or Codex appear here by themselves. You can also drop a skill folder or .zip into this window.",
                   "Skills, die du in Claude Code oder Codex installierst, erscheinen hier von selbst. Du kannst auch einen Skill-Ordner oder eine .zip in dieses Fenster ziehen."))
                .font(.system(size: 12.5)).foregroundStyle(Desk.dim).multilineTextAlignment(.center).frame(maxWidth: 380)
            Button { choose() } label: { Label(t("Add skill …", "Skill hinzufügen …"), systemImage: "plus") }.buttonStyle(.pill).padding(.top, 4)
        }.frame(maxWidth: .infinity).padding(.vertical, 60)
    }

    private func row(_ skill: Skill) -> some View {
        HStack(alignment: .center, spacing: 12) {
            badge(skill)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(skill.name).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                    Text(skill.origin ?? t("added by you", "von dir")).font(.system(size: 11)).foregroundStyle(Desk.faint).lineLimit(1)
                }
                if !skill.description.isEmpty {
                    Text(skill.description).font(.system(size: 12)).foregroundStyle(Desk.dim).lineLimit(1).help(skill.description)
                }
            }
            Spacer(minLength: 8)
            audience(skill)
            more(skill)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Desk.card.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// The tile tells where a skill comes from at a glance.
    private func badge(_ skill: Skill) -> some View {
        let color: Color
        switch kind(of: skill) {
        case .claude: color = Desk.warning
        case .codex: color = Desk.accent
        default: color = Desk.success
        }
        return Image(systemName: "graduationcap.fill").font(.system(size: 13)).foregroundStyle(color)
            .frame(width: 32, height: 32).background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func more(_ skill: Skill) -> some View {
        Menu {
            if let source = skill.source {
                Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: source)]) } label: {
                    Label(t("Show in Finder", "Im Finder zeigen"), systemImage: "folder")
                }
                Divider()
                Button(role: .destructive) { store.hide(skill) } label: {
                    Label(t("Don't use in Mochi Squad", "In Mochi Squad nicht nutzen"), systemImage: "eye.slash")
                }
            } else {
                Button(role: .destructive) { store.remove(skill) } label: { Label(t("Remove", "Entfernen"), systemImage: "trash") }
            }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).foregroundStyle(Desk.dim)
                .frame(width: 28, height: 28).contentShape(Rectangle())
        }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel(t("More for \(skill.name)", "Mehr zu \(skill.name)"))
    }

    /// Who gets the skill: everyone, or the agents ticked in the menu.
    private func audience(_ skill: Skill) -> some View {
        let everyone = agents.agents
        let chosen = skill.agents.map { ids in everyone.filter { ids.contains($0.id) } }
        let label = chosen.map { $0.isEmpty ? t("No agent", "Kein Agent") : $0.count == 1 ? $0[0].name : t("\($0.count) agents", "\($0.count) Agenten") }
            ?? t("All agents", "Alle Agenten")
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
            HStack(spacing: 5) {
                Image(systemName: "person.2").font(.system(size: 10))
                Text(label).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }.foregroundStyle(Desk.dim).padding(.horizontal, 9).frame(height: 24).background(Desk.selected, in: Capsule())
                .overlay { Capsule().strokeBorder(Desk.edge) }.contentShape(Capsule())
        }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel(t("Agents that get \(skill.name): \(label)", "Agenten mit \(skill.name): \(label)"))
    }

    private var footer: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(t("Skills are instructions and sometimes scripts that your agents follow. Use only skills from sources you trust.",
                   "Skills sind Anweisungen und manchmal Skripte, denen deine Agenten folgen. Nutze nur Skills aus Quellen, denen du vertraust.")
                 + (store.skills.count > 1000
                    ? t(" An agent's briefing names its first 1,000 skills; assign fewer per agent so none is left out.",
                        " Das Briefing eines Agenten nennt seine ersten 1.000 Skills; weise einem Agenten weniger zu, damit keiner fehlt.") : ""))
                .font(.system(size: 11.5)).foregroundStyle(Desk.faint).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            let restorable = store.restorable()
            if restorable > 0 {
                Button(t("Bring back \(restorable) hidden", "\(restorable) ausgeblendete zurückholen")) { store.showHidden() }
                    .buttonStyle(.plain).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Desk.accent).fixedSize()
            }
        }
    }

    private func add(_ source: URL) {
        do { try store.add(from: source); notice = nil } catch { notice = error.localizedDescription }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.prompt = t("Add", "Hinzufügen")
        panel.message = t("Choose skill folders, .zip archives or SKILL.md files.", "Wähle Skill-Ordner, .zip-Archive oder SKILL.md-Dateien.")
        if panel.runModal() == .OK { panel.urls.forEach(add) }
    }
}
