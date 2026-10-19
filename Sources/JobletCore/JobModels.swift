import Foundation

public enum ScheduleKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case interval, daily, weekly, manual
    public var id: String {
        rawValue
    }

    public var title: String {
        switch self {
        case .interval: "Interval"
        case .daily: "Daily"
        case .weekly: "Weekly"
        case .manual: "Manual"
        }
    }
}

public struct JobSchedule: Equatable, Codable, Sendable {
    public var kind: ScheduleKind
    public var intervalMinutes: Int
    public var hour: Int
    public var minute: Int
    public var weekday: Int

    public init(kind: ScheduleKind = .daily, intervalMinutes: Int = 60, hour: Int = 9, minute: Int = 0, weekday: Int = 1) {
        self.kind = kind
        self.intervalMinutes = intervalMinutes
        self.hour = hour
        self.minute = minute
        self.weekday = weekday
    }

    public var summary: String {
        let time = String(format: "%02d:%02d", hour, minute)
        switch kind {
        case .interval: return "Every \(intervalMinutes) min"
        case .daily: return "Daily at \(time)"
        case .weekly:
            let days = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
            let day = days.indices.contains(weekday) ? days[weekday] : "?"
            return "Every \(day) at \(time)"
        case .manual: return "Manual only"
        }
    }

    public func nextCalendarRun(after date: Date = Date(), calendar: Calendar = .current) -> Date? {
        guard (0 ... 23).contains(hour), (0 ... 59).contains(minute) else { return nil }
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        components.second = 0
        switch kind {
        case .daily: break
        case .weekly:
            guard (0 ... 6).contains(weekday) else { return nil }
            components.weekday = weekday + 1
        case .interval, .manual: return nil
        }
        return calendar.nextDate(after: date, matching: components, matchingPolicy: .nextTime,
                                 repeatedTimePolicy: .first, direction: .forward)
    }

    public func validate() throws {
        switch kind {
        case .interval:
            guard (1 ... 525_600).contains(intervalMinutes) else {
                throw JobletError("Enter a run interval from 1 to 525,600 minutes.")
            }
        case .daily, .weekly:
            guard (0 ... 23).contains(hour), (0 ... 59).contains(minute) else {
                throw JobletError("Enter a valid run time.")
            }
            if kind == .weekly, !(0 ... 6).contains(weekday) {
                throw JobletError("Select a weekday to run on.")
            }
        case .manual: break
        }
    }
}

public struct JobDraft: Equatable, Sendable {
    public var name: String
    public var command: String
    public var workingDirectory: String
    public var schedule: JobSchedule
    public var runAtLoad: Bool
    public var enabled: Bool

    public init(name: String = "", command: String = "date", workingDirectory: String = "",
                schedule: JobSchedule = JobSchedule(), runAtLoad: Bool = false, enabled: Bool = true)
    {
        self.name = name
        self.command = command
        self.workingDirectory = workingDirectory
        self.schedule = schedule
        self.runAtLoad = runAtLoad
        self.enabled = enabled
    }

    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 80,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            throw JobletError("Enter a name of 1 to 80 characters without control characters.")
        }
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              command.utf8.count <= 16384, !command.contains("\0")
        else {
            throw JobletError("The command must not be empty and must be at most 16 KB. NUL characters are not allowed.")
        }
        guard workingDirectory.utf8.count <= 4096,
              !workingDirectory.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              workingDirectory.isEmpty || workingDirectory.hasPrefix("/") || workingDirectory == "~" || workingDirectory.hasPrefix("~/")
        else {
            throw JobletError("The working directory must be an absolute path or start with ~/. If left empty, the home folder is used.")
        }
        try schedule.validate()
    }
}

enum JobGroup {
    static let maximumLength = 40

    static func validatedName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= maximumLength,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            throw JobletError("Enter a group name of 1 to \(maximumLength) characters without control characters.")
        }
        return name
    }
}

