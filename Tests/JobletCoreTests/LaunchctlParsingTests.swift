@testable import JobletCore
import XCTest

final class LaunchctlParsingTests: XCTestCase {
    func testDisabledTableDistinguishesFalseFromMissingAndUnknown() throws {
        let table = try XCTUnwrap(LaunchctlClient.parseDisabledTable("disabled services = {\n\"one\" => false\n\"two\" => true\n}"))
        XCTAssertEqual(table.values["one"], false)
        XCTAssertEqual(table.values["two"], true)
        XCTAssertNil(table.values["absent"])
        XCTAssertNil(LaunchctlClient.parseDisabledTable("permission denied"))
        XCTAssertNil(LaunchctlClient.parseDisabledTable("disabled services = {\n\"one\" => maybe\n}"))
        XCTAssertNil(LaunchctlClient.parseDisabledTable("disabled services = {\n\"one\" => true\n\"one\" => false\n}"))
    }

    func testNestedStateAndPidNeverOverrideTopLevelStatus() {
        let text = """
        gui/501/example = {
            path = /Users/tester/Library/LaunchAgents/example.plist
            state = not running
            nested = {
                state = running
                pid = 9999
            }
            last exit code = 78: EX_CONFIG
        }
        """
        let probe = LaunchctlClient.parseProbe(CommandResult(exitCode: 0, stdout: text, stderr: ""), label: "example", disabled: false)
        XCTAssertEqual(probe.runtime.phase, .waiting)
        XCTAssertNil(probe.runtime.pid)
        XCTAssertEqual(probe.runtime.lastExitCode, 78)
        XCTAssertEqual(probe.loadedPath, "/Users/tester/Library/LaunchAgents/example.plist")
    }

    func testOnlyExplicitMissingServiceIsUnloaded() {
        let absent = CommandResult(exitCode: 113, stdout: "", stderr: "Could not find service \"example\" in domain for user gui: 501")
        XCTAssertEqual(LaunchctlClient.parseProbe(absent, label: "example", disabled: false).runtime.phase, .unloaded)
        let denied = CommandResult(exitCode: 113, stdout: "", stderr: "Operation not permitted")
        XCTAssertEqual(LaunchctlClient.parseProbe(denied, label: "example", disabled: false).runtime.phase, .unknown)
        XCTAssertEqual(LaunchctlClient.parseProbe(absent, label: "another", disabled: false).runtime.phase, .unknown)
    }

    func testMissingPidUnknownStateAndTruncatedOutputStayUnknown() {
        for text in ["gui/501/example = {\nstate = running\n}", "gui/501/example = {\nstate = future-state\n}", ""] {
            let probe = LaunchctlClient.parseProbe(CommandResult(exitCode: 0, stdout: text, stderr: ""), label: "example", disabled: nil)
            XCTAssertEqual(probe.runtime.phase, .unknown)
            XCTAssertNil(probe.runtime.isEnabled)
        }
        let truncated = CommandResult(exitCode: 0, stdout: "gui/501/example = {\nstate = not running\n}", stderr: "", wasTruncated: true)
        XCTAssertEqual(LaunchctlClient.parseProbe(truncated, label: "example", disabled: false).runtime.phase, .unknown)
    }

    func testRunningRequiresPositiveTopLevelPid() {
        let result = CommandResult(exitCode: 0, stdout: "gui/501/example = {\npath = /tmp/example.plist\nstate = running\npid = 123\n}", stderr: "")
        let probe = LaunchctlClient.parseProbe(result, label: "example", disabled: false)
        XCTAssertEqual(probe.runtime.phase, .running)
        XCTAssertEqual(probe.runtime.pid, 123)
    }
}
