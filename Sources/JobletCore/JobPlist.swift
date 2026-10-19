import CoreFoundation
import Foundation

struct DecodedJobPlist {
    let label: String
    let name: String
    let command: String
    let workingDirectory: String?
    let stdout: String?
    let stderr: String?
    let schedule: JobSchedule?
    let scheduleDescription: String
    let disabled: Bool
    let hasValidDisabledValue: Bool
    let draft: JobDraft?
    var isCanonical: Bool {
        draft != nil
    }
}

enum JobPlist {
    static let labelPrefix = "local.joblet."
    static let marker = "Joblet/v1: "
    static let commandPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    static let onceArgvZero = "joblet-once"

    /// Fixed wrapper for a one-time job: `$1` is the scheduled `YYYY-MM-DDTHH:MM` and `$2` the user command, both passed
    /// as separate arguments and never spliced into this text. The command runs in a child zsh, so its own `exit` cannot
    /// skip the cleanup. launchd has no Year, so a run in another year is skipped. Afterwards the job disables itself
    /// (so the next login does not load it again) and unloads itself; bootout ends this shell.
    static func onceScript(label: String) -> String {
        let target = "gui/$UID/\(label)"
        return #"if [[ "$(/bin/date +%Y)" == "${1[1,4]}" ]]; then /bin/zsh -c "$2"; "#
            + #"print -r -- "joblet: one-time run finished with exit status $?"; "#
            + #"else print -r -- "joblet: skipped; this one-time run was scheduled for $1"; fi; "#
            + "/bin/launchctl disable \(target); /bin/launchctl bootout \(target)"
    }

    static func onceProgramArguments(label: String, schedule: JobSchedule, command: String) -> [String] {
        ["/bin/zsh", "-c", onceScript(label: label), onceArgvZero, schedule.onceDateText, command]
    }

    static func isSafeLabel(_ label: String) -> Bool {
        guard (1 ... 255).contains(label.utf8.count), let first = label.utf8.first,
              isAlphanumeric(first) else { return false }
        return label.utf8.allSatisfy { isAlphanumeric($0) || $0 == 45 || $0 == 46 || $0 == 64 || $0 == 95 }
    }

    static func managedLabel(_ label: String) -> Bool {
        guard label.hasPrefix(labelPrefix), let uuid = UUID(uuidString: String(label.dropFirst(labelPrefix.count))) else { return false }
        return label == labelPrefix + uuid.uuidString.lowercased()
    }

    static func logsDirectory(home: URL, label: String) -> URL {
        home.appendingPathComponent("Library/Application Support/Joblet/Logs", isDirectory: true)
            .appendingPathComponent(label, isDirectory: true)
    }

    static func normalizedWorkingDirectory(_ value: String, home: URL) -> String {
        let expanded: String = if value.isEmpty || value == "~" {
            home.path
        } else if value.hasPrefix("~/") {
            home.appendingPathComponent(String(value.dropFirst(2))).path
        } else {
            value
        }
        return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL.path
    }

    static func encode(_ draft: JobDraft, label: String, home: URL) throws -> Data {
        try draft.validate()
        guard managedLabel(label) else { throw JobletError("Invalid Joblet label format.") }
        let logs = logsDirectory(home: home, label: label)
        var dictionary: [String: Any] = [
            "Label": label,
            "Comment": marker + draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
            "ProgramArguments": ["/bin/zsh", "-c", draft.command],
            "WorkingDirectory": normalizedWorkingDirectory(draft.workingDirectory, home: home),
            "EnvironmentVariables": ["PATH": commandPath],
            "StandardOutPath": logs.appendingPathComponent("stdout.log").path,
            "StandardErrorPath": logs.appendingPathComponent("stderr.log").path,
            "RunAtLoad": draft.runAtLoad,
            "Disabled": !draft.enabled,
        ]
        switch draft.schedule.kind {
        case .interval: dictionary["StartInterval"] = draft.schedule.intervalMinutes * 60
        case .daily: dictionary["StartCalendarInterval"] = ["Hour": draft.schedule.hour, "Minute": draft.schedule.minute]
        case .weekly: dictionary["StartCalendarInterval"] = ["Weekday": draft.schedule.weekday, "Hour": draft.schedule.hour, "Minute": draft.schedule.minute]
        case .once:
            dictionary["StartCalendarInterval"] = ["Month": draft.schedule.month, "Day": draft.schedule.day,
                                                   "Hour": draft.schedule.hour, "Minute": draft.schedule.minute]
            dictionary["ProgramArguments"] = onceProgramArguments(label: label, schedule: draft.schedule, command: draft.command)
        case .manual: break
        }
        return try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
    }

