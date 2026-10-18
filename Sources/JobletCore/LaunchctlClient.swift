import Foundation
#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

public struct CommandResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public var wasTruncated = false

    public init(exitCode: Int32, stdout: String, stderr: String, wasTruncated: Bool = false) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.wasTruncated = wasTruncated
    }

    var diagnostic: String {
        let value = [stderr, stdout].filter { !$0.isEmpty }.joined(separator: "\n")
        return String(value.prefix(4096)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public protocol LaunchctlExecuting: Sendable {
    func run(_ arguments: [String]) async throws -> CommandResult
}

struct ProcessLaunchctl: LaunchctlExecuting {
    func run(_ arguments: [String]) async throws -> CommandResult {
        try Task.checkCancellation()
        return try await Task.detached(priority: .utility) {
            try Self.execute(arguments)
        }.value
    }

    private static func execute(_ arguments: [String]) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C", "LANG": "C"]
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }
        do { try process.run() }
        catch { throw JobletError("Could not start launchctl: \(error.localizedDescription)") }

        // Both pipes are drained concurrently, including excess bytes, so a verbose child
        // cannot deadlock on a full pipe or allocate an unbounded result in the app.
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        let out = PipeCapture()
        let err = PipeCapture()
        let readers = DispatchGroup()
        for (handle, capture) in [(stdout.fileHandleForReading, out), (stderr.fileHandleForReading, err)] {
            readers.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { try? handle.close(); readers.leave() }
                capture.drain(handle)
            }
        }

        var timedOut = false
        if terminated.wait(timeout: .now() + 12) == .timedOut {
            timedOut = true
            if process.isRunning {
                process.terminate()
            }
            if terminated.wait(timeout: .now() + 2) == .timedOut, process.isRunning {
                // Only the launchctl process started above is terminated, never the job.
                _ = kill(process.processIdentifier, SIGKILL)
                _ = terminated.wait(timeout: .now() + 2)
            }
        }
        let drained = readers.wait(timeout: .now() + 2) == .success
        if timedOut {
            throw JobletError("launchctl did not respond in time. The result of the operation is unknown; refresh to check the state.")
        }
        guard !process.isRunning, drained else {
            throw JobletError("Could not read the launchctl result. Refresh to check the state.")
        }
        let outResult = out.result
        let errResult = err.result
        return CommandResult(exitCode: process.terminationStatus,
                             stdout: String(decoding: outResult.data, as: UTF8.self),
                             stderr: String(decoding: errResult.data, as: UTF8.self),
                             wasTruncated: outResult.truncated || errResult.truncated)
    }
}

private final class PipeCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private var truncated = false
    private static let limit = 1_048_576

    func drain(_ handle: FileHandle) {
        var collected = Data()
        var didTruncate = false
        do {
            while let chunk = try handle.read(upToCount: 8192), !chunk.isEmpty {
                let available = max(0, Self.limit - collected.count)
                collected.append(chunk.prefix(available))
                if chunk.count > available {
                    didTruncate = true
                }
            }
        } catch { didTruncate = true }
        lock.lock()
        bytes = collected
        truncated = didTruncate
        lock.unlock()
    }

    var result: (data: Data, truncated: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (bytes, truncated)
    }
}

struct DisabledTable {
    let values: [String: Bool]
}

struct RuntimeProbe {
    var runtime: JobRuntime
    var loadedPath: String?
}

struct LaunchctlClient {
    let runner: any LaunchctlExecuting
    let domain: String

    init(runner: any LaunchctlExecuting, uid: UInt32) {
        self.runner = runner
        domain = "gui/\(uid)"
    }

    func checked(_ arguments: [String]) async throws {
        let result = try await runner.run(arguments)
        guard result.exitCode == 0 else {
            let diagnostic = result.diagnostic.isEmpty ? "no details" : result.diagnostic
            throw JobletError("launchctl \(arguments.first ?? "") failed (exit code \(result.exitCode)).\n\(diagnostic)")
        }
    }

