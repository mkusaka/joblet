import Foundation
import JobletCore

typealias JSON = [String: Any]

/// A failure reported to the model as a tool result with `isError: true`.
struct ToolError: Error {
    let message: String
    init(_ message: String) {
        self.message = message
    }
}

struct ToolDefinition {
    let name: String
    let description: String
    let properties: JSON
    let required: [String]
    let permission: Permission?
    let readOnly: Bool

    var json: JSON {
        var schema: JSON = ["type": "object", "properties": properties]
        if !required.isEmpty { schema["required"] = required }
        var annotations: JSON = ["readOnlyHint": readOnly]
        if !readOnly { annotations["destructiveHint"] = permission == .delete }
        return ["name": name, "description": description, "inputSchema": schema, "annotations": annotations]
    }
}

private let labelProperty: JSON = ["type": "string", "description": "Job label, as returned by list_jobs."]
private let scheduleProperty: JSON = [
    "type": "object",
    "description": "kind: interval | daily | weekly | manual. interval uses interval_minutes (1-525600); daily uses hour (0-23) and minute (0-59); weekly also uses weekday (0 = Sunday ... 6 = Saturday).",
    "properties": [
        "kind": ["type": "string", "enum": ScheduleKind.allCases.map(\.rawValue)],
        "interval_minutes": ["type": "integer"],
        "hour": ["type": "integer"],
        "minute": ["type": "integer"],
        "weekday": ["type": "integer"],
    ],
]
private let draftProperties: JSON = [
    "name": ["type": "string", "description": "Display name, 1-80 characters."],
    "command": ["type": "string", "description": "Shell command line, run with the user's login environment."],
    "working_directory": ["type": "string", "description": "Absolute path or ~/...; empty means the home folder."],
    "schedule": scheduleProperty,
    "run_at_load": ["type": "boolean", "description": "Also run when the job is loaded."],
    "enabled": ["type": "boolean", "description": "Register the job with launchd."],
]

let allTools: [ToolDefinition] = [
    ToolDefinition(name: "list_jobs", description: "List the user's launchd LaunchAgents with schedule and runtime state.",
                   properties: [:], required: [], permission: nil, readOnly: true),
    ToolDefinition(name: "get_job", description: "Get one job: definition, runtime state and plist XML.",
                   properties: ["label": labelProperty], required: ["label"], permission: nil, readOnly: true),
    ToolDefinition(name: "read_log", description: "Read the tail of a Joblet-created job's stdout or stderr log.",
                   properties: ["label": labelProperty,
                                "stream": ["type": "string", "enum": ["stdout", "stderr"], "description": "Defaults to stdout."],
                                "max_bytes": ["type": "integer", "description": "Default 16384, maximum 65536."]],
                   required: ["label"], permission: nil, readOnly: true),
    ToolDefinition(name: "create_job", description: "Create a Joblet job (label is generated).",
                   properties: draftProperties, required: ["name", "command"], permission: .create, readOnly: false),
    ToolDefinition(name: "update_job", description: "Update a Joblet-created job. Omitted fields keep their current value. Fails while the job is running.",
                   properties: draftProperties.merging(["label": labelProperty]) { $1 }, required: ["label"],
                   permission: .update, readOnly: false),
    ToolDefinition(name: "set_job_enabled", description: "Enable or disable a job. Fails while the job is running.",
                   properties: ["label": labelProperty, "enabled": ["type": "boolean"]], required: ["label", "enabled"],
                   permission: .update, readOnly: false),
    ToolDefinition(name: "run_job", description: "Start a loaded, enabled job now.",
                   properties: ["label": labelProperty], required: ["label"], permission: .run, readOnly: false),
    ToolDefinition(name: "delete_job", description: "Delete a Joblet-created job (the plist is moved to a backup).",
                   properties: ["label": labelProperty], required: ["label"], permission: .delete, readOnly: false),
]

struct ToolRunner {
    let repository: JobRepository
    let permissions: Set<Permission>

    var enabledTools: [ToolDefinition] {
        allTools.filter { $0.permission.map(permissions.contains) ?? true }
    }

    /// Returns nil for an unknown tool name; otherwise the structured result.
    func call(_ name: String, _ arguments: JSON) async throws -> JSON? {
        guard let tool = allTools.first(where: { $0.name == name }) else { return nil }
        if let permission = tool.permission, !permissions.contains(permission) {
            throw ToolError("Tool \(name) is disabled. Restart joblet-mcp with \(permission.rawValue) to enable it.")
        }
        switch name {
        case "list_jobs":
            let snapshot = try await repository.listJobs()
            return ["jobs": snapshot.jobs.map(describe), "warnings": snapshot.warnings]
        case "get_job":
            let job = try await find(arguments)
            var result = describe(job)
            result["plist"] = try await repository.plistText(for: job)
            return result
        case "read_log":
            let job = try await find(arguments)
            try requireCreatedByJoblet(job, "Reading logs")
            let stream = try string(arguments, "stream") ?? "stdout"
            guard let logStream = LogStream(rawValue: stream) else { throw ToolError("stream must be stdout or stderr.") }
            let maxBytes = try min(max(int(arguments, "max_bytes") ?? 16384, 1), 65536)
            return try await ["label": job.label, "stream": stream, "text": repository.readLog(for: job, stream: logStream, maxBytes: maxBytes)]
        case "create_job":
            var draft = JobDraft()
            guard try string(arguments, "name") != nil, try string(arguments, "command") != nil else {
                throw ToolError("name and command are required.")
            }
            try apply(arguments, to: &draft)
            let label = try await repository.create(draft)
            let created = try await repository.listJobs().jobs.first { $0.label == label }
            return created.map(describe) ?? ["label": label]
        case "update_job":
            let job = try await find(arguments)
            try requireCreatedByJoblet(job, "Editing")
            guard var draft = job.draft else { throw ToolError("This job cannot be edited by Joblet.") }
            try apply(arguments, to: &draft)
            try await repository.update(job, draft: draft)
            return try await describe(find(arguments))
        case "set_job_enabled":
            let job = try await find(arguments)
            guard let enabled = try bool(arguments, "enabled") else { throw ToolError("enabled is required.") }
            try requireOperable(job)
            try await repository.setEnabled(job, enabled: enabled)
            return try await describe(find(arguments))
        case "run_job":
            let job = try await find(arguments)
            try requireOperable(job)
            try await repository.runNow(job)
            return try await describe(find(arguments))
        case "delete_job":
            let job = try await find(arguments)
            try requireCreatedByJoblet(job, "Deleting")
            try await repository.delete(job)
            return ["deleted": job.label]
        default:
            return nil
        }
    }

