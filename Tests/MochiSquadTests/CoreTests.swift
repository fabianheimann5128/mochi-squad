import Foundation
import Testing
@testable import MochiSquad

@MainActor @Suite struct BubbleTests {
    @Test func paragraphsSplitTextAndCode() {
        let parts = Bubble.paragraphs("First paragraph.\n\n```\nlet x = 1\n```\n\n# Title\n- Item")
        #expect(parts.map(\.code) == [false, true, false])
        #expect(parts[1].text == "let x = 1")
        #expect(parts[2].text == "# Title\n- Item")
    }

    /// Lists are drawn item by item with the marker set apart, so wrapped lines align under the text.
    @Test func listsBecomeRowsWithMarkers() {
        let rows = TextRow.rows("Found three things:\n- the `README.md` is **old**\n* tests pass\n\n1. first\n2) second\n\n## Next\nline one\nline two")
        #expect(rows.map(\.marker) == [nil, "•", "•", "1.", "2.", nil, nil])
        #expect(String(rows[1].text.characters) == "the README.md is old")
        #expect(String(rows[5].text.characters) == "Next")
        #expect(String(rows[6].text.characters) == "line one\nline two")
        #expect(TextRow.listItem("-not a list") == nil)
        // The items of one list stay in one bubble even when the agent separates them with blank lines.
        let loose = Bubble.paragraphs("Result:\n\n- one\n\n- two\n\nDone.")
        #expect(loose.map(\.text) == ["Result:\n- one\n- two", "Done."])
        let bubble = Bubble.make(from: [ChatLine(id: 1, role: "assistant", text: "- one\n- two", timestamp: "")])
        #expect(bubble.count == 1 && bubble[0].rows.count == 2)
    }

    @Test func shortIntroStaysWithFollowingParagraph() {
        let parts = Bubble.paragraphs("Result:\n\nAll good.")
        #expect(parts.count == 1)
        #expect(parts[0].text == "Result:\nAll good.")
    }

    @Test func bubblesMarkRelayedMessagesAndDays() {
        let lines = [
            ChatLine(id: 1, role: "user", text: RelayedMessage.teamPrefix + "Alex: Hello @Mira" + RelayedMessage.teamContext + "\n- x" + RelayedMessage.teamHint + "Answer briefly.",
                     timestamp: "2026-01-05T09:00:00Z"),
            ChatLine(id: 2, role: "assistant", text: "One.\n\nTwo.", timestamp: "2026-01-05T09:00:05Z"),
        ]
        let bubbles = Bubble.make(from: lines)
        #expect(bubbles.count == 3)
        #expect(bubbles[0].relayedFrom == "Alex")
        #expect(bubbles[0].plain == "Hello @Mira")
        #expect(bubbles[0].day != nil)
        #expect(bubbles[1].day == nil)
        #expect(bubbles.map(\.id) == ["1.0", "2.0", "2.1"])
    }
}

@MainActor @Suite struct MessageTests {
    @Test func relayedPostIsParsed() {
        let post = RelayedMessage.parse("Message from Karo (writer): Please check.")
        #expect(post?.sender == "Karo")
        #expect(post?.body == "Please check.")
        #expect(RelayedMessage.parse("A perfectly normal message: with a colon") == nil)
    }

    /// Chats written before the switch to English keep their look: the German forms are still recognised.
    @Test func messagesOfEarlierVersionsStillRead() {
        #expect(RelayedMessage.parse("Nachricht von Karo (Autorin): Bitte prüfen.")?.sender == "Karo")
        let team = RelayedMessage.parseTeam("Team-Chat · Alex: Hallo @Mira\n\n[Verlauf im Team-Chat]\n- x\n[Hinweis] Antworte kurz.")
        #expect(team?.sender == "Alex" && team?.body == "Hallo @Mira")
        let old = "Schau mal\n\n[Anhänge im Projektordner]\n- .mochi-squad/anhaenge/bild.png"
        #expect(Attachments.split(old).files == [".mochi-squad/anhaenge/bild.png"])
    }

