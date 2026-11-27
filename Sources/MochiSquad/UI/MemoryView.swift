import AppKit
import SwiftUI

/// Mochi Memory, dead simple: what your agents remember, who learned it, and the three steps by which it works.
/// The notes are plain Markdown, so the folder opens in Obsidian as it is.
struct MemoryView: View {
    @EnvironmentObject private var memory: MemoryStore
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var agents: AgentStore
    @Environment(\.dismiss) private var dismiss
    /// nil = about you, otherwise a project folder.
    @State private var selected: String?
    @State private var draft = ""
    @State private var editing: Int?
    @State private var editText = ""
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            HowItWorks(team: agents.agents.prefix(3).map(\.avatar))
            HStack(alignment: .top, spacing: 16) {
                topics.frame(width: 210)
                entries.frame(maxWidth: .infinity)
            }.frame(height: 360)
            footer
        }
        .padding(24).frame(width: 820)
        .onAppear { memory.reload() }
        // Facts an agent saves while the window is open appear right away.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { memory.reload() }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Mochi Memory").font(.system(size: 22, weight: .semibold))
            Text(t("\(total) things remembered", "\(total) Dinge gemerkt")).font(.system(size: 13)).foregroundStyle(Desk.dim)
            Spacer()
            if let obsidian = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "md.obsidian") {
                Button { openInObsidian(obsidian) } label: { Label(t("Open in Obsidian", "In Obsidian öffnen"), systemImage: "arrow.up.forward.app") }.buttonStyle(.pill)
            }
            Button(t("Done", "Fertig")) { dismiss() }.buttonStyle(.primaryPill).keyboardShortcut(.cancelAction)
        }
    }

    private var total: Int { memory.notes.reduce(0) { $0 + $1.entries.count } }

    // MARK: Topics: you and your projects

    private var topics: some View {
        VStack(alignment: .leading, spacing: 4) {
            topic(id: nil, title: t("About you", "Über dich"), count: memory.profile?.entries.count ?? 0) {
                Image(systemName: "person.fill").font(.system(size: 12)).foregroundStyle(Desk.text)
            }
            Text(t("Projects", "Projekte")).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Desk.faint).padding(.top, 10).padding(.leading, 10)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(projectPaths, id: \.self) { path in
                        topic(id: path, title: URL(fileURLWithPath: path).lastPathComponent, count: memory.note(for: path)?.entries.count ?? 0) {
                            Image(systemName: "folder.fill").font(.system(size: 11.5)).foregroundStyle(Desk.text)
                        }
                    }
                }
            }
        }
    }

    private var projectPaths: [String] {
        let known = settings.projects.map(\.path)
        return known + memory.notes.compactMap(\.project).filter { !known.contains($0) }
    }

    private func topic<Icon: View>(id: String?, title: String, count: Int, @ViewBuilder icon: () -> Icon) -> some View {
        let chosen = selected == id
        return Button { withAnimation(.easeOut(duration: 0.2)) { selected = id; editing = nil } } label: {
            HStack(spacing: 10) {
                icon().frame(width: 28, height: 28).background((chosen ? Desk.accent : Color.white.opacity(0.08)), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(title).font(.system(size: 13, weight: chosen ? .semibold : .regular)).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(count)").font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(Desk.dim)
            }
            .padding(.horizontal, 8).frame(height: 42)
            .background(chosen ? Desk.selected : .clear, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    // MARK: Entries

    private var note: MemoryNote? { selected.map { memory.note(for: $0) } ?? memory.profile }

    private var entries: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField(selected == nil ? t("Tell your agents something about you …", "Erzähl deinen Agenten etwas über dich …")
                                          : t("Tell your agents something about this project …", "Erzähl deinen Agenten etwas über dieses Projekt …"),
                          text: $draft).textFieldStyle(.plain).font(.system(size: 13)).padding(.horizontal, 12).frame(height: 36).field(10)
                    .onSubmit(add)
                Button(t("Remember", "Merken"), action: add).buttonStyle(.primaryPill).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let notice {
                Label(notice, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(Desk.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    let list = Array((note?.entries ?? []).reversed())
                    if list.isEmpty { empty }
                    ForEach(list) { entry in
                        row(entry).transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
                    }
                }.padding(.bottom, 4)
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles").font(.system(size: 22, weight: .light)).foregroundStyle(Desk.dim)
            Text(t("Nothing remembered yet", "Noch nichts gemerkt")).font(.system(size: 14, weight: .semibold))
            Text(selected == nil
                 ? t("As soon as an agent learns something about you, for example how you like your answers, it shows up here.",
                     "Sobald ein Agent etwas über dich lernt, zum Beispiel wie du Antworten magst, steht es hier.")
                 : t("As soon as an agent learns something about this project, for example a decision, it shows up here.",
                     "Sobald ein Agent etwas über dieses Projekt lernt, zum Beispiel eine Entscheidung, steht es hier."))
                .font(.system(size: 12.5)).foregroundStyle(Desk.dim).multilineTextAlignment(.center).frame(maxWidth: 340)
        }.frame(maxWidth: .infinity).padding(.vertical, 50)
    }

    private func row(_ entry: MemoryEntry) -> some View {
        let agent = agents.agents.first { $0.name == entry.author }
        let fresh = entry.date == Date().formatted(.iso8601.year().month().day())
        return HStack(alignment: .center, spacing: 12) {
            if let agent { MochiAvatar(key: agent.avatar, size: 30, round: true) }
            else {
                Image(systemName: "person.fill").font(.system(size: 12)).foregroundStyle(Desk.dim)
                    .frame(width: 30, height: 30).background(Color.white.opacity(0.08), in: Circle())
            }
            VStack(alignment: .leading, spacing: 3) {
                if editing == entry.id {
                    TextField("", text: $editText).textFieldStyle(.plain).font(.system(size: 13.5)).onSubmit { save(entry) }
                } else {
                    Text(entry.text).font(.system(size: 13.5)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                HStack(spacing: 6) {
                    Text(byline(entry)).font(.system(size: 11.5)).foregroundStyle(Desk.faint)
                    if fresh {
                        Text(t("new", "neu")).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Desk.accent)
                            .padding(.horizontal, 6).frame(height: 16).background(Desk.accent.opacity(0.15), in: Capsule())
                    }
                }
            }
            Spacer(minLength: 6)
            if editing == entry.id {
                Button(t("Save", "Sichern")) { save(entry) }.buttonStyle(.pill)
            } else {
                Menu {
                    Button { editing = entry.id; editText = entry.text } label: { Label(t("Correct", "Korrigieren"), systemImage: "pencil") }
                    Button(role: .destructive) { change(entry, to: nil) } label: { Label(t("Forget", "Vergessen"), systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).foregroundStyle(Desk.dim).frame(width: 26, height: 26).contentShape(Rectangle())
                }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel(t("Correct or forget", "Korrigieren oder vergessen"))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Desk.card.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { if fresh { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Desk.accent.opacity(0.35)) } }
    }

    /// "Learned by Mira · 26 Nov 2026", or "Added by you".
    private func byline(_ entry: MemoryEntry) -> String {
        let day = entry.date.flatMap(Self.day)
        guard let author = entry.author else { return t("Added by you", "Von dir eingetragen") }
        let owner = settings.value.ownerName
        let who = author == owner || author == t("You", "Du") ? t("Added by you", "Von dir eingetragen") : t("Learned by \(author)", "Gelernt von \(author)")
        return [who, day].compactMap { $0 }.joined(separator: " · ")
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder").font(.system(size: 11)).foregroundStyle(Desk.faint)
            Text(memory.folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.system(size: 11.5)).foregroundStyle(Desk.faint).lineLimit(1).truncationMode(.head)
            Button(t("Change folder …", "Ordner ändern …"), action: chooseFolder).buttonStyle(.plain).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Desk.accent)
            Spacer()
            Text(t("Passwords, keys and tokens are never stored.", "Passwörter, Schlüssel und Tokens werden nie gespeichert.")).font(.system(size: 11.5)).foregroundStyle(Desk.faint)
        }
    }

    // MARK: Actions

    private func add() {
        let text = draft.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        do {
            try withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                try memory.remember(text, project: selected, author: settings.value.ownerName.isEmpty ? t("You", "Du") : settings.value.ownerName)
            }
            draft = ""; notice = nil
        } catch { notice = error.localizedDescription }
    }

    private func save(_ entry: MemoryEntry) { change(entry, to: editText); editing = nil }

    private func change(_ entry: MemoryEntry, to text: String?) {
        guard let note else { return }
        do { try withAnimation(.easeOut(duration: 0.25)) { try memory.edit(entry, in: note, to: text) }; notice = nil } catch { notice = error.localizedDescription }
    }

    /// A folder inside an Obsidian vault puts the memory right into it; picking the vault itself uses a subfolder.
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.prompt = t("Use this folder", "Diesen Ordner nutzen")
        panel.message = t("Choose where Mochi Memory keeps its notes, for example your Obsidian vault.",
                          "Wähle, wo Mochi Memory seine Notizen ablegt, zum Beispiel deinen Obsidian-Vault.")
        guard panel.runModal() == .OK, var url = panel.url else { return }
        if FileManager.default.fileExists(atPath: url.appendingPathComponent(".obsidian").path) {
            url = url.appendingPathComponent("Mochi Squad", isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let old = memory.folder
        settings.value.memoryFolder = url.path
        // Notes already written move along, unless the new folder has its own of the same name.
        if let files = try? FileManager.default.contentsOfDirectory(at: old, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "md" && !FileManager.default.fileExists(atPath: url.appendingPathComponent(file.lastPathComponent).path) {
                try? FileManager.default.moveItem(at: file, to: url.appendingPathComponent(file.lastPathComponent))
            }
        }
        memory.use(url)
    }

    private func openInObsidian(_ app: URL) {
        try? FileManager.default.createDirectory(at: memory.folder, withIntermediateDirectories: true)
        let target = (note ?? memory.profile)?.url ?? memory.folder
        var components = URLComponents(string: "obsidian://open")!
        components.queryItems = [URLQueryItem(name: "path", value: target.path)]
        // Obsidian opens a note only inside a vault it knows; otherwise the folder opens in Finder.
        if let url = components.url, isInsideVault(target) { NSWorkspace.shared.open(url) } else { NSWorkspace.shared.open(memory.folder) }
    }

    private func isInsideVault(_ url: URL) -> Bool {
        var folder = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        while folder.path != "/" {
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent(".obsidian").path) { return true }
            folder = folder.deletingLastPathComponent()
        }
        return false
    }

    static func day(_ iso: String) -> String? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        guard let date = formatter.date(from: iso) else { return nil }
        return date.formatted(.dateTime.day().month(.abbreviated).year().locale(L10n.language.locale))
    }
}

/// The idea in three steps, with a light that travels from one to the next: an agent learns something, it is
/// written into memory, and every agent knows it from its next start.
private struct HowItWorks: View {
    let team: [String]
    @Environment(\.accessibilityReduceMotion) private var still

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: still)) { clock in
            let phase = still ? 0.5 : (clock.date.timeIntervalSinceReferenceDate / 4.5).truncatingRemainder(dividingBy: 1)
            HStack(spacing: 0) {
                step(active: Self.near(phase, 0.0), title: t("An agent learns something", "Ein Agent lernt etwas"),
                     detail: t("while it works with you", "während er mit dir arbeitet")) {
                    MochiAvatar(key: team.first ?? "mochi", size: 34, round: true)
                }
                arrow(progress: Self.segment(phase, from: 0.08, to: 0.42))
                step(active: Self.near(phase, 0.5), title: t("It is saved here", "Es wird hier gespeichert"),
                     detail: t("as a note you can correct", "als Notiz, die du korrigieren kannst")) {
                    Image(systemName: "brain").font(.system(size: 16, weight: .medium)).foregroundStyle(.white)
                        .frame(width: 34, height: 34).background(Desk.accent, in: Circle())
                }
                arrow(progress: Self.segment(phase, from: 0.58, to: 0.92))
                step(active: Self.near(phase, 1.0), title: t("Every agent knows it", "Jeder Agent weiß es"),
                     detail: t("from its next start", "ab seinem nächsten Start")) {
                    GroupAvatar(keys: team.isEmpty ? ["mochi"] : team, size: 34, round: true)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Desk.card.opacity(0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    /// Close to `point` on the loop (with wrap-around), for the gentle highlight of the step the light is at.
    static func near(_ phase: Double, _ point: Double) -> Bool {
        let distance = min(abs(phase - point), 1 - abs(phase - point))
        return distance < 0.09
    }

    /// 0…1 while the light crosses an arrow, nil when it is elsewhere.
    static func segment(_ phase: Double, from: Double, to: Double) -> Double? {
        phase >= from && phase <= to ? (phase - from) / (to - from) : nil
    }

    private func step<Icon: View>(active: Bool, title: String, detail: String, @ViewBuilder icon: () -> Icon) -> some View {
        HStack(spacing: 10) {
            icon().scaleEffect(active ? 1.08 : 1).shadow(color: Desk.accent.opacity(active ? 0.6 : 0), radius: 8)
                .animation(.easeOut(duration: 0.3), value: active)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                Text(detail).font(.system(size: 11.5)).foregroundStyle(Desk.dim).lineLimit(1)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func arrow(progress: Double?) -> some View {
        GeometryReader { area in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.1)).frame(height: 2)
                if let progress {
                    Circle().fill(Desk.accent).frame(width: 7, height: 7).shadow(color: Desk.accent, radius: 5)
                        .offset(x: (area.size.width - 7) * progress)
                }
            }.frame(maxHeight: .infinity)
        }.frame(width: 44).padding(.horizontal, 6)
    }
}
