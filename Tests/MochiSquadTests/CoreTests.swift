import Foundation
import Testing
@testable import MochiSquad

@MainActor @Suite struct BubbleTests {
    @Test func paragraphsSplitTextAndCode() {
        let parts = Bubble.paragraphs("Erster Absatz.\n\n```\nlet x = 1\n```\n\n# Titel\n- Punkt")
        #expect(parts.map(\.code) == [false, true, false])
        #expect(parts[1].text == "let x = 1")
        #expect(parts[2].text == "**Titel**\n•  Punkt")
    }

    @Test func shortIntroStaysWithFollowingParagraph() {
        let parts = Bubble.paragraphs("Ergebnis:\n\nAlles gut.")
        #expect(parts.count == 1)
        #expect(parts[0].text == "Ergebnis:\nAlles gut.")
    }

    @Test func bubblesMarkRelayedMessagesAndDays() {
        let lines = [
            ChatLine(id: 1, role: "user", text: "Team-Chat · Alex: Hallo @Mira\n\n[Verlauf im Team-Chat]\n- x", timestamp: "2026-01-05T09:00:00Z"),
            ChatLine(id: 2, role: "assistant", text: "Eins.\n\nZwei.", timestamp: "2026-01-05T09:00:05Z"),
        ]
        let bubbles = Bubble.make(from: lines)
        #expect(bubbles.count == 3)
        #expect(bubbles[0].relayedFrom == "Alex")
        #expect(bubbles[0].plain == "Hallo @Mira")
        #expect(bubbles[0].day != nil)
        #expect(bubbles[1].day == nil)
        #expect(bubbles.map(\.id) == ["1.0", "2.0", "2.1"])
    }
}

@MainActor @Suite struct MessageTests {
    @Test func relayedPostIsParsed() {
        let post = RelayedMessage.parse("Nachricht von Karo (Autorin): Bitte prüfen.")
        #expect(post?.sender == "Karo")
        #expect(post?.body == "Bitte prüfen.")
        #expect(RelayedMessage.parse("Ganz normale Nachricht: mit Doppelpunkt") == nil)
    }

    @Test func mentionsNeedWordBoundaries() {
        #expect(Mention.contains("Hallo @Mira, schau mal", "Mira"))
        #expect(Mention.contains("@mira!", "Mira"))
        #expect(!Mention.contains("presse@mira.de", "Mira"))
        #expect(!Mention.contains("@Miranda", "Mira"))
    }

    @Test func mergeDropsCopiedHistoryAndKeepsOrder() {
        let old = [ChatLine(id: 1, role: "user", text: "A", timestamp: "2026-01-01T10:00:00Z"),
                   ChatLine(id: 2, role: "assistant", text: "B", timestamp: "2026-01-01T10:00:05Z")]
        let new = [ChatLine(id: 7, role: "assistant", text: "B", timestamp: "2026-01-01T10:00:05Z"),
                   ChatLine(id: 8, role: "user", text: "C", timestamp: "2026-01-02T08:00:00Z")]
        #expect(TranscriptStore.merge(old, new).map(\.text) == ["A", "B", "C"])
    }
}

@MainActor @Suite struct MochiLookTests {
    @Test func keyRoundTrip() {
        let look = MochiLook(build: .tall, top: .crown, eyes: .star, extra: .scarf, hex: "2A92FE")
        #expect(MochiLook(key: look.key) == look)
    }

    @Test func unknownKeysGiveStableLooks() {
        #expect(MochiLook(key: "irgendwas") == MochiLook(key: "irgendwas"))
        #expect(MochiLook(key: "mochi:9.9.9.9:FFFFFF") == MochiLook(key: "mochi:9.9.9.9:FFFFFF"))
        #expect(MochiLook.stableHash("a") != MochiLook.stableHash("b"))
    }
}

@MainActor @Suite struct PromptScannerTests {
    @Test func numberedMenuWithMarker() {
        let prompt = TerminalPromptScanner.parse(["Bash command", "rm build", "", "Do you want to proceed?", "❯ 1. Yes", "2. Yes, and don't ask again", "3. No"])
        #expect(prompt?.options.map(\.key) == ["1", "2", "3"])
        #expect(prompt?.context.last == "Do you want to proceed?")
    }

