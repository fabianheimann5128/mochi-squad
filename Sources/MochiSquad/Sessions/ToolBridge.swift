import Foundation
import Security

/// Starts bridge.py, the local MCP server for the coordinators, and answers its tool calls.
/// Every coordinator session gets its own token, so each call arrives with the session that made it.
/// The port changes with every start of the server; if the process dies, it restarts with a growing pause.
@MainActor final class ToolBridge: ObservableObject {
    /// (tool, arguments, id of the calling session) → result.
    typealias Handler = @MainActor (String, [String: String], UUID?) async -> [String: Any]

    @Published private(set) var port: Int?
    /// Name of the environment variable through which a coordinator gets its token.
    static let tokenVariable = "MOCHI_TOKEN"
    /// Tokens in use: token → session.
    private var grants = [String: UUID]()
    private var process: Process?
    private var input: FileHandle?
    private var runner: Task<Void, Never>?

    /// MCP configuration for a coordinator session, or nil while the server is not ready.
    /// It holds no secret: the client inserts the token from its environment.
    var mcpConfig: String? {
        guard let port else { return nil }
        let config: [String: Any] = ["mcpServers": ["mochi": [
            "type": "http", "url": "http://127.0.0.1:\(port)/mcp",
            "headers": ["Authorization": "Bearer ${\(Self.tokenVariable)}"]]]]
        return (try? JSONSerialization.data(withJSONObject: config)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// A fresh token that identifies `session` to the server until it is revoked.
    func grant(to session: UUID) -> String {
        let token = Self.makeToken()
        grants[token] = session
        send(["grant": token, "caller": session.uuidString])
        return token
    }

    func revoke(session: UUID) {
        for (token, owner) in grants where owner == session {
            grants[token] = nil
            send(["revoke": token])
        }
    }

    func start(_ handler: @escaping Handler) {
        guard runner == nil else { return }
        runner = Task { [weak self] in
            var pause = 1.0
            while !Task.isCancelled, let self {
                let began = Date()
                await self.runOnce(handler)
                if Task.isCancelled { break }
                // If the server ran for a while, it was no startup failure: reset the pause.
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
        defer { port = nil; input = nil; if process.isRunning { process.terminate() } }
        do {
            for try await line in stdout.fileHandleForReading.bytes.lines {
                guard let event = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
                if event["ready"] as? Bool == true, let port = event["port"] as? Int {
                    // A restarted server knows no tokens yet: hand it those of the sessions that still run.
                    for (token, session) in grants { send(["grant": token, "caller": session.uuidString]) }
                    self.port = port
                } else if let id = event["id"] as? String, let name = event["tool"] as? String {
                    let args = event["args"] as? [String: String] ?? [:]
                    let caller = (event["caller"] as? String).flatMap(UUID.init)
                    Task { [weak self] in
                        let result = await handler(name, args, caller)
                        self?.answer(id, result)
                    }
                }
            }
        } catch {}
    }

    private func answer(_ id: String, _ result: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(result) else { return send(["id": id, "result": ["error": "Invalid answer"]]) }
        send(["id": id, "result": result])
    }

    private func send(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        try? input?.write(contentsOf: data + Data("\n".utf8))
    }

    private static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            // Without secure randomness there is no predictable stand-in token.
            return UUID().uuidString + UUID().uuidString
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
