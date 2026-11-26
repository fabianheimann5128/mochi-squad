import Foundation

enum PythonToolError: LocalizedError {
    case missingScript(String)
    case failed(String)
    var errorDescription: String? {
        switch self {
        case .missingScript(let name): return t("The helper \(name).py is missing from the app bundle.", "Der Helfer \(name).py fehlt im App-Bundle.")
        case .failed(let name): return t("The helper \(name).py failed.", "Der Helfer \(name).py ist fehlgeschlagen.")
        }
    }
}

/// Starts a Python helper from the app bundle and reads its JSON output.
/// Reading happens on its own queue so that no Swift Concurrency thread blocks; cancelling ends the process.
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
        process.environment = AppPaths.helperEnvironment()
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