    static func decode(_ data: Data, home: URL) throws -> DecodedJobPlist {
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let dictionary = object as? [String: Any], let label = dictionary["Label"] as? String, !label.isEmpty else {
            throw JobletError("The plist has no Label, or its root is not a dictionary.")
        }
        let comment = dictionary["Comment"] as? String
        let hasMarker = comment?.hasPrefix(marker) == true
        let name = hasMarker ? String(comment!.dropFirst(marker.count)) : label
        let arguments = dictionary["ProgramArguments"] as? [String]
        let program = dictionary["Program"] as? String
        let plainCommand: String? = if program == nil, let arguments, arguments.count == 3,
                                       arguments[0] == "/bin/zsh", arguments[1] == "-c"
        {
            arguments[2]
        } else {
            nil
        }
        let onceSchedule: JobSchedule? = if program == nil, let arguments, arguments.count == 6,
                                            Array(arguments[0 ... 3]) == ["/bin/zsh", "-c", onceScript(label: label), onceArgvZero]
        {
            JobSchedule.once(arguments[4])
        } else {
            nil
        }
        let onceCommand = onceSchedule == nil ? nil : arguments?[5]
        let command: String = if let shown = onceCommand ?? plainCommand {
            shown
        } else if let program {
            // The first ProgramArguments item is argv[0], not an extra shell argument.
            "Program: \(program)\nProgramArguments: " + (arguments ?? []).map(shellQuoteForDisplay).joined(separator: " ")
        } else if let arguments, !arguments.isEmpty {
            arguments.map(shellQuoteForDisplay).joined(separator: " ")
        } else {
            "(Cannot read Program / ProgramArguments)"
        }
        // Our wrapper is only a one-time schedule when the calendar matches its date exactly; anything else is custom.
        let parsed = parseSchedule(dictionary, once: onceSchedule)
        let schedule = onceSchedule == nil || parsed?.kind == .once ? parsed : nil
        let shellCommand = schedule?.kind == .once ? onceCommand : plainCommand
        let runAtLoad = strictBool(dictionary["RunAtLoad"])
        let disabled = strictBool(dictionary["Disabled"])
        let working = dictionary["WorkingDirectory"] as? String
        let stdout = dictionary["StandardOutPath"] as? String
        let stderr = dictionary["StandardErrorPath"] as? String
        let expectedLogs = logsDirectory(home: home, label: label)
        let environment = dictionary["EnvironmentVariables"] as? [String: String]
        var draft: JobDraft?
        let required: Set = ["Label", "Comment", "ProgramArguments", "WorkingDirectory", "EnvironmentVariables", "StandardOutPath", "StandardErrorPath", "RunAtLoad", "Disabled"]
        let permitted = required.union(["StartInterval", "StartCalendarInterval"])
        let keys = Set(dictionary.keys)
        if managedLabel(label), hasMarker,
           required.isSubset(of: keys), keys.isSubset(of: permitted),
           let shellCommand, let schedule, let runAtLoad, let disabled, let working, working.hasPrefix("/"),
           normalizedWorkingDirectory(working, home: home) == working,
           environment == ["PATH": commandPath],
           stdout == expectedLogs.appendingPathComponent("stdout.log").path,
           stderr == expectedLogs.appendingPathComponent("stderr.log").path
        {
            let candidate = JobDraft(name: name, command: shellCommand, workingDirectory: working,
                                     schedule: schedule, runAtLoad: runAtLoad, enabled: !disabled)
            do { try candidate.validate(); draft = candidate }
            catch { draft = nil }
        }
        var description = schedule?.summary ?? "Custom launch conditions"
        if runAtLoad == true {
            description += "; also runs when loaded"
        }
        return DecodedJobPlist(label: label, name: name, command: command, workingDirectory: working,
                               stdout: stdout, stderr: stderr, schedule: schedule,
                               scheduleDescription: description, disabled: disabled ?? false,
                               hasValidDisabledValue: dictionary["Disabled"] == nil || disabled != nil,
                               draft: draft)
    }

    static func xmlText(_ data: Data) throws -> String {
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        let xml = try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
        return String(decoding: xml, as: UTF8.self)
    }

    /// `once` is the date carried by Joblet's one-time wrapper; only then can a Month/Day calendar be reduced to `.once`.
    static func parseSchedule(_ dictionary: [String: Any], once: JobSchedule? = nil) -> JobSchedule? {
        let interval = dictionary["StartInterval"]
        let calendar = dictionary["StartCalendarInterval"]
        // Other launch conditions cannot be faithfully reduced to the simple editor.
        let extraTriggers = ["KeepAlive", "WatchPaths", "QueueDirectories", "StartOnMount", "Sockets", "MachServices", "LaunchEvents"]
        guard !extraTriggers.contains(where: { dictionary[$0] != nil }) else { return nil }
        if interval != nil, calendar != nil {
            return nil
        }
        if let interval {
            guard let seconds = strictInteger(interval), seconds >= 60, seconds <= 31_536_000, seconds % 60 == 0 else { return nil }
            return JobSchedule(kind: .interval, intervalMinutes: seconds / 60)
        }
        if let calendar {
            guard let components = calendar as? [String: Any],
                  let hour = strictInteger(components["Hour"]), (0 ... 23).contains(hour),
                  let minute = strictInteger(components["Minute"]), (0 ... 59).contains(minute) else { return nil }
            let keys = Set(components.keys)
            if keys == Set(["Hour", "Minute"]) {
                return JobSchedule(kind: .daily, hour: hour, minute: minute)
            }
            if keys == Set(["Hour", "Minute", "Weekday"]), let weekday = strictInteger(components["Weekday"]), (0 ... 6).contains(weekday) {
                return JobSchedule(kind: .weekly, hour: hour, minute: minute, weekday: weekday)
            }
            if keys == Set(["Month", "Day", "Hour", "Minute"]), let once,
               strictInteger(components["Month"]) == once.month, strictInteger(components["Day"]) == once.day,
               hour == once.hour, minute == once.minute
            {
                return once
            }
            return nil
        }
        return JobSchedule(kind: .manual)
    }

    static func strictBool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    static func strictInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double.rounded() == double,
              double >= Double(Int32.min), double <= Double(Int32.max) else { return nil }
        return number.intValue
    }

    private static func isAlphanumeric(_ byte: UInt8) -> Bool {
        (48 ... 57).contains(byte) || (65 ... 90).contains(byte) || (97 ... 122).contains(byte)
    }

    private static func shellQuoteForDisplay(_ argument: String) -> String {
        if !argument.isEmpty, argument.utf8.allSatisfy({ isAlphanumeric($0) || [45, 46, 47, 95, 58].contains($0) }) {
            return argument
        }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