    // MARK: Safety

    private func requireCreatedByJoblet(_ job: LaunchJob, _ action: String) throws {
        guard job.isCreatedByJoblet else {
            throw ToolError("\(action) jobs not created by Joblet is not allowed (\(job.label)).")
        }
    }

    private func requireOperable(_ job: LaunchJob) throws {
        guard job.isCreatedByJoblet || permissions.contains(.foreignJobs) else {
            throw ToolError("\(job.label) was not created by Joblet. Restart joblet-mcp with --allow-foreign-jobs to run, enable or disable it.")
        }
    }

    private func find(_ arguments: JSON) async throws -> LaunchJob {
        guard let label = try string(arguments, "label") else { throw ToolError("label is required.") }
        let matches = try await repository.listJobs().jobs.filter { $0.label == label }
        guard let job = matches.first else { throw ToolError("No job with label \(label).") }
        guard matches.count == 1 else { throw ToolError("Multiple plists share the label \(label).") }
        return job
    }

    // MARK: Argument parsing (strict: a wrongly typed value is an error, never ignored)

    private func string(_ arguments: JSON, _ key: String) throws -> String? {
        guard let value = arguments[key] else { return nil }
        guard let string = value as? String else { throw ToolError("\(key) must be a string.") }
        return string
    }

    private func int(_ arguments: JSON, _ key: String) throws -> Int? {
        guard let value = arguments[key] else { return nil }
        guard !(value is Bool), let int = value as? Int else { throw ToolError("\(key) must be an integer.") }
        return int
    }

    private func bool(_ arguments: JSON, _ key: String) throws -> Bool? {
        guard let value = arguments[key] else { return nil }
        guard let bool = value as? Bool else { throw ToolError("\(key) must be a boolean.") }
        return bool
    }

    private func apply(_ arguments: JSON, to draft: inout JobDraft) throws {
        if let name = try string(arguments, "name") { draft.name = name }
        if let command = try string(arguments, "command") { draft.command = command }
        if let directory = try string(arguments, "working_directory") { draft.workingDirectory = directory }
        if let runAtLoad = try bool(arguments, "run_at_load") { draft.runAtLoad = runAtLoad }
        if let enabled = try bool(arguments, "enabled") { draft.enabled = enabled }
        if let value = arguments["schedule"] {
            guard let schedule = value as? JSON else { throw ToolError("schedule must be an object.") }
            if let kind = try string(schedule, "kind") {
                guard let parsed = ScheduleKind(rawValue: kind) else { throw ToolError("schedule.kind must be interval, daily, weekly or manual.") }
                draft.schedule.kind = parsed
            }
            if let value = try int(schedule, "interval_minutes") { draft.schedule.intervalMinutes = value }
            if let value = try int(schedule, "hour") { draft.schedule.hour = value }
            if let value = try int(schedule, "minute") { draft.schedule.minute = value }
            if let value = try int(schedule, "weekday") { draft.schedule.weekday = value }
        }
    }

    // MARK: Output

    private func describe(_ job: LaunchJob) -> JSON {
        var result: JSON = [
            "label": job.label, "name": job.name, "command": job.command,
            "schedule_summary": job.scheduleDescription, "plist_path": job.plistURL.path,
            "created_by_joblet": job.isCreatedByJoblet, "can_edit": job.canEdit, "can_control": job.canControl,
            "phase": job.runtime.phase.rawValue,
        ]
        if let schedule = job.schedule {
            result["schedule"] = ["kind": schedule.kind.rawValue, "interval_minutes": schedule.intervalMinutes,
                                  "hour": schedule.hour, "minute": schedule.minute, "weekday": schedule.weekday]
            if let next = schedule.nextCalendarRun() { result["next_run"] = ISO8601DateFormatter().string(from: next) }
        }
        if let value = job.workingDirectory { result["working_directory"] = value }
        if let value = job.standardOutPath { result["stdout_path"] = value }
        if let value = job.standardErrorPath { result["stderr_path"] = value }
        if let value = job.runtime.isEnabled { result["enabled"] = value }
        if let value = job.runtime.pid { result["pid"] = value }
        if let value = job.runtime.lastExitCode { result["last_exit_code"] = value }
        if let value = job.runtime.detail { result["detail"] = value }
        return result
    }
}
