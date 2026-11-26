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
}
