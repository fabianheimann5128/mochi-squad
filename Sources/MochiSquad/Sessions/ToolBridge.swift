import Foundation
import Security

/// Startet bridge.py, den lokalen MCP-Server für den Koordinator, und beantwortet dessen Werkzeugaufrufe.
/// Das Token gilt für die Laufzeit der App, der Port wechselt mit jedem Start des Servers; stirbt der Prozess,
/// startet er mit wachsender Pause neu.
@MainActor final class ToolBridge: ObservableObject {
    typealias Handler = @MainActor (String, [String: String]) async -> [String: Any]

    @Published private(set) var port: Int?
    /// Name der Umgebungsvariable, über die der Koordinator sein Token bekommt.
    static let tokenVariable = "MOCHI_TOKEN"
    let token = ToolBridge.makeToken()
    private var process: Process?
    private var input: FileHandle?
    private var runner: Task<Void, Never>?

    /// MCP-Konfiguration für eine Koordinator-Sitzung oder nil, solange der Server nicht bereit ist.
    /// Sie enthält kein Geheimnis: Der Client setzt das Token aus seiner Umgebung ein.
    var mcpConfig: String? {
        guard let port else { return nil }
        let config: [String: Any] = ["mcpServers": ["mochi": [
            "type": "http", "url": "http://127.0.0.1:\(port)/mcp",
            "headers": ["Authorization": "Bearer ${\(Self.tokenVariable)}"]]]]
        return (try? JSONSerialization.data(withJSONObject: config)).flatMap { String(data: $0, encoding: .utf8) }
    }

    func start(_ handler: @escaping Handler) {
        guard runner == nil else { return }
        runner = Task { [weak self] in
            var pause = 1.0
            while !Task.isCancelled, let self {
                let began = Date()
                await self.runOnce(handler)
                if Task.isCancelled { break }
                // Lief der Server eine Weile, war es kein Startfehler: Pause zurücksetzen.
                pause = Date().timeIntervalSince(began) > 60 ? 1 : min(pause * 2, 60)
                try? await Task.sleep(for: .seconds(pause))
            }
        }
    }

    func stop() {
        runner?.cancel()
        runner = nil
        if process?.isRunning == true { process?.terminate() }
    }

    private func runOnce(_ handler: @escaping Handler) async {
        guard let script = AppPaths.script("bridge") else { return }
        let process = Process(), stdin = Pipe(), stdout = Pipe()
        process.executableURL = AppPaths.python
        process.arguments = ["-B", script.path]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return }
        self.process = process
        input = stdin.fileHandleForWriting
        write(token)
        defer { port = nil; input = nil; if process.isRunning { process.terminate() } }
        do {
            for try await line in stdout.fileHandleForReading.bytes.lines {
                guard let event = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
                if event["ready"] as? Bool == true, let port = event["port"] as? Int {
                    self.port = port
                } else if let id = event["id"] as? String, let name = event["tool"] as? String {
                    let args = event["args"] as? [String: String] ?? [:]
                    Task { [weak self] in
                        let result = await handler(name, args)
                        self?.answer(id, result)
                    }
                }
            }
        } catch {}
    }

    private func answer(_ id: String, _ result: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(result),
              let data = try? JSONSerialization.data(withJSONObject: ["id": id, "result": result]),
              let text = String(data: data, encoding: .utf8) else {
            write(#"{"id":"\#(id)","result":{"error":"Ungültige Antwort"}}"#)
            return
        }
        write(text)
    }

    private func write(_ line: String) {
        try? input?.write(contentsOf: Data((line + "\n").utf8))
    }

    private static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            // Ohne sicheren Zufall gibt es kein vorhersagbares Ersatz-Token.
            return UUID().uuidString + UUID().uuidString
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