    func disabledTable() async throws -> DisabledTable? {
        let result = try await runner.run(["print-disabled", domain])
        guard result.exitCode == 0, !result.wasTruncated else { return nil }
        return Self.parseDisabledTable(result.stdout)
    }

    func probe(label: String, plistDisabled: Bool, table: DisabledTable?) async throws -> RuntimeProbe {
        let result = try await runner.run(["print", "\(domain)/\(label)"])
        let disabled = table.map { $0.values[label] ?? plistDisabled }
        return Self.parseProbe(result, label: label, disabled: disabled)
    }

    static func parseDisabledTable(_ text: String) -> DisabledTable? {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard lines.first == "disabled services = {", lines.last == "}" else { return nil }
        let pattern = #"^"([^"]+)"\s*=>\s*(true|false|enabled|disabled)\s*,?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        var values: [String: Bool] = [:]
        for line in lines.dropFirst().dropLast() {
            let range = NSRange(line.startIndex ..< line.endIndex, in: line)
            guard let match = regex.firstMatch(in: line, range: range),
                  let keyRange = Range(match.range(at: 1), in: line),
                  let valueRange = Range(match.range(at: 2), in: line) else { return nil }
            let key = String(line[keyRange])
            guard values[key] == nil else { return nil }
            let value = String(line[valueRange])
            values[key] = value == "true" || value == "disabled"
        }
        return DisabledTable(values: values)
    }

    static func parseProbe(_ result: CommandResult, label: String, disabled: Bool?) -> RuntimeProbe {
        guard !result.wasTruncated else {
            return RuntimeProbe(runtime: JobRuntime(isDisabled: disabled, detail: "Could not read the complete launchctl output."), loadedPath: nil)
        }
        if result.exitCode != 0 {
            let detail = result.diagnostic
            let absent = detail.contains("Could not find service \"\(label)\"") || detail.contains("Could not find specified service \"\(label)\"")
            return RuntimeProbe(runtime: JobRuntime(phase: absent ? .unloaded : .unknown, isDisabled: disabled,
                                                    detail: absent ? nil : "launchctl failed to report the state (\(result.exitCode)).\n\(detail)"), loadedPath: nil)
        }
        var depth = 0
        var fields: [String: String] = [:]
        var malformed = false
        let interesting: Set = ["path", "state", "pid", "last exit code"]
        for line in result.stdout.components(separatedBy: .newlines) {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.hasSuffix("= {") || line == "{" {
                depth += 1; continue
            }
            if line == "}" || line == "};" {
                depth -= 1; if depth < 0 {
                    malformed = true
                }; continue
            }
            guard depth == 1, let separator = line.range(of: " = ") else { continue }
            let key = String(line[..<separator.lowerBound])
            guard interesting.contains(key) else { continue }
            if fields[key] != nil {
                malformed = true
            }
            fields[key] = String(line[separator.upperBound...])
        }
        let path = fields["path"].flatMap { $0.hasPrefix("/") ? $0 : nil }
        let pid = fields["pid"].flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil }
        // launchctl also emits values such as "78: EX_CONFIG".
        let exit = fields["last exit code"].flatMap { value -> Int? in
            guard let number = value.split(separator: ":", maxSplits: 1).first else { return nil }
            return Int(String(number).trimmingCharacters(in: .whitespaces))
        }
        let state = fields["state"]
        let phase: JobPhase = if !malformed, depth == 0, state == "running", pid != nil {
            .running
        } else if !malformed, depth == 0, ["not running", "waiting", "exited"].contains(state ?? ""), pid == nil {
            .waiting
        } else {
            .unknown
        }
        var notes: [String] = []
        if phase == .unknown {
            notes.append("Could not determine the run state from launchctl output.\n\(result.diagnostic)")
        }
        if path == nil {
            notes.append("Cannot determine the plist path the job was loaded from.")
        }
        if disabled == nil {
            notes.append("Cannot determine the persistent enabled/disabled setting.")
        }
        return RuntimeProbe(runtime: JobRuntime(phase: phase, isDisabled: disabled, pid: pid,
                                                lastExitCode: exit, detail: notes.isEmpty ? nil : notes.joined(separator: "\n")), loadedPath: path)
    }
}
