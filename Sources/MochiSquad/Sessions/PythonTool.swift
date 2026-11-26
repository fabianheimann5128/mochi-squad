import Foundation

enum PythonToolError: LocalizedError {
    case missingScript(String)
    case failed(String)
    var errorDescription: String? {
        switch self {
        case .missingScript(let name): return "Der Helfer \(name).py fehlt im App-Bundle."
        case .failed(let name): return "Der Helfer \(name).py ist fehlgeschlagen."
        }
    }
}

/// Startet einen Python-Helfer aus dem App-Bundle und liest seine JSON-Ausgabe.
/// Gelesen wird auf einer eigenen Warteschlange, damit kein Thread von Swift Concurrency blockiert; Abbruch beendet den Prozess.
enum PythonTool {
    private static let queue = DispatchQueue(label: "mochi.python-tool", qos: .utility, attributes: .concurrent)

    static func run<T: Decodable>(_ script: String, _ args: [String], as type: T.Type) async throws -> T {
        try JSONDecoder().decode(type, from: try await output(script, args))
    }

    static func output(_ script: String, _ args: [String]) async throws -> Data {
        guard let tool = AppPaths.script(script) else { throw PythonToolError.missingScript(script) }
        let process = Process()
        process.executableURL = AppPaths.python
        process.arguments = ["-B", tool.path] + args
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                queue.async {
                    do { try process.run() } catch { continuation.resume(throwing: error); return }
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    if process.terminationStatus == 0 { continuation.resume(returning: data) }
                    else { continuation.resume(throwing: PythonToolError.failed(script)) }
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}
