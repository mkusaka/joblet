import Foundation
@testable import JobletCore
import XCTest

final class RepositoryTests: XCTestCase {
    func testEmptyRefreshDoesNotCreateDirectoriesOrRunCommands() async throws {
        let home = try TemporaryHome()
        let runner = InMemoryLaunchctl()
        let repository = JobRepository(homeDirectory: home.url, runner: runner)
        let snapshot = try await repository.listJobs()
        XCTAssertTrue(snapshot.jobs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.agents.path))
        let calls = await runner.calls()
        XCTAssertTrue(calls.isEmpty)
    }

    func testDisabledCreateDoesNotInvokeLaunchctlAndKeepsPrivateLogs() async throws {
        let home = try TemporaryHome()
        let runner = InMemoryLaunchctl()
        let repository = JobRepository(homeDirectory: home.url, runner: runner)
        let label = try await repository.create(JobDraft(name: "Disabled test", enabled: false))
        let calls = await runner.calls()
        XCTAssertTrue(calls.isEmpty)
        let snapshot = try await repository.listJobs()
        let job = try XCTUnwrap(snapshot.jobs.first)
        XCTAssertEqual(job.label, label)
        XCTAssertEqual(job.runtime.phase, .unloaded)
        XCTAssertEqual(job.runtime.isDisabled, true)
        XCTAssertEqual(job.draft?.enabled, false)
        XCTAssertTrue(job.isManaged)
        XCTAssertTrue(job.canEdit)
        let out = try XCTUnwrap(job.standardOutPath)
        XCTAssertEqual(try JobFileIO.read(URL(fileURLWithPath: out)).permissions, 0o600)
    }

    func testExternalJobCanRunButCannotEditOrDelete() async throws {
        let home = try TemporaryHome()
        let runner = InMemoryLaunchctl()
        let label = "homebrew.mxcl.postgresql@16"
        let path = try home.writePlist(["Label": label, "ProgramArguments": ["/bin/date"]], name: "external.plist")
        await runner.register(label, path: path.path)
        let repository = JobRepository(homeDirectory: home.url, runner: runner)
        let snapshot = try await repository.listJobs()
        let job = try XCTUnwrap(snapshot.jobs.first)
        XCTAssertTrue(job.canControl)
        XCTAssertFalse(job.canEdit)
        XCTAssertFalse(job.isManaged)
        await runner.clearCalls()
        await assertAsyncThrows { try await repository.update(job, draft: JobDraft(name: "Changed")) }
        await assertAsyncThrows { try await repository.delete(job) }
        let blockedCalls = await runner.calls()
        XCTAssertTrue(blockedCalls.isEmpty)
        try await repository.runNow(job)
        let calls = await runner.calls()
        XCTAssertEqual(calls.last?.first, "kickstart")
        XCTAssertEqual(calls.last?.dropFirst().first, "-p")
        XCTAssertFalse(calls.flatMap { $0 }.contains("-k"))
    }

    func testDuplicateLabelsStayVisibleAndCannotBeControlled() async throws {
        let home = try TemporaryHome()
        let runner = InMemoryLaunchctl()
        let dictionary: [String: Any] = ["Label": "example.duplicate", "ProgramArguments": ["/bin/date"]]
        let first = try home.writePlist(dictionary, name: "one.plist")
        try home.writePlist(dictionary, name: "two.plist")
        await runner.register("example.duplicate", path: first.path)
        let repository = JobRepository(homeDirectory: home.url, runner: runner)
        let snapshot = try await repository.listJobs()
        XCTAssertEqual(snapshot.jobs.count, 2)
        XCTAssertEqual(Set(snapshot.jobs.map(\.id)).count, 2)
        XCTAssertTrue(snapshot.jobs.allSatisfy { !$0.canControl })
        await runner.clearCalls()
        await assertAsyncThrows { try await repository.setEnabled(snapshot.jobs[0], enabled: false) }
        let calls = await runner.calls()
        XCTAssertTrue(calls.isEmpty)
    }

    func testLoadedPathMismatchBlocksActions() async throws {
        let home = try TemporaryHome()
        let runner = InMemoryLaunchctl()
        try home.writePlist(["Label": "example.path", "ProgramArguments": ["/bin/date"]], name: "path.plist")
        await runner.register("example.path", path: "/different/path.plist")
        let repository = JobRepository(homeDirectory: home.url, runner: runner)
        let snapshot = try await repository.listJobs()
        let job = try XCTUnwrap(snapshot.jobs.first)
        XCTAssertFalse(job.canControl)
        await runner.clearCalls()
        await assertAsyncThrows { try await repository.runNow(job) }
        let calls = await runner.calls()
        XCTAssertFalse(calls.contains { ["kickstart", "enable", "disable", "bootout", "bootstrap"].contains($0[0]) })
    }

    func testUnknownDisableFormatBlocksControl() async throws {
        let home = try TemporaryHome()
        let runner = InMemoryLaunchctl()
        let path = try home.writePlist(["Label": "example.unknown", "ProgramArguments": ["/bin/date"]], name: "unknown.plist")
        await runner.register("example.unknown", path: path.path)
        await runner.makeDisabledOutputUnknown()
        let repository = JobRepository(homeDirectory: home.url, runner: runner)
        let snapshot = try await repository.listJobs()
        let job = try XCTUnwrap(snapshot.jobs.first)
        XCTAssertFalse(job.canControl)
        XCTAssertNil(job.runtime.isEnabled)
        await runner.clearCalls()
        await assertAsyncThrows { try await repository.setEnabled(job, enabled: false) }
        let calls = await runner.calls()
        XCTAssertEqual(calls.map { $0[0] }, ["print-disabled"])
    }

    func testEnabledButUnregisteredDraftPreservesPersistentSetting() async throws {
        let home = try TemporaryHome()
        let runner = InMemoryLaunchctl()
        let repository = JobRepository(homeDirectory: home.url, runner: runner)
        let label = try await repository.create(JobDraft(name: "Persistent", enabled: false))
        await runner.setDisabled(false, label: label)
        let snapshot = try await repository.listJobs()
        let job = try XCTUnwrap(snapshot.jobs.first)
        XCTAssertEqual(job.runtime.phase, .unloaded)
        XCTAssertEqual(job.runtime.isEnabled, false)
        XCTAssertEqual(job.runtime.isDisabled, false)
        XCTAssertEqual(job.draft?.enabled, true)
    }

    func testStaleSnapshotAndRunningJobRejectUpdateBeforeMutation() async throws {
        let home = try TemporaryHome()
        let runner = InMemoryLaunchctl()
        let repository = JobRepository(homeDirectory: home.url, runner: runner)
        let label = try await repository.create(JobDraft(name: "Safe", enabled: false))
        let snapshot = try await repository.listJobs()
        let stale = try XCTUnwrap(snapshot.jobs.first)
        let revision = try JobFileIO.read(stale.plistURL)
        let changed = try JobPlist.encode(JobDraft(name: "External change", enabled: false), label: label, home: home.url)
        try JobFileIO.atomicWrite(changed, to: stale.plistURL, expecting: revision)
        await runner.clearCalls()
        await assertAsyncThrows { try await repository.update(stale, draft: JobDraft(name: "Stale", enabled: false)) }
        let staleCalls = await runner.calls()
        XCTAssertTrue(staleCalls.isEmpty)
        await runner.register(label, path: stale.plistURL.path, phase: .running)
        await runner.setDisabled(false, label: label)
        let refreshed = try await repository.listJobs()
        let running = try XCTUnwrap(refreshed.jobs.first)
        await runner.clearCalls()
        await assertAsyncThrows { try await repository.delete(running) }
        let calls = await runner.calls()
        XCTAssertFalse(calls.contains { ["disable", "bootout"].contains($0[0]) })
    }

    func testFailedDisableDoesNotReloadUnchangedWaitingJob() async throws {
        let home = try TemporaryHome()
        let runner = InMemoryLaunchctl()
        let repository = JobRepository(homeDirectory: home.url, runner: runner)
        _ = try await repository.create(JobDraft(name: "Original"))
        let snapshot = try await repository.listJobs()
        let job = try XCTUnwrap(snapshot.jobs.first)
        await runner.clearCalls()
        await runner.failNext("disable")
        await assertAsyncThrows { try await repository.update(job, draft: JobDraft(name: "Replacement")) }
        let calls = await runner.calls()
        XCTAssertFalse(calls.contains { ["bootout", "bootstrap"].contains($0[0]) })
        let persistent = await runner.disabledValue(job.label)
        XCTAssertEqual(persistent, false)
        XCTAssertEqual(try JobPlist.decode(Data(contentsOf: job.plistURL), home: home.url).name, "Original")
    }

    func testRaceStartedProcessIsNotKilledAndOverrideIsRestored() async throws {
        let home = try TemporaryHome()
        let runner = InMemoryLaunchctl()
        let repository = JobRepository(homeDirectory: home.url, runner: runner)
        _ = try await repository.create(JobDraft(name: "Race"))
        let snapshot = try await repository.listJobs()
        let job = try XCTUnwrap(snapshot.jobs.first)
        await runner.clearCalls()
        await runner.raceStartOnDisable()
        await assertAsyncThrows { try await repository.setEnabled(job, enabled: false) }
        let calls = await runner.calls()
        XCTAssertFalse(calls.contains { ["bootout", "bootstrap", "kickstart"].contains($0[0]) })
        let persistent = await runner.disabledValue(job.label)
        let service = await runner.service(job.label)
        XCTAssertEqual(persistent, false)
        XCTAssertEqual(service?.phase, .running)
    }

    func testFailedNewBootstrapRestoresOldBytesAndRegistration() async throws {
        let home = try TemporaryHome()
        let runner = InMemoryLaunchctl()
        let repository = JobRepository(homeDirectory: home.url, runner: runner)
        _ = try await repository.create(JobDraft(name: "Original"))
        let snapshot = try await repository.listJobs()
        let job = try XCTUnwrap(snapshot.jobs.first)
        let original = try Data(contentsOf: job.plistURL)
        await runner.clearCalls()
        await runner.failNext("bootstrap")
        await assertAsyncThrows { try await repository.update(job, draft: JobDraft(name: "Replacement")) }
        XCTAssertEqual(try Data(contentsOf: job.plistURL), original)
        let service = await runner.service(job.label)
        let disabled = await runner.disabledValue(job.label)
        // Foundation standardization maps /private/var to /var for temp directories.
        XCTAssertEqual(service.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path }, job.plistURL.standardizedFileURL.path)
        XCTAssertEqual(service?.phase, .waiting)
        XCTAssertEqual(disabled, false)
        let backups = home.url.appendingPathComponent("Library/Application Support/Joblet/Backups")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: backups.path).isEmpty)
    }

    func testDeletePreservesLogsAndOriginalPlistBackup() async throws {
        let home = try TemporaryHome()
        let runner = InMemoryLaunchctl()
        let repository = JobRepository(homeDirectory: home.url, runner: runner)
        _ = try await repository.create(JobDraft(name: "Delete", enabled: false))
        let snapshot = try await repository.listJobs()
        let job = try XCTUnwrap(snapshot.jobs.first)
        let original = try Data(contentsOf: job.plistURL)
        try await repository.delete(job)
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.plistURL.path))
        XCTAssertTrue(try FileManager.default.fileExists(atPath: XCTUnwrap(job.standardOutPath)))
        let backups = home.url.appendingPathComponent("Library/Application Support/Joblet/Backups")
        let urls = try FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)
        XCTAssertEqual(urls.count, 1)
        XCTAssertEqual(try Data(contentsOf: urls[0]), original)
    }
}
