import Foundation
#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// In-memory stand-in for launchctl. Never invokes launchctl, zsh, or the user account's launchd domain.
/// Used by tests and by UI/MCP test hosts.
public actor InMemoryLaunchctl: LaunchctlExecuting {
    public struct Service: Sendable {
        public var path: String
        public var phase: JobPhase
    }

    private var services: [String: Service] = [:]
    private var disabled: [String: Bool] = [:]
    private var history: [[String]] = []
    private var failures: [String: Int] = [:]
    private var startOnNextDisable = false
    private var unknownDisabled = false

    public init() {}

    public func register(_ label: String, path: String, phase: JobPhase = .waiting) {
        services[label] = Service(path: path, phase: phase)
    }

    public func setDisabled(_ value: Bool, label: String) {
        disabled[label] = value
    }

    public func failNext(_ verb: String, count: Int = 1) {
        failures[verb] = count
    }

    public func raceStartOnDisable() {
        startOnNextDisable = true
    }

    public func makeDisabledOutputUnknown() {
        unknownDisabled = true
    }

    public func calls() -> [[String]] {
        history
    }

    public func clearCalls() {
        history = []
    }

    public func disabledValue(_ label: String) -> Bool? {
        disabled[label]
    }

    public func service(_ label: String) -> Service? {
        services[label]
    }

    public func run(_ arguments: [String]) async throws -> CommandResult {
        history.append(arguments)
        let verb = arguments[0]
        if let remaining = failures[verb], remaining > 0 {
            failures[verb] = remaining - 1
            return CommandResult(exitCode: 5, stdout: "", stderr: "Injected \(verb) failure")
        }
        let label = arguments.last?.split(separator: "/").last.map(String.init) ?? ""
        switch verb {
        case "print-disabled":
            if unknownDisabled { return CommandResult(exitCode: 0, stdout: "future output format", stderr: "") }
            let entries = disabled.keys.sorted().map { "\"\($0)\" => \(disabled[$0]! ? "true" : "false")" }.joined(separator: "\n")
            return CommandResult(exitCode: 0, stdout: "disabled services = {\n\(entries)\n}\n", stderr: "")
        case "print":
            guard let service = services[label] else {
                return CommandResult(exitCode: 113, stdout: "", stderr: "Could not find service \"\(label)\" in domain for user gui: \(getuid())")
            }
            let state = service.phase == .running ? "running" : "not running"
            let pid = service.phase == .running ? "\n\tpid = 4242" : ""
            return CommandResult(exitCode: 0, stdout: "\(arguments[1]) = {\n\tpath = \(service.path)\n\tstate = \(state)\(pid)\n\tlast exit code = 0\n}\n", stderr: "")
        case "enable": disabled[label] = false
        case "disable":
            disabled[label] = true
            if startOnNextDisable, services[label] != nil {
                services[label]?.phase = .running
                startOnNextDisable = false
            }
        case "bootstrap":
            let path = arguments[2]
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            guard let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                  let actualLabel = object["Label"] as? String
            else { return CommandResult(exitCode: 5, stdout: "", stderr: "Invalid plist") }
            services[actualLabel] = Service(path: path, phase: .waiting)
        case "bootout": services.removeValue(forKey: label)
        case "kickstart": services[label]?.phase = .running
        default: return CommandResult(exitCode: 64, stdout: "", stderr: "Unexpected fake command")
        }
        return CommandResult(exitCode: 0, stdout: "", stderr: "")
    }
}
