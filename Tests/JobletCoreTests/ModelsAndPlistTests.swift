import Foundation
@testable import JobletCore
import XCTest

final class ModelsAndPlistTests: XCTestCase {
    private let label = "local.joblet.67b7e4c8-7f4a-4323-9de8-1bc0a221b430"
    private let home = URL(fileURLWithPath: "/Users/tester")

    func testValidationRejectsNULAndInvalidSchedules() {
        XCTAssertThrowsError(try JobDraft(name: "Test", command: "date\0pwd").validate())
        XCTAssertThrowsError(try JobDraft(name: "Test", schedule: JobSchedule(kind: .interval, intervalMinutes: 0)).validate())
        XCTAssertThrowsError(try JobDraft(name: "Test", schedule: JobSchedule(kind: .weekly, hour: 25)).validate())
        XCTAssertThrowsError(try JobDraft(name: "Test", workingDirectory: "relative/path").validate())
        XCTAssertNoThrow(try JobDraft(name: "Test", command: "echo '$HOME'; date", workingDirectory: "~/work").validate())
    }

    func testNextCalendarRunUsesLaunchdSundayZeroConvention() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let formatter = ISO8601DateFormatter()
        let after = try XCTUnwrap(formatter.date(from: "2026-10-17T12:00:00Z"))
        let schedule = JobSchedule(kind: .weekly, hour: 9, minute: 15, weekday: 0)
        XCTAssertEqual(schedule.nextCalendarRun(after: after, calendar: calendar), formatter.date(from: "2026-10-18T09:15:00Z"))
        XCTAssertNil(JobSchedule(kind: .interval).nextCalendarRun(after: after))
        XCTAssertNil(JobSchedule(kind: .manual).nextCalendarRun(after: after))
    }

    func testUnknownAndUnloadedNeverAppearActive() {
        XCTAssertNil(JobRuntime(phase: .unknown, isDisabled: false).isEnabled)
        XCTAssertNil(JobRuntime(phase: .waiting, isDisabled: nil).isEnabled)
        XCTAssertEqual(JobRuntime(phase: .unloaded, isDisabled: false).isEnabled, false)
        XCTAssertEqual(JobRuntime(phase: .waiting, isDisabled: false).isEnabled, true)
        XCTAssertEqual(JobRuntime(phase: .running, isDisabled: true).isEnabled, false)
    }

    func testAllCanonicalSchedulesRoundTrip() throws {
        for kind in ScheduleKind.allCases {
            let input = JobDraft(name: "Nightly export", command: "printf '%s\\n' \"$HOME\"",
                                 workingDirectory: home.path,
                                 schedule: JobSchedule(kind: kind, intervalMinutes: 37, hour: 18, minute: 23, weekday: 5),
                                 runAtLoad: true, enabled: false)
            let data = try JobPlist.encode(input, label: label, home: home)
            let decoded = try JobPlist.decode(data, home: home)
            XCTAssertTrue(decoded.isCanonical)
            XCTAssertEqual(decoded.draft?.command, input.command)
            XCTAssertEqual(decoded.draft?.schedule.kind, kind)
            XCTAssertEqual(decoded.draft?.enabled, false)
            XCTAssertEqual(decoded.stdout, home.path + "/Library/Application Support/Joblet/Logs/\(label)/stdout.log")
            XCTAssertEqual(decoded.stderr, home.path + "/Library/Application Support/Joblet/Logs/\(label)/stderr.log")
            let dictionary = try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any])
            XCTAssertNil(dictionary["AssociatedBundleIdentifiers"])
            XCTAssertEqual(Set(dictionary.keys).subtracting(["StartInterval", "StartCalendarInterval"]).count, 9)
        }
    }

    func testPrefixOrMarkerAloneDoesNotGrantEditPermission() throws {
        let plain: [String: Any] = ["Label": label, "ProgramArguments": ["/bin/date"]]
        let data = try PropertyListSerialization.data(fromPropertyList: plain, format: .xml, options: 0)
        XCTAssertFalse(try JobPlist.decode(data, home: home).isCanonical)
        var canonical = try canonicalDictionary()
        canonical["ProgramArguments"] = ["/bin/sh", "-c", "date"]
        XCTAssertFalse(try decode(canonical).isCanonical)
        canonical = try canonicalDictionary()
        canonical["Comment"] = "Joblet/v2: Test"
        XCTAssertFalse(try decode(canonical).isCanonical)
    }

    func testUnsupportedKeysAndLogPathsAreNeverSilentlyRoundTripped() throws {
        var dictionary = try canonicalDictionary()
        dictionary["KeepAlive"] = true
        XCTAssertNil(try decode(dictionary).draft)
        dictionary = try canonicalDictionary()
        dictionary["StandardOutPath"] = "/tmp/unrelated.log"
        XCTAssertNil(try decode(dictionary).draft)
        dictionary = try canonicalDictionary()
        dictionary["EnvironmentVariables"] = ["PATH": JobPlist.commandPath, "CUSTOM": "preserve-me"]
        XCTAssertNil(try decode(dictionary).draft)
    }

    func testBooleanCannotMasqueradeAsIntervalOrCalendarNumber() {
        XCTAssertNil(JobPlist.strictInteger(true))
        XCTAssertNil(JobPlist.strictBool(NSNumber(value: 1)))
        XCTAssertNil(JobPlist.parseSchedule(["StartInterval": true]))
        XCTAssertNil(JobPlist.parseSchedule(["StartCalendarInterval": ["Hour": true, "Minute": 0]]))
        XCTAssertNil(JobPlist.parseSchedule(["StartCalendarInterval": [["Hour": 9, "Minute": 0]]]))
    }

    func testProgramAndArgvZeroAreDisplayedWithoutInventingShellInvocation() throws {
        let decoded = try decode(["Label": "example.external", "Program": "/bin/sleep", "ProgramArguments": ["custom-argv-zero", "1"]])
        XCTAssertEqual(decoded.command, "Program: /bin/sleep\nProgramArguments: custom-argv-zero 1")
    }

    private func canonicalDictionary() throws -> [String: Any] {
        let data = try JobPlist.encode(JobDraft(name: "Test", workingDirectory: home.path), label: label, home: home)
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any])
    }

    private func decode(_ dictionary: [String: Any]) throws -> DecodedJobPlist {
        let data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
        return try JobPlist.decode(data, home: home)
    }
}