    @Test func everyoneIsAddressedInBothLanguages() {
        for text in ["@all are you there?", "@alle seid ihr da?", "Hey @team", "@everyone"] { #expect(Mention.addressesEveryone(text), "\(text)") }
        #expect(!Mention.addressesEveryone("we all agree") && !Mention.addressesEveryone("mail@all.example"))
    }

    @Test func mentionsNeedWordBoundaries() {
        #expect(Mention.contains("Hello @Mira, have a look", "Mira"))
        #expect(Mention.contains("@mira!", "Mira"))
        #expect(!Mention.contains("press@mira.de", "Mira"))
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
        #expect(MochiLook(key: "anything") == MochiLook(key: "anything"))
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
        #expect(TerminalPromptScanner.parse(["1. Step one", "2. Step two", "Done."]) == nil)
    }

    /// A one-time screen that only waits for Return becomes a card with one answer.
    @Test func noticesThatWaitForReturnAreRecognised() {
        let prompt = TerminalPromptScanner.parse(["────────", "Claude in Chrome", "", "Claude can use Chrome through its extension.", "", "Enter to continue · Esc to close", "", ""])
        #expect(prompt?.options.map(\.key) == [TerminalPromptScanner.continueKey])
        #expect(prompt?.context == ["Claude in Chrome", "Claude can use Chrome through its extension."])
        #expect(prompt.map(TerminalPromptScanner.isChromeIntroduction) == true)
        let other = TerminalPromptScanner.parse(["Terms changed", "Please read them.", "", "Enter to continue"])
        #expect(other != nil && other.map(TerminalPromptScanner.isChromeIntroduction) == false)
        // Text that merely mentions the phrase further up is no notice.
        #expect(TerminalPromptScanner.parse(["Press Enter to continue later", "", "❯ "]) == nil)
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
        #expect(routine.rhythm == "daily")
        routine.days = [5, 1, 2, 3, 4]
        #expect(routine.rhythm == "Mon–Fri")
        routine.days = [6, 7]; routine.hour = 7; routine.minute = 5
        #expect(routine.rhythm == "Sat, Sun")
        #expect(routine.time == "07:05")
    }

    @Test func journalPathsMustBelongToAClient() {
        #expect(AgentSession.isJournal(NSHomeDirectory() + "/.claude/projects/x/abc.jsonl"))
        #expect(!AgentSession.isJournal(NSHomeDirectory() + "/.ssh/id_ed25519"))
        #expect(!AgentSession.isJournal(NSHomeDirectory() + "/.claude/projects/../../.ssh/key.jsonl"))
    }

    @Test func specEncodesWhatTheLauncherNeeds() throws {
        let agent = Agent(name: "Mira", job: "", project: "/tmp/p", canEdit: true)
        let spec = SessionSpec(agent: agent, project: URL(fileURLWithPath: "/tmp/p"), task: "Hello", sessionID: UUID(), owner: "Alex", team: [], parentChat: nil)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(spec)) as? [String: Any]
        #expect(json?["provider"] as? String == "claude")
        #expect(json?["language"] as? String == "en")
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
            ChatLine(id: 1, role: "user", text: "Hello", timestamp: "2026-01-05T09:00:00Z"),
            ChatLine(id: 2, role: "assistant", text: "One.\n\nTwo.", timestamp: "2026-01-05T09:00:05Z"),
            ChatLine(id: 3, role: "assistant", text: "Three.", timestamp: "2026-01-05T09:00:09Z"),
            ChatLine(id: 4, role: "user", text: "Thanks", timestamp: "2026-01-06T08:00:00Z"),
        ]
        let full = Bubble.make(from: lines)
        let stepwise = Bubble.make(from: Array(lines[..<2])) + Bubble.make(from: Array(lines[2...]), after: lines[1])
        #expect(full == stepwise)
    }

    @Test func specCarriesNoPaths() throws {
        let agent = Agent(name: "Mochi", job: "", project: "/tmp/p", isCoordinator: true)
        let spec = SessionSpec(agent: agent, project: URL(fileURLWithPath: "/tmp/p"), task: "Hello", sessionID: UUID(), owner: "Alex", team: [], parentChat: nil)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(spec)) as? [String: Any] ?? [:]
        #expect(json["postEnabled"] as? Bool == true)
        for key in ["post", "outbox", "mcpConfig", "contextFile", "toolUrl"] { #expect(json[key] == nil) }
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
        for good in ["/Users/alex/Mochi Squad", "/Users/alexander", "/Volumes/Data/Project"] {
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
        let parsed = RelayedMessage.parse(RelayedMessage.postPrefix + "Mochi (coordinator): Please check the checkout: phone first.")
        #expect(parsed?.sender == "Mochi")
        #expect(parsed?.body == "Please check the checkout: phone first.")
    }

    @MainActor @Test func projectsCanBeAddedAndRemovedWithTheirAgents() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let settings = SettingsStore(file: folder.appendingPathComponent("settings.json"))
        let agents = AgentStore(file: folder.appendingPathComponent("agents.json"))
        // The project list shows only folders that exist.
        let first = folder.appendingPathComponent("one").resolvingSymlinksInPath(), second = folder.appendingPathComponent("two").resolvingSymlinksInPath()
        for project in [first, second] { try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true) }
        #expect(settings.addProject(first) && settings.addProject(second) && settings.addProject(first))
        #expect(settings.projects.map(\.path) == [first.path, second.path])
        #expect(!settings.addProject(FileManager.default.homeDirectoryForCurrentUser))
        for project in [first, second] { agents.ensureCoordinator(in: project, name: "Mochi") }
        agents.ensureCoordinator(in: first, name: "Mochi")
        agents.save(Agent(name: "Mira", job: "researcher", project: second.path))
        #expect(agents.agents(in: first).count == 1 && agents.agents(in: second).count == 2)
        agents.removeProject(second)
        settings.removeProject(second)
        #expect(agents.agents(in: second).isEmpty && agents.coordinator(in: first) != nil)
        #expect(settings.projects.map(\.path) == [first.path])
    }

    @Test func accountsGetSafeIdentifiersAndApplyOnlyToCodex() throws {
        let id = Account.makeID(from: "Work & Büro / 2")
        #expect(id.range(of: "^[a-z0-9][a-z0-9-]{0,39}$", options: .regularExpression) != nil)
        #expect(id.hasPrefix("work-b-ro-2-"))
        #expect(Account.makeID(from: "…").hasPrefix("plan-"))
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
        let project = root.appendingPathComponent("project"), source = root.appendingPathComponent("image.png")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("a".utf8).write(to: source)
        #expect(try Attachments.stage([source], in: project) == [".mochi-squad/attachments/image.png"])
        #expect(try Attachments.stage([source], in: project) == [".mochi-squad/attachments/image-2.png"])
        #expect(FileManager.default.fileExists(atPath: project.appendingPathComponent(".mochi-squad/attachments/image-2.png").path))
        #expect(throws: Attachments.Failure.self) { try Attachments.stage([root.appendingPathComponent("missing.txt")], in: project) }
        #expect(Attachments.message("Look", files: []) == "Look")
        #expect(Attachments.message("", files: ["a/b.png"]).hasSuffix("[Attachments in the project folder]\n- a/b.png"))
    }

    /// A message without files must work in a project the user may only read: nothing is created for it.
    @Test func textNeedsNoWriteAccessToTheProject() throws {
        let project = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: project.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: project.path)
            try? FileManager.default.removeItem(at: project)
        }
        #expect(try Attachments.stage([], in: project).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: project.path).isEmpty)
        #expect(throws: Attachments.Failure.self) { try Attachments.stage([URL(fileURLWithPath: "/etc/hosts")], in: project) }
    }

    /// If one of several files cannot be attached, none of them stays in the shared project.
    @Test func aFailedAttachmentLeavesNothingBehind() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = root.appendingPathComponent("project"), good = root.appendingPathComponent("a.txt")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("a".utf8).write(to: good)
        #expect(throws: Attachments.Failure.self) { try Attachments.stage([good, root.appendingPathComponent("gone.txt")], in: project) }
        let left = (try? FileManager.default.contentsOfDirectory(atPath: project.appendingPathComponent(Attachments.folder).path)) ?? []
        #expect(left.isEmpty)
    }

    @Test func sentAttachmentsAreShownSeparatelyFromTheText() {
        let message = Attachments.message("Do you see this?", files: [".mochi-squad/attachments/Screenshot 1.png", ".mochi-squad/attachments/note.txt"])
        let parts = Attachments.split(message)
        #expect(parts.text == "Do you see this?")
        #expect(parts.files == [".mochi-squad/attachments/Screenshot 1.png", ".mochi-squad/attachments/note.txt"])
        #expect(Attachments.split("Only text\n- no attachment").files.isEmpty)
        let bubble = Bubble.make(from: [ChatLine(id: 1, role: "user", text: message, timestamp: "")])[0]
        #expect(bubble.plain == "Do you see this?" && bubble.attachments.count == 2)
        #expect(Attachments.isImage(URL(fileURLWithPath: "/x/Photo.PNG")) && !Attachments.isImage(URL(fileURLWithPath: "/x/note.txt")))
    }

    @Test func speechLevelStaysBetweenZeroAndOne() {
        #expect(SpeechInput.scaled(rms: 0) == 0)
        #expect(SpeechInput.scaled(rms: 0.03) > 0.3)
        #expect(SpeechInput.scaled(rms: 5) == 1)
        #expect(SpeechInput.join("", "Hello") == "Hello")
        #expect(SpeechInput.join("Hello", "how are you") == "Hello how are you")
        #expect(SpeechInput.join("Hello", "") == "Hello")
        // Growing, revised and shortened partial results are no new start (3.1).
        #expect(!SpeechInput.startedOver(previous: "Hello how", latest: "Hello how are you"))
        #expect(!SpeechInput.startedOver(previous: "I want to write two letters", latest: "I want to write to Lena"))
        #expect(!SpeechInput.startedOver(previous: "hello there", latest: "Hello, there!"))
        #expect(!SpeechInput.startedOver(previous: "", latest: "Hello"))
        #expect(!SpeechInput.startedOver(previous: "Wir treffen uns morgen um zehn Uhr", latest: "Wir treffen"))
        // A new stretch of speech, also when it is as long or longer (3.2).
        #expect(SpeechInput.startedOver(previous: "First I want to say that the team chat works well now", latest: "and then"))
        // A11: without times a corrected first word is a revision; with equal positions (zero too) as well.
        #expect(!SpeechInput.startedOver(previous: "Erste Frage", latest: "zweite Frage"))
        #expect(SpeechInput.startedOver(previous: "Erste Frage", latest: "zweite Frage", previousStart: 0.1, latestStart: 3.0))
        #expect(!SpeechInput.startedOver(previous: "Wie geht", latest: "Wir gehen", previousStart: 0, latestStart: 0))
        #expect(!SpeechInput.startedOver(previous: "Wie geht", latest: "Wir gehen"))
        // With times from the recogniser: a later start is new speech, the same start a revision.
        #expect(SpeechInput.startedOver(previous: "Erste Frage", latest: "Erste Frage und mehr", previousStart: 0.2, latestStart: 4.1))
        #expect(!SpeechInput.startedOver(previous: "Wie geht", latest: "Wir gehen", previousStart: 0.2, latestStart: 0.2))
    }

    @Test func imagePreviewsKeepTheirProportions() {
        #expect(AttachmentPreview.fitted(CGSize(width: 3200, height: 1200)) == CGSize(width: 320, height: 120))
        #expect(AttachmentPreview.fitted(CGSize(width: 600, height: 1200)) == CGSize(width: 120, height: 240))
        #expect(AttachmentPreview.fitted(CGSize(width: 100, height: 80)) == CGSize(width: 100, height: 80))
    }

    @Test func everyAgentHasAnExplicitModel() {
        var agent = Agent(name: "Emil", job: "", project: "/tmp/p")
        #expect(agent.withModel().model == "claude-opus-5-5")
        agent.model = "sonnet"
        #expect(agent.withModel().model == "sonnet")
        agent.provider = .codex
        #expect(Provider.codex.models().isEmpty || Provider.codex.models().contains(agent.withModel().model))
    }

    @Test func journalsOfExtraAccountsCount() {
        let path = AppPaths.support.appendingPathComponent("accounts/codex/work-1a2b/sessions/2026/rollout-x.jsonl").path
        #expect(AgentSession.isJournal(path))
        #expect(!AgentSession.isJournal(AppPaths.support.appendingPathComponent("agents.jsonl").path))
    }

    @Test func permissionAnswersGetShortTitles() {
        #expect(PromptCard.wording("Yes").title == "Allow")
        #expect(PromptCard.wording("No, and tell Claude what to do differently").title == "Deny")
        #expect(PromptCard.wording("Yes, and don't ask again for touch commands").title == "Allow and don't ask again")
        #expect(PromptCard.wording("Something else").title == "Something else")
        #expect(PromptCard.isPermission(["Yes", "Yes, and don't ask again", "No, and tell Claude what to do differently"]))
        #expect(!PromptCard.isPermission(["Plan A", "Plan B"]))
    }

    @Test func changedSettingsAreNoticed() {
        var agent = Agent(name: "Emil", job: "Reviewer", project: "/tmp/p").withModel()
        let before = agent.sessionSignature
        agent.access = .full
        #expect(agent.sessionSignature != before)
        #expect(Agent.Access.read.rank < Agent.Access.edit.rank && Agent.Access.edit.rank < Agent.Access.full.rank)
    }

    @Test func feedbackLinksCarryOnlyVersions() {
        #expect(Feedback.url(.bug).absoluteString == Feedback.repository + "/issues/new?template=bug.md")
        #expect(Feedback.url(.idea).absoluteString.hasSuffix("template=feature.md"))
        let parts = WhatsNew.sections("# What's new\n\n## 0.2.0\n- A\n- B\n\n## 0.1.0\n- C")
        #expect(parts.map(\.title) == ["0.2.0", "0.1.0"] && parts[0].items == ["A", "B"])
        let item = ChangeItem("**Telegram.** Reach your team chat from your phone.")
        #expect(item.title == "Telegram" && item.text == "Reach your team chat from your phone." && item.symbol == "paperplane.fill")
        #expect(ChangeItem("Plain entry").title == nil && ChangeItem("Plain entry").symbol == "sparkles")
    }

    @Test func attachmentPathsFromMessagesCannotLeaveTheAttachmentFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let project = root.appendingPathComponent("project"), fm = FileManager.default
        let folder = project.appendingPathComponent(Attachments.folder)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try Data("x".utf8).write(to: folder.appendingPathComponent("image.png"))
        try Data("x".utf8).write(to: project.appendingPathComponent("run.command"))
        try Data("x".utf8).write(to: root.appendingPathComponent("secret.png"))
        #expect(Attachments.resolve(Attachments.folder + "/image.png", in: project) != nil)
        for bad in ["run.command", "../../Downloads/x.app", Attachments.folder + "/../../run.command", "/etc/passwd"] {
            #expect(Attachments.resolve(bad, in: project) == nil, "\(bad)")
        }
        // A link inside the attachment folder that points outside does not count either.
        try fm.createSymbolicLink(at: folder.appendingPathComponent("link"), withDestinationURL: root)
        #expect(Attachments.resolve(Attachments.folder + "/link/project/run.command", in: project) == nil)
        // Relayed messages from agents are never read as a file list.
        let relayed = RelayedMessage.postPrefix + "Nora (Reviewer): Look" + Attachments.marker + "- run.command"
        #expect(Bubble.make(from: [ChatLine(id: 1, role: "user", text: relayed, timestamp: "")])[0].attachments.isEmpty)
        // The folder itself replaced by a link out of the project: nothing behind it is an attachment,
        // and nothing is copied through it.
        try fm.removeItem(at: folder)
        try fm.createSymbolicLink(at: folder, withDestinationURL: root)
        #expect(Attachments.resolve(Attachments.folder + "/secret.png", in: project) == nil)
        #expect(throws: Attachments.Failure.self) { try Attachments.stage([project.appendingPathComponent("run.command")], in: project) }
        #expect(!fm.fileExists(atPath: root.appendingPathComponent("run.command").path))
        // The same for its parent folder.
        try fm.removeItem(at: project.appendingPathComponent(".mochi-squad"))
        try fm.createSymbolicLink(at: project.appendingPathComponent(".mochi-squad"), withDestinationURL: root)
        #expect(throws: Attachments.Failure.self) { try Attachments.stage([project.appendingPathComponent("run.command")], in: project) }
        #expect(!fm.fileExists(atPath: root.appendingPathComponent("attachments").path))
    }

    @MainActor @Test func accountFoldersAndHiddenProjectsAreRefused() {
        #expect(AppPaths.accountHome("work-1a2b") != nil)
        for bad in ["", "..", "../../..", "A", "a/b"] { #expect(AppPaths.accountHome(bad) == nil, "\(bad)") }
        let home = URL(fileURLWithPath: "/Users/alex")
        for bad in ["/Users/alex/.ssh", "/Users/alex/.claude/projects", "/Users/alex/Applications", "/Users/alex/Applications/Mochi Squad.app"] {
            #expect(!SettingsStore.projectAllowed(URL(fileURLWithPath: bad), home: home), "\(bad)")
        }
    }

    // MARK: Findings of the second review

    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mochi-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// An editor that was open for a while must not write an older state over what the app tracked meanwhile.
    @MainActor @Test func savingAnEditedAgentKeepsWhatTheAppTracked() throws {
        let home = try folder()
        defer { try? FileManager.default.removeItem(at: home) }
        let agents = AgentStore(file: home.appendingPathComponent("agents.json"))
        let opened = Agent(name: "Mira", job: "researcher", project: "/tmp/p")
        agents.save(opened)
        agents.remember(journal: "/x/chat.jsonl", for: opened.id)
        agents.update(opened.id) { $0.lastLine = "done"; $0.lastTask = "task" }
        var edited = opened
        edited.persona = "thorough"
        agents.save(edited)
        let stored = try #require(agents.agent(opened.id))
        #expect(stored.persona == "thorough")
        #expect(stored.journals == ["/x/chat.jsonl"] && stored.lastLine == "done" && stored.lastTask == "task")
    }

    /// A damaged agents file must not cost the user their routines: nothing is pruned, and the agents the
    /// routines describe come back under their old ids.
    @MainActor @Test func routinesSurviveADamagedAgentsFile() throws {
        let home = try folder()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent("agents.json"), routineFile = home.appendingPathComponent("routines.json")
        var owner = Agent(name: "Mira", job: "researcher", project: "/tmp/p", canEdit: true)
        owner.provider = .claude; owner.model = "sonnet"
        let lead = Agent.coordinator(name: "Mochi", project: "/tmp/p")
        var first = Routine(agent: owner), second = Routine(agent: lead)
        first.task = "Read the news"; second.task = "Summarise"
        try JSONFile.save([first, second], to: routineFile)
        try Data("{broken".utf8).write(to: file)

        let agents = AgentStore(file: file)
        let routines = RoutineStore(file: routineFile, runFile: home.appendingPathComponent("runs.jsonl"))
        #expect(agents.loadFailed && agents.agents.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: home.path).contains { $0.hasPrefix("agents.damaged-") })
        #expect(agents.restore(from: routines.routines) == 2)
        #expect(agents.agent(owner.id)?.name == "Mira" && agents.agent(owner.id)?.canEdit == true && agents.agent(owner.id)?.model == "sonnet")
        #expect(agents.coordinator(in: URL(fileURLWithPath: "/tmp/p"))?.id == lead.id)
        // Opening the project creates no second coordinator, and syncing removes nothing.
        agents.ensureCoordinator(in: URL(fileURLWithPath: "/tmp/p"), name: "Mochi")
        #expect(agents.agents.filter(\.isCoordinator).count == 1)
        routines.sync(with: agents.agents)
        routines.sync(with: [])
        #expect(routines.routines.map(\.id) == [first.id, second.id])
        #expect(RoutineStore(file: routineFile, runFile: home.appendingPathComponent("runs.jsonl")).routines.count == 2)
        // Only removing the agent takes its routines along.
        routines.removeRoutines(of: [owner.id])
        #expect(routines.routines.map(\.id) == [second.id])
    }

    /// A routine form that was open while the agent changed saves task and time, never the agent's old rights.
    @MainActor @Test func aStaleRoutineDraftCannotBringBackOldRights() throws {
        let home = try folder()
        defer { try? FileManager.default.removeItem(at: home) }
        let routines = RoutineStore(file: home.appendingPathComponent("routines.json"), runFile: home.appendingPathComponent("runs.jsonl"))
        var agent = Agent(name: "Mira", job: "researcher", project: "/tmp/p", canEdit: true)
        agent.model = "sonnet"
        var draft = Routine(agent: agent)
        draft.task = "Read the news"
        routines.save(draft, agent: agent)
        // The user takes the write access away and switches the model while the form stays open.
        agent.canEdit = false; agent.model = "haiku"; agent.provider = .codex; agent.account = "work-1a2b"
        routines.sync(with: [agent])
        draft.hour = 9
        #expect(draft.agent.canEdit)
        routines.save(draft, agent: agent)
        let stored = try #require(routines.routines.first)
        #expect(stored.hour == 9 && stored.task == "Read the news")
        #expect(!stored.agent.canEdit && stored.agent.model == "haiku" && stored.provider == "codex" && stored.agent.account == "work-1a2b")
        // What the form compares ignores the agent details.
        #expect(draft.plan != Routine(agent: agent).plan && stored.plan == draft.plan)
    }

    /// Who may see a line of the team chat is decided by the agent's id, not by a name that can change hands.
    @MainActor @Test func teamContextFollowsTheAgentNotTheName() throws {
        let home = try folder()
        defer { try? FileManager.default.removeItem(at: home) }
        let log = TeamLog(folder: home)
        let mira = Agent(name: "Mira", job: "researcher", project: "/tmp/p")
        var impostor = Agent(name: "Otto", job: "developer", project: "/tmp/p")
        log.open("/tmp/p")
        log.append(TeamLine(kind: .user, text: "hello team"), project: "/tmp/p")
        log.append(TeamLine(kind: .agent, from: "Mira", agent: mira.id, text: "secret finding"), project: "/tmp/p")
        log.append(TeamLine(kind: .agent, from: "Juna", text: "old line without id"), project: "/tmp/p")
        // Another agent takes over the name: Mira's line does not become its line.
        impostor.name = "Mira"
        let foreign = log.context(project: "/tmp/p", owner: "Alex", voices: [impostor])
        #expect(foreign.contains("hello team") && !foreign.contains("secret finding"))
        // Mira under a new name still sees her own line.
        var renamed = mira
        renamed.name = "Mia"
        #expect(log.context(project: "/tmp/p", owner: "Alex", voices: [renamed]).contains("secret finding"))
        // Lines from before ids were stored fall back to the name.
        #expect(log.context(project: "/tmp/p", owner: "Alex", voices: [Agent(name: "Juna", job: "", project: "/tmp/p")]).contains("old line"))
        // The log reads back from disk, messenger origin included.
        log.append(TeamLine(kind: .user, text: "from the phone", via: "Telegram"), project: "/tmp/p")
        let again = TeamLog(folder: home)
        again.open("/tmp/p")
        #expect(again.lines.count == 4 && again.lines.last?.via == "Telegram" && again.lines[1].agent == mira.id)
    }

    /// A write that fails is reported once and retried; the report does not repeat while the fault lasts.
    @MainActor @Test func failedSavesAreReportedAndRetried() throws {
        let home = try folder()
        defer { try? FileManager.default.removeItem(at: home) }
        var reports = [String](), fail = true, written = 0
        let previous = SaveGuard.report
        SaveGuard.report = { reports.append($0) }
        defer { SaveGuard.report = previous }
        let name = "test data " + UUID().uuidString
        let write: () throws -> Void = { if fail { throw CocoaError(.fileWriteNoPermission) }; written += 1 }
        SaveGuard.save(name, write)
        SaveGuard.save(name, write)
        #expect(reports.count == 1 && reports[0].contains(name))
        #expect(SaveGuard.retry())
        fail = false
        SaveGuard.retry()
        #expect(written == 1)
        // A settings change that cannot be stored is not silent either.
        let settings = SettingsStore(file: home.appendingPathComponent("missing/settings.json"))
        settings.value.ownerName = "Alex"
        #expect(reports.count == 2)
    }

    /// A relayed message never lands in the middle of an answer, and never waits forever either.
    @Test func relayedMessagesWaitForAnIdleAgent() {
        #expect(SessionManager.shouldHold(working: true, waited: 0))
        #expect(SessionManager.shouldHold(working: true, waited: 600))
        #expect(!SessionManager.shouldHold(working: false, waited: 0))
        #expect(!SessionManager.shouldHold(working: true, waited: SessionManager.patience + 1))
        #expect(AgentSession.showsBusy("✻ Brewing…\n⏵⏵ bypass permissions on (shift+tab to cycle) · esc to interrupt"))
        #expect(AgentSession.showsBusy("• Working (12s • Esc to interrupt)"))
        #expect(!AgentSession.showsBusy("❯ \n⏵⏵ bypass permissions on (shift+tab to cycle)"))
    }

    @MainActor @Test func coordinatorFollowsTheInstalledProgramAndTheLanguage() {
        let codex = Agent.coordinator(name: "Mochi", project: "/tmp/p", provider: .codex)
        #expect(codex.provider == .codex && codex.isCoordinator && codex.jobTitle == "Coordinator")
        #expect(Agent.coordinator(name: "Mochi", project: "/tmp/p").model == "claude-opus-5-5")
        // Exact models with their names; the short names stay valid for agents created with them.
        #expect(Provider.claude.models().contains("claude-fable-5-2") && Provider.claude.models().contains("opus"))
        #expect(Provider.claude.label(for: "claude-fable-5-2") == "Fable 5.2" && Provider.claude.label(for: "unknown-x") == "unknown-x")
        #expect(Provider.claude.efforts(for: "claude-haiku-5-5").isEmpty && !Provider.claude.efforts(for: "claude-fable-5-2").isEmpty)
        #expect(Agent(name: "A", job: "", project: "/tmp/p").jobTitle == "Agent")
        #expect(t("yes", "ja") == "yes" && Language.de.title == "Deutsch")
        #expect(AppSettings().language == nil && AppPaths.helperEnvironment([:])["MOCHI_LANG"] == "en")
    }

    @MainActor @Test func messengerSettingsHoldNoSecrets() throws {
        var settings = AppSettings()
        settings.messengers = Messengers(telegram: .init(bot: "my_bot", userID: 42, userName: "Alex"), whatsapp: .init(number: "491234"))
        let json = String(data: try JSONFile.encoder.encode(settings), encoding: .utf8) ?? ""
        #expect(json.contains("my_bot") && !json.lowercased().contains("token"))
        // A token is found inside a pasted BotFather reply; anything shorter is not one.
        let token = "1234567890:" + String(repeating: "A", count: 35)
        #expect(TelegramLink.token(in: "Use this token to access the HTTP API:\n\(token)\nKeep it safe") == token)
        #expect(TelegramLink.token(in: "12345:short") == nil)
        #expect(QRCode.image("https://t.me/my_bot?start=abc") != nil)
    }

    /// A routine's run shows up in the agent's chat once, and a new message never continues from it.
    @MainActor @Test func routineRunsJoinTheChatButAreNoPlaceToContinue() throws {
        let home = try folder(), fm = FileManager.default
        defer { try? fm.removeItem(at: home) }
        let agents = AgentStore(file: home.appendingPathComponent("agents.json"))
        let settings = SettingsStore(file: home.appendingPathComponent("settings.json"))
        let manager = SessionManager(agents: agents, settings: settings,
                                     routines: RoutineStore(file: home.appendingPathComponent("r.json"), runFile: home.appendingPathComponent("runs.jsonl")),
                                     team: TeamLog(folder: home))
        let agent = Agent(name: "Mira", job: "researcher", project: "/tmp/p").withModel()
        agents.save(agent)
        let chat = home.appendingPathComponent(UUID().uuidString + ".jsonl"), run = home.appendingPathComponent(UUID().uuidString + ".jsonl")
        for file in [chat, run] { try Data("{}\n".utf8).write(to: file) }
        agents.remember(journal: chat.path, for: agent.id)
        let later = Date(), earlier = later.addingTimeInterval(-3600)
        agents.update(agent.id) { $0.updated = later; $0.lastLine = "from the chat" }
        agents.attach(routineJournal: run.path, to: agent.id, lastLine: "old run", finished: earlier)
        var stored = try #require(agents.agent(agent.id))
        #expect(stored.journals == [chat.path, run.path] && stored.lastLine == "from the chat" && stored.updated == later)
        #expect(manager.resumableChat(for: stored) == chat.deletingPathExtension().lastPathComponent)
        // Once the run has dropped out of the recent histories, it is not attached again.
        agents.update(agent.id) { $0.journals = [chat.path] }
        agents.attach(routineJournal: run.path, to: agent.id, lastLine: "old run", finished: earlier)
        stored = try #require(agents.agent(agent.id))
        #expect(stored.journals == [chat.path])
        // A newer run does move the preview on.
        let fresh = home.appendingPathComponent(UUID().uuidString + ".jsonl")
        agents.attach(routineJournal: fresh.path, to: agent.id, lastLine: "new run", finished: later.addingTimeInterval(60))
        #expect(agents.agent(agent.id)?.lastLine == "new run")
        #expect(SkillStore.parse("---\r\nname: windows\r\ndescription: line endings\r\n---\r\nBody")?.name == "windows")
    }

    /// B1: what waits for a messenger stays bound to the account and project it was meant for.
    @MainActor @Test func waitingMessagesGoOnlyToTheirAccountAndProject() throws {
        let home = try folder(), fm = FileManager.default
        defer { try? fm.removeItem(at: home) }
        let settings = SettingsStore(file: home.appendingPathComponent("settings.json"))
        let manager = SessionManager(agents: AgentStore(file: home.appendingPathComponent("agents.json")), settings: settings,
                                     routines: RoutineStore(file: home.appendingPathComponent("r.json"), runFile: home.appendingPathComponent("runs.jsonl")),
                                     team: TeamLog(folder: home))
        let hub = MessengerHub(manager: manager, settings: settings, team: TeamLog(folder: home))
        let a = home.appendingPathComponent("a", isDirectory: true), b = home.appendingPathComponent("b", isDirectory: true)
        for project in [a, b] { try fm.createDirectory(at: project, withIntermediateDirectories: true); _ = settings.addProject(project) }
        settings.messengers.project = a.path
        // Not set up: nothing waits.
        hub.announce("lost")
        #expect(hub.pending.isEmpty)
        settings.messengers.telegram = .init(bot: "bot", userID: 1, userName: "Me")
        hub.announce("warning")
        hub.announce("result of a", project: a.path)
        hub.announce("result of b", project: b.path)
        #expect(hub.pending["Telegram"]?.map(\.text) == ["ℹ️ warning", "ℹ️ result of a"])
        // The messenger project changes: the result of the old project no longer goes out.
        settings.messengers.project = b.path
        hub.flush("Telegram")
        #expect(hub.pending["Telegram"]?.map(\.text) == ["ℹ️ warning"])
        // Paired with another account: nothing meant for the first one reaches it.
        settings.messengers.telegram = .init(bot: "bot", userID: 2, userName: "Someone")
        hub.flush("Telegram")
        #expect(hub.pending["Telegram"] == nil)
        hub.announce("again")
        settings.messengers.telegram = nil
        hub.flush("Telegram")
        #expect(hub.pending.isEmpty)
    }

    /// Skills: import from a folder or archive, assignment, and the copy agents read.
    @MainActor @Test func skillsAreImportedAssignedAndPublished() throws {
        let home = try folder(), fm = FileManager.default
        defer { try? fm.removeItem(at: home) }
        let source = home.appendingPathComponent("src/reviews"), mirror = home.appendingPathComponent("shared/skills")
        try fm.createDirectory(at: source.appendingPathComponent("refs"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appendingPathComponent("library"), withIntermediateDirectories: true)
        try Data("---\nname: reviews\ndescription: >\n  How reviews are written,\n  step by step\n---\n# Body".utf8).write(to: source.appendingPathComponent("SKILL.md"))
        try Data("x".utf8).write(to: source.appendingPathComponent("refs/checklist.md"))
        try fm.createSymbolicLink(at: source.appendingPathComponent("secret"), withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        func store() -> SkillStore {
            SkillStore(index: home.appendingPathComponent("skills.json"), library: home.appendingPathComponent("library"), mirror: mirror,
                       hidden: home.appendingPathComponent("hidden.json"))
        }
        let skills = store()
        let skill = try skills.add(from: source)
        #expect(skill.name == "reviews" && skill.description == "How reviews are written, step by step" && skill.agents == nil)
        #expect(skill.id.range(of: "^[a-z0-9][a-z0-9-]{0,63}$", options: .regularExpression) != nil)
        #expect(fm.fileExists(atPath: mirror.appendingPathComponent(skill.id + "/refs/checklist.md").path))
        // A link out of the skill's folder is not taken along.
        #expect(!fm.fileExists(atPath: mirror.appendingPathComponent(skill.id + "/secret").path))
        // Assignment: everyone by default, then only the chosen agent.
        let mira = Agent(name: "Mira", job: "", project: "/tmp/p"), otto = Agent(name: "Otto", job: "", project: "/tmp/p")
        #expect(skills.skills(for: otto).count == 1)
        skills.assign(skill, to: [mira.id])
        #expect(skills.skills(for: mira).count == 1 && skills.skills(for: otto).isEmpty)
        // Importing the same skill again replaces it and keeps the assignment; it survives a restart.
        let again = try skills.add(from: source.appendingPathComponent("SKILL.md"))
        // The path stays the same, so agents that were briefed with it can still read it.
        #expect(skills.skills.count == 1 && again.agents == [mira.id] && again.id == skill.id)
        #expect(fm.fileExists(atPath: mirror.appendingPathComponent(skill.id + "/SKILL.md").path))
        #expect(store().skills == [again])
        // Not a skill, and removal.
        try fm.createDirectory(at: home.appendingPathComponent("empty"), withIntermediateDirectories: true)
        #expect(throws: SkillStore.Failure.self) { try skills.add(from: home.appendingPathComponent("empty")) }
        // A folder that holds exactly one skill one level down is taken as that skill, as archives are packed that way.
        #expect(try skills.add(from: home.appendingPathComponent("src")).name == "reviews")
        #expect(skills.skills.count == 1)
        #expect(SkillStore.parse("no front matter") == nil && SkillStore.parse("---\ndescription: x\n---") == nil)
        #expect(SkillStore.parse("---\nname: \"quoted name\"\ndescription: 'd'\n---")?.name == "quoted name")
        skills.skills.forEach(skills.remove)
        #expect(skills.skills.isEmpty)
        #expect(try fm.contentsOfDirectory(atPath: mirror.path).isEmpty)
        // What the clients already have is linked without a click, and kept current.
        let userHome = home.appendingPathComponent("user")
        func write(_ root: String, _ name: String, _ body: String = "d") throws {
            let folder = userHome.appendingPathComponent(root + "/" + name)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("---\nname: \(name)\ndescription: \(body)\n---".utf8).write(to: folder.appendingPathComponent("SKILL.md"))
        }
        try write(".claude/skills", "videos"); try write(".codex/skills", "videos"); try write(".codex/skills", "deploy")
        // A skill taken over by hand earlier becomes a link and keeps its assignment.
        let earlier = try skills.add(from: userHome.appendingPathComponent(".codex/skills/deploy"))
        skills.assign(earlier, to: [mira.id])
        skills.sync(home: userHome)
        #expect(skills.skills.map(\.name).sorted() == ["deploy", "videos"])
        #expect(skills.skills.first { $0.name == "videos" }?.origin == "Claude Code")
        let deploy = try #require(skills.skills.first { $0.name == "deploy" })
        #expect(deploy.origin == "Codex" && deploy.agents == [mira.id])
        // Nothing changed: nothing is copied again.
        let ids = skills.skills.map(\.id)
        skills.sync(home: userHome)
        #expect(skills.skills.map(\.id) == ids)
        // Changed in the client: copied again under a new id, assignment kept.
        Thread.sleep(forTimeInterval: 1.1)
        try write(".codex/skills", "deploy", "a longer description now")
        skills.sync(home: userHome)
        let updated = try #require(skills.skills.first { $0.name == "deploy" })
        // Same id and path, so a running agent's briefing stays valid; new content, assignment kept.
        #expect(updated.id == deploy.id && updated.description == "a longer description now" && updated.agents == [mira.id])
        #expect(try String(contentsOf: mirror.appendingPathComponent(updated.id + "/SKILL.md"), encoding: .utf8).contains("a longer description"))
        #expect(fm.fileExists(atPath: mirror.appendingPathComponent(updated.id + "/SKILL.md").path))
        // Hidden ones stay out until brought back; deleted ones go.
        skills.hide(updated)
        skills.sync(home: userHome)
        #expect(skills.skills.map(\.name) == ["videos"] && skills.hidden.count == 1)
        skills.showHidden(home: userHome)
        #expect(skills.skills.count == 2 && skills.hidden.isEmpty)
        try fm.removeItem(at: userHome.appendingPathComponent(".claude/skills/videos"))
        skills.sync(home: userHome)
        // The same name in Codex takes over once the Claude Code one is gone.
        #expect(skills.skills.first { $0.name == "videos" }?.origin == "Codex")
    }

    /// Second review: a source that cannot be copied or read for a moment never loses a skill or its assignment,
    /// and the agents' copy always shows what the library holds.
    @MainActor @Test func skillSyncSurvivesBrokenSources() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("mochi-skills2-" + UUID().uuidString)
        defer { try? fm.removeItem(at: home) }
        let user = home.appendingPathComponent("user"), mirror = home.appendingPathComponent("shared")
        let skills = SkillStore(index: home.appendingPathComponent("skills.json"), library: home.appendingPathComponent("library"),
                                mirror: mirror, hidden: home.appendingPathComponent("hidden.json"))
        let mira = Agent(name: "Mira", job: "", project: "/tmp/p")
        @discardableResult func write(_ root: String, _ name: String, _ body: String = "d", extra: String = "") throws -> URL {
            let folder = user.appendingPathComponent(root + "/" + name)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("---\nname: \(name)\ndescription: \(body)\n---\n\(extra)".utf8).write(to: folder.appendingPathComponent("SKILL.md"))
            return folder
        }
        func mirrored(_ skill: Skill, _ file: String = "SKILL.md") throws -> String {
            try String(contentsOf: mirror.appendingPathComponent(skill.id + "/" + file), encoding: .utf8)
        }
        // A1: a preferred source too large to copy leaves the working one and its assignment alone.
        try write(".codex/skills", "deploy", "CODEX")
        skills.sync(home: user)
        skills.assign(try #require(skills.skills.first), to: [mira.id])
        let big = try write(".claude/skills", "deploy", "CLAUDE")
        try Data(count: SkillStore.maxBytes + 1).write(to: big.appendingPathComponent("blob.bin"))
        skills.sync(home: user)
        var deploy = try #require(skills.skills.first)
        #expect(skills.skills.count == 1 && deploy.origin == "Codex" && deploy.agents == [mira.id])
        // Once it fits, it takes over and keeps the assignment; A5: the agents' copy shows the new text at once.
        try fm.removeItem(at: big.appendingPathComponent("blob.bin"))
        skills.sync(home: user)
        deploy = try #require(skills.skills.first)
        let shown = try mirrored(deploy)
        #expect(deploy.origin == "Claude Code" && deploy.agents == [mira.id] && shown.contains("CLAUDE"))
        // A2: SKILL.md missing for a moment in a folder that is still there: the skill and assignment stay.
        try fm.moveItem(at: big.appendingPathComponent("SKILL.md"), to: home.appendingPathComponent("aside.md"))
        skills.sync(home: user)
        #expect(skills.skills.first?.id == deploy.id && skills.skills.first?.agents == [mira.id] && skills.skills.count == 1)
        try fm.moveItem(at: home.appendingPathComponent("aside.md"), to: big.appendingPathComponent("SKILL.md"))
        skills.sync(home: user)
        #expect(skills.skills.first?.agents == [mira.id] && skills.skills.first?.origin == "Claude Code")
        // A4: a link inside the skill that now points elsewhere is copied again.
        let notes = try write(".claude/skills", "notes")
        try Data("FIRST".utf8).write(to: notes.appendingPathComponent("one.txt"))
        try Data("SECOND".utf8).write(to: notes.appendingPathComponent("two.txt"))
        try fm.createSymbolicLink(atPath: notes.appendingPathComponent("current.txt").path, withDestinationPath: "one.txt")
        skills.sync(home: user)
        let linked = try #require(skills.skills.first { $0.name == "notes" })
        #expect(try mirrored(linked, "current.txt") == "FIRST")
        try fm.removeItem(at: notes.appendingPathComponent("current.txt"))
        try fm.createSymbolicLink(atPath: notes.appendingPathComponent("current.txt").path, withDestinationPath: "two.txt")
        skills.sync(home: user)
        #expect(try mirrored(linked, "current.txt") == "SECOND")
        // A7: a long SKILL.md with a short head is a valid skill.
        try write(".claude/skills", "long", extra: String(repeating: "A normal paragraph of documentation.\n", count: 9000))
        skills.sync(home: user)
        #expect(skills.skills.contains { $0.name == "long" })
        // A9: deep folders are copied completely, or the skill is refused, never copied in part.
        var deep = try write(".claude/skills", "deep")
        for level in 0..<24 { deep = deep.appendingPathComponent("d\(level)") }
        try fm.createDirectory(at: deep, withIntermediateDirectories: true)
        try Data("bottom".utf8).write(to: deep.appendingPathComponent("doc.md"))
        skills.sync(home: user)
        let deepSkill = try #require(skills.skills.first { $0.name == "deep" })
        #expect(fm.fileExists(atPath: mirror.appendingPathComponent(deepSkill.id + "/" + (0..<24).map { "d\($0)" }.joined(separator: "/") + "/doc.md").path))
        // V-A: what links bring in counts against the size limit, and a link loop is not followed.
        let loop = try write(".claude/skills", "loop")
        try fm.createSymbolicLink(atPath: loop.appendingPathComponent("again").path, withDestinationPath: ".")
        skills.sync(home: user)
        #expect(skills.skills.contains { $0.name == "loop" })
        let copies = try write(".claude/skills", "copies")
        try fm.createDirectory(at: copies.appendingPathComponent("data"), withIntermediateDirectories: true)
        try Data(count: SkillStore.maxBytes / 2 + 1).write(to: copies.appendingPathComponent("data/half.bin"))
        try fm.createSymbolicLink(atPath: copies.appendingPathComponent("mirror").path, withDestinationPath: "data")
        #expect(throws: SkillStore.Failure.self) {
            try SkillStore.copyResolved(copies, to: home.appendingPathComponent("copied"), root: copies.resolvingSymlinksInPath())
        }
        // A8: a hidden skill whose file broke cannot be brought back, so it is not counted.
        skills.hide(try #require(skills.skills.first { $0.name == "notes" }))
        #expect(skills.restorable(home: user) == 1)
        try Data("no head".utf8).write(to: notes.appendingPathComponent("SKILL.md"))
        #expect(skills.restorable(home: user) == 0)
        // A3: the swap leaves one complete folder in place.
        let target = home.appendingPathComponent("swap"), fresh = home.appendingPathComponent("fresh")
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try fm.createDirectory(at: fresh, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: target.appendingPathComponent("f"))
        try Data("new".utf8).write(to: fresh.appendingPathComponent("f"))
        try SkillStore.swap(fresh, into: target)
        #expect(try String(contentsOf: target.appendingPathComponent("f"), encoding: .utf8) == "new" && !fm.fileExists(atPath: fresh.path))
    }

    @MainActor @Test func usageWarnsOncePerThresholdAndWindow() {
        UserDefaults.standard.removeObject(forKey: "usageWarnings.v3")
        defer { UserDefaults.standard.removeObject(forKey: "usageWarnings.v3") }
        let store = LimitStore()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let stamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-60))
        func limit(_ week: Double, resets: Double? = 1_800_100_000) -> PlanLimit {
            PlanLimit(id: "claude", five: nil, week: .init(percent: week, resets: resets), stamp: stamp)
        }
        #expect(store.crossed(limit(50), now: now).isEmpty)
        #expect(store.crossed(limit(81), now: now).map(\.threshold) == [80])
        #expect(store.crossed(limit(85), now: now).isEmpty)
        #expect(store.crossed(limit(96), now: now).map(\.threshold) == [95])
        #expect(store.crossed(limit(99), now: now).isEmpty)
        // A new week warns again.
        #expect(store.crossed(limit(82, resets: 1_800_700_000), now: now).map(\.threshold) == [80])
        // 4.7: a window whose reset has passed warns no more.
        #expect(store.crossed(limit(97, resets: 1_799_000_000), now: now).isEmpty)
        // 4.6: without a reset time a clear drop starts a new period.
        #expect(store.crossed(limit(83, resets: nil), now: now).map(\.threshold) == [80])
        #expect(store.crossed(limit(2, resets: nil), now: now).isEmpty)
        #expect(store.crossed(limit(83, resets: nil), now: now).map(\.threshold) == [80])
        // B7: within the same known window a lower number (a correction, an older report) warns nothing again.
        #expect(store.crossed(limit(83, resets: 1_800_900_000), now: now).map(\.threshold) == [80])
        #expect(store.crossed(limit(2, resets: 1_800_900_000), now: now).isEmpty)
        #expect(store.crossed(limit(84, resets: 1_800_900_000), now: now).isEmpty)
        // B8: without a reset the period starts with the first report, not at a fixed clock boundary …
        let boundary = 1_800_000_000.0 - 1_800_000_000.0.truncatingRemainder(dividingBy: 18_000) + 18_000
        func dated(_ percent: Double, at: Double) -> PlanLimit {
            PlanLimit(id: "codex", five: .init(percent: percent, resets: nil), week: nil,
                      stamp: ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: at)))
        }
        let later = Date(timeIntervalSince1970: boundary + 10)
        #expect(store.crossed(dated(83, at: boundary - 1), now: later).map(\.threshold) == [80])
        #expect(store.crossed(dated(84, at: boundary + 1), now: later).isEmpty)
        // … an older report than one already used is ignored …
        #expect(store.crossed(dated(97, at: boundary - 100), now: later).isEmpty)
        // … and an undated report never counts as new by time alone.
        let undated = PlanLimit(id: "plain", five: .init(percent: 83, resets: nil), week: nil, stamp: nil)
        #expect(store.crossed(undated, now: now).map(\.threshold) == [80])
        #expect(store.crossed(undated, now: now.addingTimeInterval(6 * 3600)).isEmpty)
        // 4.5: absurd numbers are clamped or dropped instead of crashing.
        let wild = PlanLimit.Window(percent: 1e100, resets: 1e100)
        #expect(wild.percent == 100 && wild.resets == nil)
        #expect(limit(1).date != nil && store.name("codex") == "ChatGPT")
    }

    @Test func macStaysAwakeWhileAgentsWork() {
        #expect(SessionManager.awakeLevel(open: 0, working: false, always: false) == .none)
        #expect(SessionManager.awakeLevel(open: 2, working: false, always: false) == .appOnly)
        #expect(SessionManager.awakeLevel(open: 2, working: true, always: false) == .wholeMac)
        #expect(SessionManager.awakeLevel(open: 0, working: false, always: true) == .wholeMac)
    }

    /// B9–B11: runs that finished while the app was closed reach the user once, the right ones.
    @MainActor @Test func missedRoutineRunsAreDeliveredOnce() throws {
        let home = try folder()
        defer { try? FileManager.default.removeItem(at: home) }
        for key in ["routineRunsSeen", "routineRunsDelivered"] { UserDefaults.standard.removeObject(forKey: key) }
        defer { for key in ["routineRunsSeen", "routineRunsDelivered"] { UserDefaults.standard.removeObject(forKey: key) } }
        let runs = home.appendingPathComponent("runs.jsonl")
        let stamp = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-600))
        func line(_ run: String, code: Int = 0, silent: Bool = false, manual: Bool = false) -> String {
            "{\"run\":\"\(run)\",\"routine\":\"r\(run)\",\"start\":\"\(stamp)\",\"end\":\"\(stamp)\",\"code\":\(code),\"output\":\"out \(run)\""
                + (silent ? ",\"silent\":true" : "") + (manual ? ",\"manual\":true" : "") + "}\n"
        }
        // B9: the very first run, with nothing seen before, is delivered and not marked seen at launch.
        try line("a").write(to: runs, atomically: true, encoding: .utf8)
        var got = [String]()
        var store = RoutineStore(file: home.appendingPathComponent("r.json"), runFile: runs)
        store.onFinished = { got.append($0.run ?? "") }
        store.deliverMissed()
        #expect(got == ["a"])
        // B10 / B11: another run of the same second is delivered; quiet and skipped runs do not push it out.
        let more = line("b") + (1...6).map { line("q\($0)", silent: true) }.joined() + line("skip", code: 75) + line("asked", code: 75, manual: true)
        try (line("a") + more).write(to: runs, atomically: true, encoding: .utf8)
        got = []
        store = RoutineStore(file: home.appendingPathComponent("r.json"), runFile: runs)
        store.onFinished = { got.append($0.run ?? "") }
        store.deliverMissed()
        #expect(got == ["b", "asked"])
        // Nothing twice.
        got = []
        store = RoutineStore(file: home.appendingPathComponent("r.json"), runFile: runs)
        store.onFinished = { got.append($0.run ?? "") }
        store.deliverMissed()
        #expect(got.isEmpty)
        // B13: a keyword holds no whitespace of any kind, as messages are split at any.
        #expect(Routine.normalized(keyword: "one\ttwo") == nil && Routine.normalized(keyword: "#Report ") == "#report")
    }

    @Test func routineTriggersReadWell() {
        var routine = Routine(agent: Agent(name: "Mira", job: "", project: "/tmp/p"))
        routine.hour = 8; routine.minute = 5
        #expect(routine.kind == .time && routine.summary.hasSuffix("08:05"))
        let before = routine.plan
        routine.trigger = .hours; routine.every = 6
        #expect(routine.summary == "every 6 hours" && routine.plan != before)
        routine.every = 5
        #expect(routine.hours == 1)
        routine.trigger = .folder; routine.folder = "/Users/x/Downloads"
        #expect(routine.summary == "when “Downloads” changes")
        #expect(Notifier.summary(of: "line one\n\nline two\nline three", limit: 20) == "line two line three")
    }

    @Test func contextWindowSplitsByWhatFillsIt() {
        var usage = Usage()
        #expect(usage.parts.isEmpty)
        // Codex: the answer is inside what is used.
        usage.used = 63_340; usage.base = 43_873; usage.output = 826; usage.answerInside = true
        #expect(usage.parts.map(\.tokens) == [43_873, 18_641, 826])
        usage.limit = 200_000
        #expect(usage.parts.last?.kind == .free && usage.parts.last?.tokens == 136_660)
        // Claude (7.2): the answer comes on top of the context that was read.
        usage.answerInside = false; usage.used = 150; usage.base = 100; usage.output = 50; usage.limit = 1000
        #expect(usage.parts.map(\.tokens) == [100, 50, 50, 800])
        usage.used = 100; usage.output = 10
        #expect(usage.parts.map(\.kind) == [.base, .answer, .free])
        // A base larger than the window's content never goes negative.
        usage.used = 63_340; usage.output = 826; usage.limit = 200_000; usage.base = 90_000
        #expect(usage.parts.first?.tokens == 63_340 && usage.parts.allSatisfy { $0.tokens > 0 })
        // K4: numbers no context window has are dropped instead of overflowing.
        usage.answerInside = false; usage.used = Int.max; usage.output = 1; usage.base = nil; usage.limit = nil
        #expect(usage.parts.isEmpty)
        usage.used = 1_000; usage.output = Int.max; usage.limit = Int.max
        #expect(usage.parts.allSatisfy { $0.tokens > 0 })
    }

    @MainActor @Test func memoryKeepsFactsAsObsidianNotes() throws {
        let root = try folder(), fm = FileManager.default
        defer { try? fm.removeItem(at: root) }
        let bot = MemorySource(agent: UUID().uuidString, reach: "", from: "0123456789abcdef")
        let store = MemoryStore(folder: root.appendingPathComponent("Mochi Memory"))
        #expect(store.notes.isEmpty)
        let day = Date(timeIntervalSince1970: 1_795_000_000)
        let note = try store.remember("Fabian wants answers in German", project: nil, author: "Mira", source: bot, date: day)
        #expect(note.kind == .profile && note.title == "About me" && note.entries.first?.author == "Mira")
        try store.remember("The shop runs on Shopify", project: "/tmp/Shop", author: "Otto", source: bot, date: day)
        let shop = try #require(store.note(for: "/tmp/Shop"))
        #expect(shop.title == "Shop" && shop.entries.map(\.text) == ["The shop runs on Shopify"])
        let text = try String(contentsOf: shop.url, encoding: .utf8)
        #expect(text.hasPrefix("---\nmochi: project\nproject: \"/tmp/Shop\"\n---") && text.contains("[[About me]]"))
        // Duplicates, secrets and empty text are refused.
        #expect(throws: MemoryStore.Failure.self) { try store.remember("the shop runs on shopify", project: "/tmp/Shop", author: "Otto", source: bot) }
        #expect(throws: MemoryStore.Failure.self) { try store.remember("api_key: sk-abcdefghijklmnopqrstuv", project: nil, author: "Otto", source: bot) }
        #expect(throws: MemoryStore.Failure.self) { try store.remember("   ", project: nil, author: "Otto", source: bot) }
        // Lines the user wrote count too; editing keeps the attribution, forgetting removes the line only.
        try (text + "- Ships on Fridays\n").write(to: shop.url, atomically: true, encoding: .utf8)
        store.reload()
        let edited = try #require(store.note(for: "/tmp/Shop"))
        #expect(edited.entries.count == 2 && edited.entries[1].author == nil)
        try store.edit(edited.entries[0], to: "The shop runs on Shopify Plus")
        let after = try #require(store.note(for: "/tmp/Shop"))
        #expect(after.entries[0].text == "The shop runs on Shopify Plus" && after.entries[0].author == "Otto")
        try store.edit(after.entries[1], to: nil)
        #expect(store.note(for: "/tmp/Shop")?.entries.count == 1)
        #expect(MemoryStore.parse(line: "- [[About me]]", index: 0) == nil)
        #expect(!MemoryStore.looksSecret("Prefers short answers and dark mode"))
    }

    @MainActor @Test func keywordAndLinkTriggersFindTheirRoutine() throws {
        let home = try folder()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = RoutineStore(file: home.appendingPathComponent("routines.json"), runFile: home.appendingPathComponent("runs.jsonl"))
        let mira = Agent(name: "Mira", job: "", project: home.path)
        var report = Routine(agent: mira)
        report.task = "Report on the shop"; report.active = true; report.trigger = .keyword; report.keyword = "#Report"
        store.save(report, agent: mira)
        #expect(Routine.normalized(keyword: "Report") == "#report" && Routine.normalized(keyword: "two words") == nil)
        let hit = try #require(store.match(message: "#report  the new orders "))
        #expect(hit.routine.id == report.id && hit.input == "the new orders")
        #expect(store.match(message: "#REPORT")?.input == "")
        #expect(store.match(message: "please #report") == nil && store.match(message: "#reports") == nil)
        // 6.6: a line break after the keyword; 6.4: only the messenger's project.
        #expect(store.match(message: "#report\nonly today")?.input == "only today")
        #expect(store.match(message: "#report", project: home.path) != nil && store.match(message: "#report", project: "/elsewhere") == nil)
        // 6.9: a run that holds the helper's lock counts as busy.
        let locks = home.appendingPathComponent("locks")
        try FileManager.default.createDirectory(at: locks, withIntermediateDirectories: true)
        #expect(!RoutineStore.isRunning(report.id, folder: locks))
        let held = Darwin.open(locks.appendingPathComponent(report.id + ".lock").path, O_CREAT | O_WRONLY, 0o600)
        flock(held, LOCK_EX)
        #expect(RoutineStore.isRunning(report.id, folder: locks))
        Darwin.close(held)
        #expect(!RoutineStore.isRunning(report.id, folder: locks))
        report.active = false
        store.save(report, agent: mira)
        #expect(store.match(message: "#report") == nil)
        // Start link: only the right key of an active link routine counts.
        var linked = Routine(agent: mira)
        linked.task = "Tidy the inbox"; linked.active = true; linked.trigger = .link; linked.key = Routine.newKey()
        let link = try #require(linked.startLink)
        #expect(link.absoluteString.hasPrefix("mochisquad://run?routine=\(linked.id)&key="))
        #expect(linked.key?.count == 24 && Routine.newKey() != linked.key)
        #expect(RoutineStore.same("abc", "abc") && !RoutineStore.same("abc", "abd") && !RoutineStore.same("abc", "abcd"))
        store.save(linked, agent: mira)
        let wrong = URL(string: "mochisquad://run?routine=\(linked.id)&key=wrongwrongwrongwrongwron")!
        #expect(store.open(link: wrong) == nil)
        #expect(store.open(link: URL(string: "https://example.com/run?routine=\(linked.id)&key=\(linked.key!)")!) == nil)
    }

    @Test func tidyUpTaskCarriesTheSummary() {
        let task = SessionManager.compactTask("Goal: ship 0.2.1")
        #expect(task.hasPrefix(SessionManager.compactMark) && task.contains("Goal: ship 0.2.1") && task.contains("wait for my next message"))
    }

    @MainActor @Test func skillLinksKeepAssignmentsAndFollowOnlyInnerLinks() throws {
        let root = try folder(), fm = FileManager.default
        defer { try? fm.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let store = SkillStore(index: root.appendingPathComponent("skills.json"), library: root.appendingPathComponent("library"),
                               mirror: root.appendingPathComponent("mirror"), hidden: root.appendingPathComponent("hidden.json"))
        func write(_ base: String, _ name: String, head: String? = nil) throws {
            let folder = home.appendingPathComponent(base + "/" + name)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data((head ?? "---\nname: \(name)\ndescription: d\n---\n").utf8).write(to: folder.appendingPathComponent("SKILL.md"))
        }
        let mira = UUID()
        // 1.1: a same-name skill from a preferred source keeps the narrowed assignment.
        try write(".codex/skills", "demo")
        store.sync(home: home)
        store.assign(try #require(store.skills.first), to: [mira])
        try write(".claude/skills", "demo")
        store.sync(home: home)
        #expect(store.skills.count == 1 && store.skills[0].origin == "Claude Code" && store.skills[0].agents == [mira])
        // 1.2: a half-saved manifest keeps the skill and its assignment.
        try write(".claude/skills", "demo", head: "---\nname: \n")
        store.sync(home: home)
        #expect(store.skills.first?.agents == [mira])
        try write(".claude/skills", "demo")
        store.sync(home: home)
        #expect(store.skills.count == 1 && store.skills.first?.agents == [mira])
        // 1.3: a linked skill folder and a manifest that links inside its own folder are copied as real files.
        let real = home.appendingPathComponent(".claude/skills/linked")
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        try Data("---\nname: linked\ndescription: d\n---\n".utf8).write(to: real.appendingPathComponent("instructions.md"))
        try fm.createSymbolicLink(atPath: real.appendingPathComponent("SKILL.md").path, withDestinationPath: "instructions.md")
        try fm.createSymbolicLink(atPath: real.appendingPathComponent("outside").path, withDestinationPath: "/etc/hosts")
        try fm.createDirectory(at: home.appendingPathComponent(".agents/skills"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: home.appendingPathComponent(".agents/skills/viaagents").path, withDestinationPath: "../../.claude/skills/linked")
        store.sync(home: home)
        let linked = try #require(store.skills.first { $0.name == "linked" })
        let copy = root.appendingPathComponent("mirror/" + linked.id)
        let attributes = try fm.attributesOfItem(atPath: copy.appendingPathComponent("SKILL.md").path)
        #expect(attributes[.type] as? FileAttributeType == .typeRegular)
        #expect(!fm.fileExists(atPath: copy.appendingPathComponent("outside").path))
        // 1.7: a hidden skill whose folder is gone cannot be brought back.
        store.hide(linked)
        #expect(store.restorable(home: home) == 1)
        try fm.removeItem(at: real)
        #expect(store.restorable(home: home) == 0)
    }

    @Test func reasoningDepthIsCheckedEvenWhenTheModelStays() {
        var agent = Agent(name: "Mira", job: "", project: "/tmp/p")
        agent.model = "claude-haiku-5-5"; agent.effort = "high"
        #expect(agent.withModel().model == "claude-haiku-5-5" && agent.withModel().effort == "")
        agent.model = "claude-opus-5-5"
        #expect(agent.withModel().effort == "high")
    }

    /// A10: back on the regular sign-in after a plan was removed, model and depth are checked against that plan.
    @MainActor @Test func removingAPlanChecksTheAgentsModelAgain() throws {
        let home = try folder()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = AgentStore(file: home.appendingPathComponent("agents.json"))
        var agent = Agent(name: "Cody", job: "", project: "/tmp/p")
        agent.provider = .codex; agent.account = "extra-plan"; agent.effort = "only-on-the-extra-plan"
        store.save(agent)
        store.releaseAccount("extra-plan")
        let after = try #require(store.agent(agent.id))
        #expect(after.account == nil && after.effort == "" && after == after.withModel())
    }

    @MainActor @Test func memoryEditsAndMovesSafely() throws {
        let root = try folder(), fm = FileManager.default
        defer { try? fm.removeItem(at: root) }
        let old = root.appendingPathComponent("old"), new = root.appendingPathComponent("new")
        let bot = MemorySource(agent: UUID().uuidString, reach: "", from: "0123456789abcdef")
        let store = MemoryStore(folder: old)
        try store.remember("first", project: "/tmp/Shop", author: "Otto", source: bot)
        try store.remember("second", project: "/tmp/Shop", author: "Otto", source: bot)
        // 8.3: a line inserted elsewhere meanwhile does not make the edit hit the wrong entry.
        let note = try #require(store.note(for: "/tmp/Shop"))
        let second = try #require(note.entries.last)
        var text = try String(contentsOf: note.url, encoding: .utf8)
        text = text.replacingOccurrences(of: "- first", with: "- inserted\n- first")
        try text.write(to: note.url, atomically: true, encoding: .utf8)
        try store.edit(second, to: "second corrected")
        #expect(store.note(for: "/tmp/Shop")?.entries.map(\.text) == ["inserted", "first", "second corrected"])
        // A text that is gone is reported, not guessed.
        #expect(throws: MemoryStore.Failure.self) { try store.edit(second, to: "again") }
        // 8.8: a path with quotes round-trips.
        try store.remember("odd", project: "/tmp/with \"quote\"", author: "Otto", source: bot)
        #expect(store.note(for: "/tmp/with \"quote\"")?.entries.first?.text == "odd")
        #expect(MemoryStore.unquoted(MemoryStore.quoted("a\\b\"c")) == "a\\b\"c")
        // 8.11 properties are no entries, 8.13 "+" is one.
        let tagged = old.appendingPathComponent("Tagged.md")
        try "---\nmochi: project\nproject: \"/tmp/T\"\ntags:\n  - hidden\n---\n+ plus\n".write(to: tagged, atomically: true, encoding: .utf8)
        store.reload()
        #expect(store.note(for: "/tmp/T")?.entries.map(\.text) == ["plus"])
        // 8.7: a note made outside the app is found before a new one is created.
        let outside = old.appendingPathComponent("About me.md")
        try "---\nmochi: profile\n---\n- outside\n".write(to: outside, atomically: true, encoding: .utf8)
        try store.remember("inside", project: nil, author: "Otto", source: bot)
        #expect(!fm.fileExists(atPath: old.appendingPathComponent("About me 2.md").path) && store.profile?.entries.count == 2)
        // 8.2: a full note refuses instead of crashing.
        try ("---\nmochi: project\nproject: \"/tmp/Big\"\n---\n" + String(repeating: "- x\n", count: 131_058)).write(to: old.appendingPathComponent("Big.md"), atomically: true, encoding: .utf8)
        store.reload()
        #expect(throws: MemoryStore.Failure.self) { try store.remember("one more", project: "/tmp/Big", author: "Otto", source: bot) }
        // 8.1 / 8.15: only Mochi notes move, a note in both places is merged.
        try "# my own note".write(to: old.appendingPathComponent("Personal.md"), atomically: true, encoding: .utf8)
        try fm.createDirectory(at: new, withIntermediateDirectories: true)
        try "---\nmochi: profile\n---\n- already there\n".write(to: new.appendingPathComponent("About me.md"), atomically: true, encoding: .utf8)
        let moved = store.move(to: new)
        #expect(moved == .init(switched: true, stayed: []))
        #expect(fm.fileExists(atPath: old.appendingPathComponent("Personal.md").path))
        #expect(!fm.fileExists(atPath: new.appendingPathComponent("Personal.md").path))
        #expect(Set(store.entries(for: nil).map(\.text)) == ["already there", "outside", "inside"])
        // 8.14: common ways of writing secrets are caught.
        #expect(MemoryStore.looksSecret("My password is fictional") && MemoryStore.looksSecret("-----BEGIN OPENSSH PRIVATE KEY-----"))
    }

    /// Second review of Mochi Memory: moving never loses anything, edits hit exactly their line, origins are kept.
    @MainActor @Test func memoryMovesWithoutLossAndKeepsOrigins() throws {
        let root = try folder(), fm = FileManager.default
        defer { try? fm.removeItem(at: root) }
        let agentID = UUID().uuidString
        let bot = MemorySource(agent: agentID, reach: "fc", from: MemorySource.key(of: "/tmp/Shop"))
        // The same key as scripts/memory.py computes (project_key("/tmp")).
        #expect(MemorySource.key(of: "/tmp") == "11fe14a563f7aed6")
        let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
        let store = MemoryStore(folder: a)
        // Origin: id and rights go into the line and come back; the user's own entries are marked as such.
        try store.remember("Prefers German", project: nil, author: "Mira", source: bot)
        try store.remember("Likes tea", project: nil, author: "Fabian", source: MemorySource(user: true))
        var profile = store.entries(for: nil)
        #expect(profile[0].source == bot && profile[0].unconfirmed && profile[1].byUser && !profile[1].unconfirmed)
        // Confirming keeps the origin and marks it.
        try store.confirm(profile[0])
        profile = store.entries(for: nil)
        #expect(profile[0].source?.confirmed == true && profile[0].source?.agent == agentID && !profile[0].unconfirmed)
        // A marker inside the text does not count; a broken marker means unknown origin.
        #expect(MemoryStore.parse(line: "- x %%mochi:1 user%% · Mira · 2026-11-27 \(bot.marker)", index: 0)?.source == bot)
        let broken = try #require(MemoryStore.parse(line: "- x · Mira · 2026-11-27 %%mochi:1 user agent=1%%", index: 0))
        #expect(broken.broken && broken.unconfirmed && !broken.byUser)
        #expect(try #require(MemoryStore.parse(line: "- x · Mira · 2026-11-27", index: 0)).unconfirmed)
        // M3: a nested property is not the note's own.
        try "---\nmetadata:\n  mochi: profile\n---\n- foreign\n".write(to: a.appendingPathComponent("Foreign.md"), atomically: true, encoding: .utf8)
        store.reload()
        #expect(store.entries(for: nil).count == 2)
        // M12: control characters in a folder name come back exactly.
        let odd = "/tmp/two\nlines\t\u{7}"
        try store.remember("odd path", project: odd, author: "Mira", source: bot)
        #expect(store.note(for: odd)?.entries.map(\.text) == ["odd path"])
        #expect(MemoryStore.unquoted(MemoryStore.quoted(odd)) == odd)
        // M9: two equal lines with different dates: the edit takes the right one or reports a conflict.
        let shop = try store.remember("Ships on Fridays", project: "/tmp/Shop", author: "Otto", source: bot,
                                      date: Date(timeIntervalSince1970: 1_767_225_600))
        var lines = try String(contentsOf: shop.url, encoding: .utf8)
        lines += lines.components(separatedBy: "\n").first { $0.hasPrefix("- Ships") }!.replacingOccurrences(of: "2026-01-01", with: "2026-02-01") + "\n"
        try lines.write(to: shop.url, atomically: true, encoding: .utf8)
        store.reload()
        let february = try #require(store.entries(for: "/tmp/Shop").last)
        #expect(february.date == "2026-02-01")
        try lines.replacingOccurrences(of: "\n- Ships on Fridays · Otto · 2026-01-01", with: "\n- inserted\n- Ships on Fridays · Otto · 2026-01-01")
            .write(to: shop.url, atomically: true, encoding: .utf8)
        try store.edit(february, to: "Ships on Mondays")
        #expect(store.entries(for: "/tmp/Shop").map { "\($0.text)|\($0.date ?? "")" } == ["inserted|", "Ships on Fridays|2026-01-01", "Ships on Mondays|2026-02-01"])
        // M11: a fact that is gone is not looked for among the properties.
        let tag = try #require(store.entries(for: "/tmp/Shop").first)
        let shopText = try String(contentsOf: shop.url, encoding: .utf8)
        try shopText.replacingOccurrences(of: "mochi: project\n", with: "mochi: project\ntags:\n- inserted\n").replacingOccurrences(of: "\n- inserted\n- Ships", with: "\n- Ships")
            .write(to: shop.url, atomically: true, encoding: .utf8)
        #expect(throws: MemoryStore.Failure.self) { try store.edit(tag, to: "changed") }
        #expect(try String(contentsOf: shop.url, encoding: .utf8).contains("tags:\n- inserted\n"))
        // M1: a note with the user's own paragraphs, tags and links is never merged into another: both stay whole.
        try fm.createDirectory(at: b, withIntermediateDirectories: true)
        try "---\nmochi: profile\n---\n- already there\n".write(to: b.appendingPathComponent("About me.md"), atomically: true, encoding: .utf8)
        let rich = "---\nmochi: profile\ntags:\n  - me\n---\n# About me\n\nA paragraph of my own.\n\n- [[Somewhere]]\n- my fact\n"
        try rich.write(to: a.appendingPathComponent("Me too.md"), atomically: true, encoding: .utf8)
        // M8: a target note too full to take more keeps its content; the moved note comes along whole.
        let full = "---\nmochi: project\nproject: \"/tmp/Shop\"\n---\n" + String(repeating: "- x\n", count: 131_060)
        try full.write(to: b.appendingPathComponent("Shop.md"), atomically: true, encoding: .utf8)
        store.reload()
        let before = Set(store.entries(for: nil).map(\.text) + store.entries(for: "/tmp/Shop").map(\.text))
        let moved = store.move(to: b)
        #expect(moved == .init(switched: true, stayed: []) && store.folder == b)
        #expect(try String(contentsOf: b.appendingPathComponent("Me too.md"), encoding: .utf8) == rich)
        #expect(try String(contentsOf: b.appendingPathComponent("Shop.md"), encoding: .utf8) == full)
        let after = Set(store.entries(for: nil).map(\.text) + store.entries(for: "/tmp/Shop").map(\.text))
        #expect(before.isSubset(of: after) && after.contains("already there") && after.contains("my fact"))
        #expect(fm.fileExists(atPath: a.appendingPathComponent("Foreign.md").path))
        // M10: several notes about the user all count, in the app as for agents.
        #expect(store.notes.filter { $0.kind == .profile }.count >= 2)
        // M2: the same folder under a second path moves nothing and deletes nothing.
        let link = root.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: b)
        let count = store.entries(for: nil).count
        #expect(store.move(to: link) == .init(switched: true, stayed: []) && store.entries(for: nil).count == count)
        #expect(fm.fileExists(atPath: b.appendingPathComponent("About me.md").path))
        // Nothing can be written there: the memory stays where it is, nothing is lost.
        let locked = root.appendingPathComponent("locked")
        try fm.createDirectory(at: locked, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }
        let refused = store.move(to: locked)
        #expect(!refused.switched && store.entries(for: nil).count == count)
    }

    @MainActor @Test func tidyingUpMovesOldChatsToMoreChats() throws {
        let home = try folder()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = AgentStore(file: home.appendingPathComponent("agents.json"))
        var agent = Agent(name: "Mira", job: "", project: home.path)
        agent.journals = ["/a.jsonl", "/run.jsonl", "/b.jsonl"]; agent.routineJournals = ["/run.jsonl"]
        store.save(agent)
        store.archiveConversations(of: agent.id)
        #expect(store.agent(agent.id)?.journals == ["/run.jsonl"])
        // D7: the moved conversations stay listed for "More chats", also without a client index entry.
        #expect(store.agent(agent.id)?.archivedJournals == ["/a.jsonl", "/b.jsonl"])
    }
}