    @Test func plainTextIsNoMenu() {
        #expect(TerminalPromptScanner.parse(["1. Schritt eins", "2. Schritt zwei", "Fertig."]) == nil)
    }

    @Test func plainMenuWithEnterHint() {
        let prompt = TerminalPromptScanner.parse(["Trust this folder?", "", "❯ Yes, proceed", "No, exit", "", "Enter to confirm"])
        #expect(prompt?.options.count == 2)
        #expect(prompt?.marked == 0)
    }
}

@MainActor @Suite struct ModelTests {
    @Test func routineRhythm() {
        var routine = Routine(agent: Agent(name: "Mira", job: "Researcher", project: "/tmp/p"))
        #expect(routine.rhythm == "täglich")
        routine.days = [5, 1, 2, 3, 4]
        #expect(routine.rhythm == "Mo–Fr")
        routine.days = [6, 7]; routine.hour = 7; routine.minute = 5
        #expect(routine.rhythm == "Sa, So")
        #expect(routine.time == "07:05")
    }

    @Test func journalPathsMustBelongToAClient() {
        #expect(AgentSession.isJournal(NSHomeDirectory() + "/.claude/projects/x/abc.jsonl"))
        #expect(!AgentSession.isJournal(NSHomeDirectory() + "/.ssh/id_ed25519"))
        #expect(!AgentSession.isJournal(NSHomeDirectory() + "/.claude/projects/../../.ssh/key.jsonl"))
    }

    @Test func specEncodesWhatTheLauncherNeeds() throws {
        let agent = Agent(name: "Mira", job: "", project: "/tmp/p", canEdit: true)
        let spec = SessionSpec(agent: agent, project: URL(fileURLWithPath: "/tmp/p"), task: "Hallo", sessionID: UUID(), owner: "Alex", team: [], parentChat: nil)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(spec)) as? [String: Any]
        #expect(json?["provider"] as? String == "claude")
        #expect((json?["agent"] as? [String: Any])?["job"] as? String == "Agent")
        #expect((json?["agent"] as? [String: Any])?["canEdit"] as? Bool == true)
        #expect((json?["sessionId"] as? String)?.count == 36)
    }
}

