import Foundation

public enum ScheduleKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case interval, daily, weekly, once, manual
    public var id: String {
        rawValue
    }

    public var title: String {
        switch self {
        case .interval: "Interval"
        case .daily: "Daily"
        case .weekly: "Weekly"
        case .once: "Once"
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
    /// Local calendar date of a `.once` schedule; `hour` and `minute` give its time.
    public var year: Int
    public var month: Int
    public var day: Int

    public init(kind: ScheduleKind = .daily, intervalMinutes: Int = 60, hour: Int = 9, minute: Int = 0, weekday: Int = 1,
                year: Int = 2000, month: Int = 1, day: Int = 1)
    {
        self.kind = kind
        self.intervalMinutes = intervalMinutes
        self.hour = hour
        self.minute = minute
        self.weekday = weekday
        self.year = year
        self.month = month
        self.day = day
    }

    /// Strictly parses local `YYYY-MM-DDTHH:MM` into a `.once` schedule.
    public static func once(_ text: String) -> JobSchedule? {
        let parts = text.split(separator: "T", omittingEmptySubsequences: false)
        guard text.utf8.count == 16, parts.count == 2 else { return nil }
        let date = parts[0].split(separator: "-", omittingEmptySubsequences: false)
        let time = parts[1].split(separator: ":", omittingEmptySubsequences: false)
        let fields = date + time
        guard date.count == 3, time.count == 2, zip(fields, [4, 2, 2, 2, 2]).allSatisfy({ field, width in
            field.utf8.count == width && field.utf8.allSatisfy { (48 ... 57).contains($0) }
        }) else { return nil }
        let numbers = fields.compactMap { Int($0) }
        return JobSchedule(kind: .once, hour: numbers[3], minute: numbers[4], year: numbers[0], month: numbers[1], day: numbers[2])
    }

    public var onceDateText: String {
        String(format: "%04d-%02d-%02dT%02d:%02d", year, month, day, hour, minute)
    }

    /// The local moment of a `.once` schedule, or nil if that wall-clock time does not exist (for example Feb 30).
    public func onceDate(calendar: Calendar = .current) -> Date? {
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        guard let date = calendar.date(from: components) else { return nil }
        let actual = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return actual == components ? date : nil
    }

    public mutating func setOnceDate(_ date: Date, calendar: Calendar = .current) {
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        year = components.year ?? year
        month = components.month ?? month
        day = components.day ?? day
        hour = components.hour ?? hour
        minute = components.minute ?? minute
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
        case .once: return "Once on \(onceDateText.prefix(10)) at \(time)"
        case .manual: return "Manual only"
        }
    }

    public func nextCalendarRun(after date: Date = Date(), calendar: Calendar = .current) -> Date? {
        guard (0 ... 23).contains(hour), (0 ... 59).contains(minute) else { return nil }
        if kind == .once {
            return onceDate(calendar: calendar).flatMap { $0 > date ? $0 : nil }
        }
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        components.second = 0
        switch kind {
        case .daily: break
        case .weekly:
            guard (0 ... 6).contains(weekday) else { return nil }
            components.weekday = weekday + 1
        case .interval, .manual, .once: return nil
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
        case .once:
            // Whether the date is still in the future is checked when saving, not here:
            // a finished one-time job must still decode as editable.
            guard (2000 ... 9999).contains(year), onceDate() != nil else {
                throw JobletError("Choose a valid date and time for the one-time run.")
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
        if schedule.kind == .once, runAtLoad {
            throw JobletError("A one-time job cannot also run when loaded; it would run and remove itself right away.")
        }
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

    /// A one-time job that unregistered itself after running: it is unloaded and wrote to its log after the scheduled time.
    public var isOnceDone: Bool {
        guard schedule?.kind == .once, runtime.phase == .unloaded,
              let date = schedule?.onceDate(), let lastLogWrite else { return false }
        return lastLogWrite >= date
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
