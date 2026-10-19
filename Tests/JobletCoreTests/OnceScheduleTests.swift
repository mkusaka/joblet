import Foundation
@testable import JobletCore
import XCTest

final class OnceScheduleTests: XCTestCase {
    private let label = "local.joblet.67b7e4c8-7f4a-4323-9de8-1bc0a221b430"
    private let home = URL(fileURLWithPath: "/Users/tester")
    private let trickyCommands = [
        #"echo "it's $HOME"; printf '%s\n' 'a;b' "$(echo nested)""#,
        "echo first\necho second; exit 7",
        #"echo '"; /bin/launchctl bootout gui/0/x; echo "'"#,
        "echo $1 $2 \\$UID `echo backtick` && false",
    ]

    private func once(_ text: String) throws -> JobSchedule {
        try XCTUnwrap(JobSchedule.once(text))
    }

    private func dictionary(_ draft: JobDraft) throws -> [String: Any] {
        let data = try JobPlist.encode(draft, label: label, home: home)
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any])
    }

    private func decode(_ dictionary: [String: Any]) throws -> DecodedJobPlist {
        let data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
        return try JobPlist.decode(data, home: home)
    }

    func testOnceDateParsingIsStrict() throws {
        let schedule = try once("2031-02-28T07:05")
        XCTAssertEqual([schedule.year, schedule.month, schedule.day, schedule.hour, schedule.minute], [2031, 2, 28, 7, 5])
        XCTAssertEqual(schedule.onceDateText, "2031-02-28T07:05")
        XCTAssertEqual(schedule.summary, "Once on 2031-02-28 at 07:05")
        for bad in ["2031-02-28T7:05", "2031-02-28 07:05", "2031-02-28T07:05:00", "+031-02-28T07:05",
                    "2031-2-028T07:05", "2031-02-28T07:5 ", "２０３１-02-28T07:05", ""]
        {
            XCTAssertNil(JobSchedule.once(bad), bad)
        }
        XCTAssertThrowsError(try once("2031-02-30T07:05").validate(), "a date that does not exist is invalid")
        XCTAssertThrowsError(try once("2031-13-01T07:05").validate())
        XCTAssertThrowsError(try once("2031-02-28T24:00").validate())
        XCTAssertNoThrow(try once("2032-02-29T07:05").validate())
    }

    func testOnceCannotAlsoRunAtLoad() throws {
        XCTAssertThrowsError(try JobDraft(name: "Once", schedule: once("2031-02-28T07:05"), runAtLoad: true).validate())
    }

    func testOnceRoundTripsWithTheCommandAsItsOwnArgument() throws {
        for command in trickyCommands {
            let draft = try JobDraft(name: "Once: \"quoted\"", command: command, workingDirectory: home.path,
                                     schedule: once("2031-02-28T07:05"), enabled: true)
            let plist = try dictionary(draft)
            let arguments = try XCTUnwrap(plist["ProgramArguments"] as? [String])
            XCTAssertEqual(arguments, ["/bin/zsh", "-c", JobPlist.onceScript(label: label), "joblet-once", "2031-02-28T07:05", command])
            XCTAssertFalse(arguments[2].contains(command), "the user command is never spliced into the script")
            XCTAssertEqual(plist["StartCalendarInterval"] as? [String: Int], ["Month": 2, "Day": 28, "Hour": 7, "Minute": 5])
            let decoded = try decode(plist)
            XCTAssertTrue(decoded.isCanonical)
            XCTAssertEqual(decoded.draft, draft)
            XCTAssertEqual(decoded.command, command, "the detail view shows the user command, not the wrapper")
            XCTAssertEqual(decoded.scheduleDescription, "Once on 2031-02-28 at 07:05")
        }
    }

    /// Runs the real wrapper text under zsh with launchctl swapped for `print`, so nothing reaches launchd.
    func testWrapperRunsTrickyCommandsVerbatimThenRemovesItself() throws {
        let year = Calendar.current.component(.year, from: Date())
        let script = JobPlist.onceScript(label: label).replacingOccurrences(of: "/bin/launchctl", with: "print -r -- LAUNCHCTL")
        guard !script.contains("launchctl") else { return XCTFail("launchctl must not be reachable from this test") }
        for command in trickyCommands {
            let expected = try run(["-c", command])
            let wrapped = try run(["-c", script, "joblet-once", "\(year)-12-31T23:59", command])
            let uid = getuid()
            XCTAssertEqual(wrapped.output, expected.output
                + "joblet: one-time run finished with exit status \(expected.status)\n"
                + "LAUNCHCTL disable gui/\(uid)/\(label)\nLAUNCHCTL bootout gui/\(uid)/\(label)\n")
        }
        let skipped = try run(["-c", script, "joblet-once", "\(year + 1)-01-01T00:00", "echo must-not-run"])
        XCTAssertFalse(skipped.output.contains("must-not-run"))
        XCTAssertTrue(skipped.output.hasPrefix("joblet: skipped; this one-time run was scheduled for \(year + 1)-01-01T00:00\n"))
        XCTAssertTrue(skipped.output.contains("LAUNCHCTL bootout gui/"))
    }

    func testHandMadePlistsCannotMasqueradeAsOnce() throws {
        let draft = try JobDraft(name: "Once", workingDirectory: home.path, schedule: once("2031-02-28T07:05"))
        let canonical = try dictionary(draft)
        var plain = canonical
        plain["ProgramArguments"] = ["/bin/zsh", "-c", "date"]
        var otherLabel = canonical
        otherLabel["ProgramArguments"] = ["/bin/zsh", "-c", JobPlist.onceScript(label: "local.joblet.00000000-0000-0000-0000-000000000000"),
                                          "joblet-once", "2031-02-28T07:05", "date"]
        var mismatchedDate = canonical
        mismatchedDate["StartCalendarInterval"] = ["Month": 3, "Day": 28, "Hour": 7, "Minute": 5]
        var daily = canonical
        daily["StartCalendarInterval"] = ["Hour": 7, "Minute": 5]
        var badDate = canonical
        badDate["ProgramArguments"] = ["/bin/zsh", "-c", JobPlist.onceScript(label: label), "joblet-once", "2031-02-28 07:05", "date"]
        var extraArgument = canonical
        extraArgument["ProgramArguments"] = (canonical["ProgramArguments"] as? [String] ?? []) + ["extra"]
        var withYear = canonical
        withYear["StartCalendarInterval"] = ["Year": 2031, "Month": 2, "Day": 28, "Hour": 7, "Minute": 5]
        for (name, value) in ["plain zsh": plain, "other label": otherLabel, "mismatched date": mismatchedDate,
                              "daily calendar": daily, "bad date": badDate, "extra argument": extraArgument,
                              "unknown calendar key": withYear]
        {
            let decoded = try decode(value)
            XCTAssertFalse(decoded.isCanonical, name)
            XCTAssertNil(decoded.schedule, name)
            XCTAssertEqual(decoded.scheduleDescription, "Custom launch conditions", name)
        }
    }

    private func run(_ arguments: [String]) throws -> (output: String, status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": home.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(decoding: data, as: UTF8.self), process.terminationStatus)
    }

    private func firstJob(_ repository: JobRepository) async throws -> LaunchJob {
        let jobs = try await repository.listJobs().jobs
        return try XCTUnwrap(jobs.first)
    }

    private func futureOnce(addingDays days: Int = 1) throws -> JobSchedule {
        var schedule = JobSchedule(kind: .once)
        let date = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: days, to: Date()))
        schedule.setOnceDate(date)
        return schedule
    }

    func testRepositoryRejectsPastDatesAtCreateAndUpdate() async throws {
        let temp = try TemporaryHome()
        let runner = InMemoryLaunchctl()
        let repository = JobRepository(homeDirectory: temp.url, runner: runner)
        let past = try futureOnce(addingDays: -1)
        await assertAsyncThrows { try await repository.create(JobDraft(name: "Late", schedule: past)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.agents.path))
        let calls = await runner.calls()
        XCTAssertTrue(calls.isEmpty)

        let schedule = try futureOnce()
        let label = try await repository.create(JobDraft(name: "Soon", schedule: schedule))
        let job = try await firstJob(repository)
        XCTAssertEqual(job.label, label)
        XCTAssertEqual(job.runtime.phase, .waiting)
        XCTAssertTrue(job.canEdit)
        XCTAssertEqual(job.draft?.schedule, schedule)
        XCTAssertEqual(job.nextRunEstimate(), schedule.onceDate())
        XCTAssertFalse(job.isOnceDone)
        var draft = try XCTUnwrap(job.draft)
        draft.schedule = past
        await assertAsyncThrows { try await repository.update(job, draft: draft) }
    }

    func testSelfRemovedJobIsDoneAndNeedsANewDateToEnable() async throws {
        let temp = try TemporaryHome()
        let runner = InMemoryLaunchctl()
        let repository = JobRepository(homeDirectory: temp.url, runner: runner)
        // A finished job carries a date that has passed, which only an earlier save could have written.
        let past = try futureOnce(addingDays: -1)
        let data = try JobPlist.encode(JobDraft(name: "Ran", schedule: past), label: label, home: temp.url)
        try temp.writePlist(XCTUnwrap(PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]),
                            name: label + ".plist")
        // What the wrapper does after the run: disable, bootout, and its status line in the log.
        await runner.setDisabled(true, label: label)
        let logs = JobPlist.logsDirectory(home: temp.url, label: label)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let stdout = logs.appendingPathComponent("stdout.log")
        XCTAssertTrue(FileManager.default.createFile(atPath: stdout.path, contents: Data("joblet: one-time run finished with exit status 0\n".utf8),
                                                     attributes: [.posixPermissions: 0o600]))
        let runAt = try XCTUnwrap(past.onceDate()).addingTimeInterval(20)
        try FileManager.default.setAttributes([.modificationDate: runAt], ofItemAtPath: stdout.path)

        let job = try await firstJob(repository)
        XCTAssertTrue(job.canEdit)
        XCTAssertEqual(job.runtime.phase, .unloaded)
        XCTAssertTrue(job.isOnceDone)
        XCTAssertNil(job.nextRunEstimate())
        XCTAssertEqual(job.draft?.enabled, false)
        await runner.clearCalls()
        await assertAsyncThrows { try await repository.setEnabled(job, enabled: true) }
        let calls = await runner.calls()
        XCTAssertFalse(calls.contains { $0.first == "enable" || $0.first == "bootstrap" })

        var draft = try XCTUnwrap(job.draft)
        draft.schedule = try futureOnce()
        draft.enabled = true
        try await repository.update(job, draft: draft)
        let rescheduled = try await firstJob(repository)
        XCTAssertEqual(rescheduled.runtime.phase, .waiting)
        XCTAssertFalse(rescheduled.isOnceDone)
    }

    func testUnloadedWithoutARunAfterTheDateIsNotDone() async throws {
        let temp = try TemporaryHome()
        let runner = InMemoryLaunchctl()
        let repository = JobRepository(homeDirectory: temp.url, runner: runner)
        let schedule = try futureOnce()
        _ = try await repository.create(JobDraft(name: "Paused", schedule: schedule, enabled: false))
        let created = try await firstJob(repository)
        let stdout = try XCTUnwrap(created.standardOutPath)
        try Data("older output\n".utf8).write(to: URL(fileURLWithPath: stdout))
        try FileManager.default.setAttributes([.modificationDate: XCTUnwrap(schedule.onceDate()).addingTimeInterval(-60)], ofItemAtPath: stdout)
        let job = try await firstJob(repository)
        XCTAssertEqual(job.runtime.phase, .unloaded)
        XCTAssertFalse(job.isOnceDone)
    }
}
