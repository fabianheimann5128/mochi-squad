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
        // Growing and revised partial results are no new start.
        #expect(!SpeechInput.startedOver(previous: "Hello how", latest: "Hello how are you"))
        #expect(!SpeechInput.startedOver(previous: "I want to write two letters", latest: "I want to write to Lena"))
        #expect(!SpeechInput.startedOver(previous: "hello there", latest: "Hello, there!"))
        #expect(!SpeechInput.startedOver(previous: "", latest: "Hello"))
        // The recognition began again and reports only the new words.
        #expect(SpeechInput.startedOver(previous: "First I want to say that the team chat works well now", latest: "and then"))
        #expect(SpeechInput.startedOver(previous: "Please check the routines", latest: "Also the"))
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
        #expect(skills.skills.count == 1 && again.agents == [mira.id] && again.id != skill.id)
        #expect(!fm.fileExists(atPath: mirror.appendingPathComponent(skill.id).path))
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
        #expect(updated.id != deploy.id && updated.description == "a longer description now" && updated.agents == [mira.id])
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

    @MainActor @Test func usageWarnsOncePerThresholdAndWindow() {
        let store = LimitStore()
        func limit(_ week: Double, resets: Double = 100) -> PlanLimit {
            PlanLimit(id: "claude", five: nil, week: .init(percent: week, resets: resets), stamp: "2026-11-27T12:00:00Z")
        }
        #expect(store.crossed(limit(50)).isEmpty)
        #expect(store.crossed(limit(81)).map(\.threshold) == [80])
        #expect(store.crossed(limit(85)).isEmpty)
        #expect(store.crossed(limit(96)).map(\.threshold) == [95])
        #expect(store.crossed(limit(99)).isEmpty)
        // A new week warns again.
        #expect(store.crossed(limit(82, resets: 200)).map(\.threshold) == [80])
        #expect(limit(1).date != nil && store.name("codex") == "ChatGPT")
    }

    @Test func macStaysAwakeWhileAgentsWork() {
        #expect(SessionManager.awakeLevel(open: 0, working: false, always: false) == .none)
        #expect(SessionManager.awakeLevel(open: 2, working: false, always: false) == .appOnly)
        #expect(SessionManager.awakeLevel(open: 2, working: true, always: false) == .wholeMac)
        #expect(SessionManager.awakeLevel(open: 0, working: false, always: true) == .wholeMac)
    }
}