@MainActor @Suite struct HardeningTests {
    private func scratch() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mochi-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func filesAreWrittenPrivateAndAtomically() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("a.json")
        try JSONFile.save(["a": 1], to: file)
        try JSONFile.save(["a": 2], to: file)
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        #expect(JSONFile.load([String: Int].self, from: file) == ["a": 2])
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["a.json"])
    }

    @Test func smallFileReaderRejectsLinksPipesAndLargeFiles() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let plain = folder.appendingPathComponent("ok.json"), big = folder.appendingPathComponent("big.json")
        let link = folder.appendingPathComponent("link.json"), pipe = folder.appendingPathComponent("pipe.json")
        try Data("{}".utf8).write(to: plain)
        try Data(count: 70_000).write(to: big)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/dev/zero"))
        #expect(mkfifo(pipe.path, 0o600) == 0)
        #expect(AppPaths.readSmallFile(plain) != nil)
        #expect(AppPaths.readSmallFile(big) == nil)
        #expect(AppPaths.readSmallFile(link) == nil)
        #expect(AppPaths.readSmallFile(pipe) == nil)
    }

    @Test func journalCheckResolvesLinks() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(!AgentSession.isJournal(folder.appendingPathComponent("fake.jsonl").path))
        #expect(!AgentSession.isJournal(NSHomeDirectory() + "/.claude/settings.jsonl"))
    }

    @Test func appendedBubblesMatchAFullRebuild() {
        let lines = [
            ChatLine(id: 1, role: "user", text: "Hallo", timestamp: "2026-01-05T09:00:00Z"),
            ChatLine(id: 2, role: "assistant", text: "Eins.\n\nZwei.", timestamp: "2026-01-05T09:00:05Z"),
            ChatLine(id: 3, role: "assistant", text: "Drei.", timestamp: "2026-01-05T09:00:09Z"),
            ChatLine(id: 4, role: "user", text: "Danke", timestamp: "2026-01-06T08:00:00Z"),
        ]
        let full = Bubble.make(from: lines)
        let stepwise = Bubble.make(from: Array(lines[..<2])) + Bubble.make(from: Array(lines[2...]), after: lines[1])
        #expect(full == stepwise)
    }

    @Test func specCarriesNoPaths() throws {
        let agent = Agent(name: "Mochi", job: "", project: "/tmp/p", isCoordinator: true)
        let spec = SessionSpec(agent: agent, project: URL(fileURLWithPath: "/tmp/p"), task: "Hallo", sessionID: UUID(), owner: "Alex", team: [], parentChat: nil)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(spec)) as? [String: Any] ?? [:]
        #expect(json["postEnabled"] as? Bool == true)
        for key in ["post", "outbox", "mcpConfig", "contextFile"] { #expect(json[key] == nil) }
    }

    @Test func dockEntryIsAValidPropertyList() throws {
        let entry = Dock.entry(for: URL(fileURLWithPath: "/Applications/Tom & Jerry <2>.app"))
        let plist = try PropertyListSerialization.propertyList(from: Data(entry.utf8), format: nil) as? [String: Any]
        let file = (plist?["tile-data"] as? [String: Any])?["file-data"] as? [String: Any]
        #expect(file?["_CFURLString"] as? String == "/Applications/Tom & Jerry <2>.app")
        #expect(file?["_CFURLStringType"] as? Int == 0)
    }

    @MainActor @Test func projectMustNotExposeHome() {
        let home = URL(fileURLWithPath: "/Users/alex")
        for bad in ["/", "/Users", "/Users/alex", "/Users/alex/Library", "/Users/alex/Library/Caches/x"] {
            #expect(!SettingsStore.projectAllowed(URL(fileURLWithPath: bad), home: home), "\(bad)")
        }
        for good in ["/Users/alex/Mochi Squad", "/Users/alexander", "/Volumes/Daten/Projekt"] {
            #expect(SettingsStore.projectAllowed(URL(fileURLWithPath: good), home: home), "\(good)")
        }
    }

    @Test func inputPromptIgnoresEmptyCells() {
        #expect(TerminalPromptScanner.isInputPrompt("› "))
        #expect(TerminalPromptScanner.isInputPrompt("›\u{0}"))
        #expect(TerminalPromptScanner.isInputPrompt("\u{0}❯ "))
        #expect(!TerminalPromptScanner.isInputPrompt("› x"))
        #expect(!TerminalPromptScanner.isInputPrompt(""))
    }

    @Test func coordinatorTaskReadsAsRelayedMessage() {
        let parsed = RelayedMessage.parse(RelayedMessage.postPrefix + "Mochi (Koordinator): Prüf bitte den Checkout: Handy zuerst.")
        #expect(parsed?.sender == "Mochi")
        #expect(parsed?.body == "Prüf bitte den Checkout: Handy zuerst.")
    }

    @MainActor @Test func projectsCanBeAddedAndRemovedWithTheirAgents() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let settings = SettingsStore(file: folder.appendingPathComponent("settings.json"))
        let agents = AgentStore(file: folder.appendingPathComponent("agents.json"))
        // Die Projektliste zeigt nur Ordner, die es gibt.
        let first = folder.appendingPathComponent("eins").resolvingSymlinksInPath(), second = folder.appendingPathComponent("zwei").resolvingSymlinksInPath()
        for project in [first, second] { try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true) }
        #expect(settings.addProject(first) && settings.addProject(second) && settings.addProject(first))
        #expect(settings.projects.map(\.path) == [first.path, second.path])
        #expect(!settings.addProject(FileManager.default.homeDirectoryForCurrentUser))
        for project in [first, second] { agents.ensureCoordinator(in: project, name: "Mochi") }
        agents.ensureCoordinator(in: first, name: "Mochi")
        agents.save(Agent(name: "Mira", job: "Researcherin", project: second.path))
        #expect(agents.agents(in: first).count == 1 && agents.agents(in: second).count == 2)
        agents.removeProject(second)
        settings.removeProject(second)
        #expect(agents.agents(in: second).isEmpty && agents.coordinator(in: first) != nil)
        #expect(settings.projects.map(\.path) == [first.path])
    }

    @Test func accountsGetSafeIdentifiersAndApplyOnlyToCodex() throws {
        let id = Account.makeID(from: "Arbeit & Büro / 2")
        #expect(id.range(of: "^[a-z0-9][a-z0-9-]{0,39}$", options: .regularExpression) != nil)
        #expect(id.hasPrefix("arbeit-b-ro-2-"))
        #expect(Account.makeID(from: "…").hasPrefix("abo-"))
        var agent = Agent(name: "Otto", job: "", project: "/tmp/p")
        agent.account = id
        func account(_ agent: Agent) throws -> String? {
            let spec = SessionSpec(agent: agent, project: URL(fileURLWithPath: "/tmp/p"), task: "x", sessionID: UUID(), owner: "Alex", team: [], parentChat: nil)
            return (try JSONSerialization.jsonObject(with: JSONEncoder().encode(spec)) as? [String: Any])?["account"] as? String
        }
        #expect(try account(agent) == "")
        agent.provider = .codex
        #expect(try account(agent) == id)
    }

    @Test func attachmentsAreCopiedIntoTheProjectWithFreeNames() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = root.appendingPathComponent("projekt"), source = root.appendingPathComponent("bild.png")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("a".utf8).write(to: source)
        #expect(try Attachments.stage([source], in: project) == [".mochi-squad/anhaenge/bild.png"])
        #expect(try Attachments.stage([source], in: project) == [".mochi-squad/anhaenge/bild-2.png"])
        #expect(FileManager.default.fileExists(atPath: project.appendingPathComponent(".mochi-squad/anhaenge/bild-2.png").path))
        #expect(throws: Attachments.Failure.self) { try Attachments.stage([root.appendingPathComponent("fehlt.txt")], in: project) }
        #expect(Attachments.message("Schau mal", files: []) == "Schau mal")
        #expect(Attachments.message("", files: ["a/b.png"]).hasSuffix("[Anhänge im Projektordner]\n- a/b.png"))
    }

    @Test func sentAttachmentsAreShownSeparatelyFromTheText() {
        let message = Attachments.message("Siehst du das?", files: [".mochi-squad/anhaenge/Bildschirmfoto 1.png", ".mochi-squad/anhaenge/notiz.txt"])
        let parts = Attachments.split(message)
        #expect(parts.text == "Siehst du das?")
        #expect(parts.files == [".mochi-squad/anhaenge/Bildschirmfoto 1.png", ".mochi-squad/anhaenge/notiz.txt"])
        #expect(Attachments.split("Nur Text\n- kein Anhang").files.isEmpty)
        let bubble = Bubble.make(from: [ChatLine(id: 1, role: "user", text: message, timestamp: "")])[0]
        #expect(bubble.plain == "Siehst du das?" && bubble.attachments.count == 2)
        #expect(Attachments.isImage(URL(fileURLWithPath: "/x/Foto.PNG")) && !Attachments.isImage(URL(fileURLWithPath: "/x/notiz.txt")))
    }

    @Test func speechLevelStaysBetweenZeroAndOne() {
        #expect(SpeechInput.scaled(rms: 0) == 0)
        #expect(SpeechInput.scaled(rms: 0.03) > 0.3)
        #expect(SpeechInput.scaled(rms: 5) == 1)
        #expect(SpeechInput.join("", "Hallo") == "Hallo")
        #expect(SpeechInput.join("Hallo", "wie gehts") == "Hallo wie gehts")
        #expect(SpeechInput.join("Hallo", "") == "Hallo")
    }

    @Test func imagePreviewsKeepTheirProportions() {
        #expect(AttachmentPreview.fitted(CGSize(width: 3200, height: 1200)) == CGSize(width: 320, height: 120))
        #expect(AttachmentPreview.fitted(CGSize(width: 600, height: 1200)) == CGSize(width: 120, height: 240))
        #expect(AttachmentPreview.fitted(CGSize(width: 100, height: 80)) == CGSize(width: 100, height: 80))
    }

    @Test func everyAgentHasAnExplicitModel() {
        var agent = Agent(name: "Emil", job: "", project: "/tmp/p")
        #expect(agent.withModel().model == "opus")
        agent.model = "sonnet"
        #expect(agent.withModel().model == "sonnet")
        agent.provider = .codex
        #expect(Provider.codex.models.contains(agent.withModel().model))
    }

    @Test func journalsOfExtraAccountsCount() {
        let path = AppPaths.support.appendingPathComponent("accounts/codex/arbeit-1a2b/sessions/2026/rollout-x.jsonl").path
        #expect(AgentSession.isJournal(path))
        #expect(!AgentSession.isJournal(AppPaths.support.appendingPathComponent("agents.jsonl").path))
    }
}