public enum JobPhase: String, Sendable {
    case running, waiting, unloaded, unknown
    public var title: String {
        switch self {
        case .running: "Running"
        case .waiting: "Waiting"
        case .unloaded: "Not loaded"
        case .unknown: "Unknown"
        }
    }
}

public struct JobRuntime: Sendable, Equatable {
    public var phase: JobPhase
    public var isDisabled: Bool?
    public var pid: Int?
    public var lastExitCode: Int?
    public var detail: String?
    public var isEnabled: Bool? {
        if phase == .unloaded {
            return false
        }
        guard phase != .unknown, let isDisabled else { return nil }
        return !isDisabled
    }

    public init(phase: JobPhase = .unknown, isDisabled: Bool? = nil, pid: Int? = nil,
                lastExitCode: Int? = nil, detail: String? = nil)
    {
        self.phase = phase
        self.isDisabled = isDisabled
        self.pid = pid
        self.lastExitCode = lastExitCode
        self.detail = detail
    }
}

public struct LaunchJob: Identifiable, Sendable {
    /// A label can occur in more than one file. The file remains the UI identity.
    public var id: String {
        plistURL.path
    }

    public let label: String
    public let name: String
    public let command: String
    public let scheduleDescription: String
    public let schedule: JobSchedule?
    public let plistURL: URL
    public let workingDirectory: String?
    public let standardOutPath: String?
    public let standardErrorPath: String?
    public let isManaged: Bool
    public let canEdit: Bool
    public let canControl: Bool
    public var runtime: JobRuntime
    public let draft: JobDraft?
    /// Stored in Joblet's own groups.json, never in the plist, so any job can be grouped.
    public var group: String?
    /// Newest modification time of a non-empty stdout/stderr log; nil when neither was ever written.
    public var lastLogWrite: Date?
    var revision: FileRevision?
    /// Optimistic-concurrency token (not a secret) that changes whenever the plist file changes.
    public var revisionToken: String? {
        revision?.token
    }

    public init(label: String, name: String, command: String, scheduleDescription: String,
                schedule: JobSchedule?, plistURL: URL, workingDirectory: String?,
                standardOutPath: String?, standardErrorPath: String?, isManaged: Bool,
                canEdit: Bool, canControl: Bool, runtime: JobRuntime, draft: JobDraft?)
    {
        self.label = label
        self.name = name
        self.command = command
        self.scheduleDescription = scheduleDescription
        self.schedule = schedule
        self.plistURL = plistURL
        self.workingDirectory = workingDirectory
        self.standardOutPath = standardOutPath
        self.standardErrorPath = standardErrorPath
        self.isManaged = isManaged
        self.canEdit = canEdit
        self.canControl = canControl
        self.runtime = runtime
        self.draft = draft
        revision = nil
    }

    /// Estimated next start, only for an enabled, loaded job. An interval job uses its last log write
    /// plus the interval, because launchd does not report interval run times; the result can be in the past.
    public func nextRunEstimate(now: Date = Date(), calendar: Calendar = .current) -> Date? {
        guard runtime.isEnabled == true, let schedule else { return nil }
        if schedule.kind == .interval {
            return lastLogWrite?.addingTimeInterval(TimeInterval(schedule.intervalMinutes * 60))
        }
        return schedule.nextCalendarRun(after: now, calendar: calendar)
    }
}

public struct JobSnapshot: Sendable {
    public let jobs: [LaunchJob]
    public let warnings: [String]
    public init(jobs: [LaunchJob], warnings: [String]) {
        self.jobs = jobs
        self.warnings = warnings
    }
}

public enum LogStream: String, CaseIterable, Identifiable, Sendable {
    case stdout, stderr
    public var id: String {
        rawValue
    }

    public var title: String {
        self == .stdout ? "Standard output" : "Standard error"
    }
}

struct JobletError: LocalizedError {
    let message: String
    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}
