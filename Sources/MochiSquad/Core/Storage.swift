import Foundation

/// Where Mochi Squad keeps its data on the user's Mac.
enum AppPaths {
    static let appName = "Mochi Squad"

    /// ~/Library/Application Support/Mochi Squad (readable by the user only).
    static let support: URL = directory(FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support", isDirectory: true)
        .appendingPathComponent(appName, isDirectory: true))

    static func file(_ name: String) -> URL { support.appendingPathComponent(name) }
    /// Codex folder of an extra ChatGPT subscription (like common.account_home).
    /// Only for valid ids (like common.ACCOUNT_ID); anything else could lead out of the folder.
    static func accountHome(_ id: String) -> URL? {
        guard id.range(of: "^[a-z0-9][a-z0-9-]{0,39}$", options: .regularExpression) != nil else { return nil }
        return support.appendingPathComponent("accounts/codex/" + id, isDirectory: true)
    }
    static func folder(_ name: String) -> URL { directory(support.appendingPathComponent(name, isDirectory: true)) }

    /// Launch data per session. Inside the app data, which agents may neither read nor write.
    static var sessions: URL { folder("sessions") }
    /// Area outside the app data without spaces in its path: the post tool and one outbox per session.
    static let shared: URL = directory(FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/dev.mochisquad.app", isDirectory: true))
    static var outboxes: URL { directory(shared.appendingPathComponent("outbox", isDirectory: true)) }
    static var postTool: URL { shared.appendingPathComponent("bin/post") }

    /// At launch: remove leftovers of crashed sessions and provide the post tool from the app bundle.
    static func prepareRuntime() {
        let fm = FileManager.default
        for folder in [sessions, outboxes] {
            for item in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] { try? fm.removeItem(at: item) }
        }
        guard let source = script("post") else { return }
        directory(postTool.deletingLastPathComponent())
        try? fm.removeItem(at: postTool)
        try? fm.copyItem(at: source, to: postTool)
        try? fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: postTool.path)
    }

    /// Reads a small regular file. Links, pipes and oversized files are refused.
    static func readSmallFile(_ url: URL, limit: Int = 64_000) -> Data? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.intValue, size <= limit else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Python helper in the app bundle (Contents/Resources/*.py).
    static func script(_ name: String) -> URL? { Bundle.main.url(forResource: name, withExtension: "py") }
    /// The Python of the Xcode command line tools. Other paths are deliberately not used.
    static let python = URL(fileURLWithPath: "/usr/bin/python3")
    static var pythonAvailable: Bool {
        let tools = Process()
        tools.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        tools.arguments = ["-p"]
        tools.standardOutput = FileHandle.nullDevice
        tools.standardError = FileHandle.nullDevice
        guard (try? tools.run()) != nil else { return false }
        tools.waitUntilExit()
        return tools.terminationStatus == 0
    }

    /// Environment for helpers: the interface language decides which messages they return.
    static func helperEnvironment(_ base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        base.merging(["MOCHI_LANG": L10n.language.rawValue]) { $1 }
    }

    @discardableResult
    private static func directory(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }
}

/// Read JSON files and write them atomically, readable by the user only.
enum JSONFile {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, to url: URL) throws {
        try write(try encoder.encode(value), to: url)
    }

    /// Writes atomically; the file is readable by the user only from the start.
    static func write(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let temp = url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + "." + UUID().uuidString)
        guard fm.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            if fm.fileExists(atPath: url.path) { _ = try fm.replaceItemAt(url, withItemAt: temp) } else { try fm.moveItem(at: temp, to: url) }
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }
}

/// Saves on behalf of the stores and tells the user when writing fails. The change stays in memory; every later
/// save and a periodic retry try again, and the warning comes back only for a new failure.
@MainActor enum SaveGuard {
    /// Shows the message to the user; set by the app at launch.
    static var report: (String) -> Void = { _ in }
    private static var failing = [String: () throws -> Void]()

    static func save(_ what: String, _ write: @escaping () throws -> Void) {
        do {
            try write()
            failing[what] = nil
        } catch {
            let known = failing[what] != nil
            failing[what] = write
            if !known {
                report(t("Mochi Squad could not save your \(what). The change is kept only until you quit. Check free disk space and the permissions of the app data folder; Mochi Squad keeps trying.",
                         "Mochi Squad konnte deine \(what) nicht speichern. Die Änderung gilt nur, bis du die App beendest. Prüfe den freien Speicherplatz und die Rechte des App-Datenordners; Mochi Squad versucht es weiter."))
            }
        }
    }

    /// Tries the failed writes again. True while something is still unsaved.
    @discardableResult
    static func retry() -> Bool {
        for (what, write) in failing where (try? write()) != nil { failing[what] = nil }
        return !failing.isEmpty
    }
}

/// Bundles quick changes into one write (e.g. while typing).
@MainActor final class Debouncer {
    private var task: Task<Void, Never>?
    private let delay: Duration
    init(delay: Duration = .milliseconds(400)) { self.delay = delay }
    func run(_ action: @escaping @MainActor () -> Void) {
        task?.cancel()
        task = Task { [delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            action()
        }
    }
    func flush(_ action: @MainActor () -> Void) {
        task?.cancel()
        task = nil
        action()
    }
}
