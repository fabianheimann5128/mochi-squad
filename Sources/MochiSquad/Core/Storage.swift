import Foundation

/// Orte, an denen Mochi Squad Daten ablegt. Alles bleibt auf dem Mac des Nutzers.
enum AppPaths {
    static let appName = "Mochi Squad"

    /// ~/Library/Application Support/Mochi Squad (nur für den Nutzer lesbar).
    static let support: URL = directory(FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support", isDirectory: true)
        .appendingPathComponent(appName, isDirectory: true))

    static func file(_ name: String) -> URL { support.appendingPathComponent(name) }
    /// Codex-Ordner eines weiteren ChatGPT-Abos (wie common.account_home).
    static func accountHome(_ id: String) -> URL { support.appendingPathComponent("accounts/codex/" + id, isDirectory: true) }
    static func folder(_ name: String) -> URL { directory(support.appendingPathComponent(name, isDirectory: true)) }

    /// Startdaten je Sitzung. Liegt in den App-Daten, die Agenten weder lesen noch beschreiben dürfen.
    static var sessions: URL { folder("sessions") }
    /// Bereich außerhalb der App-Daten ohne Leerzeichen im Pfad: das Post-Werkzeug und je Sitzung ein Postausgang.
    static let shared: URL = directory(FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/dev.mochisquad.app", isDirectory: true))
    static var outboxes: URL { directory(shared.appendingPathComponent("outbox", isDirectory: true)) }
    static var postTool: URL { shared.appendingPathComponent("bin/post") }

    /// Beim Start: Reste abgestürzter Sitzungen entfernen und das Post-Werkzeug aus der App bereitstellen.
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

    /// Liest eine kleine, gewöhnliche Datei. Verweise, Pipes und zu große Dateien werden abgelehnt.
    static func readSmallFile(_ url: URL, limit: Int = 64_000) -> Data? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.intValue, size <= limit else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Python-Helfer im App-Bundle (Contents/Resources/*.py).
    static func script(_ name: String) -> URL? { Bundle.main.url(forResource: name, withExtension: "py") }
    /// Das Python der Xcode-Befehlszeilenwerkzeuge. Andere Pfade werden bewusst nicht genutzt.
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

    @discardableResult
    private static func directory(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }
}

/// JSON-Dateien lesen und atomar, nur für den Nutzer lesbar, schreiben.
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

    /// Schreibt atomar; die Datei ist von Anfang an nur für den Nutzer lesbar.
    static func write(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let temp = url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + "." + UUID().uuidString)
        guard fm.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if fm.fileExists(atPath: url.path) { _ = try fm.replaceItemAt(url, withItemAt: temp) } else { try fm.moveItem(at: temp, to: url) }
    }
}

/// Bündelt schnelle Änderungen zu einem Schreibvorgang (z. B. beim Tippen).
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
