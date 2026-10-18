import Foundation
@testable import JobletCore
import XCTest

final class GroupTests: XCTestCase {
    func testGroupPersistsAcrossRepositoriesAndClears() async throws {
        let home = try TemporaryHome()
        let runner = InMemoryLaunchctl()
        let repository = JobRepository(homeDirectory: home.url, runner: runner)
        let label = try await repository.create(JobDraft(name: "Grouped", enabled: false))
        let job = try await firstJob(repository)
        XCTAssertNil(job.group)
        try await repository.setGroup(job, group: "  Backups  ")
        let reopened = JobRepository(homeDirectory: home.url, runner: runner)
        let grouped = try await firstJob(reopened)
        XCTAssertEqual(grouped.label, label)
        XCTAssertEqual(grouped.group, "Backups")
        XCTAssertEqual(try JobFileIO.read(groupsFile(home)).permissions, 0o600)
        try await reopened.setGroup(grouped, group: nil)
        let cleared = try await reopened.listJobs()
        XCTAssertNil(cleared.jobs.first?.group)
        XCTAssertTrue(cleared.warnings.isEmpty)
    }

    func testExternalJobCanBeGroupedWithoutTouchingItsPlistOrLaunchd() async throws {
        let home = try TemporaryHome()
        let runner = InMemoryLaunchctl()
        let label = "com.example.external"
        let path = try home.writePlist(["Label": label, "ProgramArguments": ["/bin/date"]], name: "external.plist")
        await runner.register(label, path: path.path)
        let before = try Data(contentsOf: path)
        let repository = JobRepository(homeDirectory: home.url, runner: runner)
        let job = try await firstJob(repository)
        await runner.clearCalls()
        try await repository.setGroup(job, group: "Third party")
        let calls = await runner.calls()
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(try Data(contentsOf: path), before)
        let listed = try await repository.listJobs()
        XCTAssertEqual(listed.jobs.first?.group, "Third party")
    }

    func testInvalidNamesAndStaleJobsAreRejected() async throws {
        let home = try TemporaryHome()
        let repository = JobRepository(homeDirectory: home.url, runner: InMemoryLaunchctl())
        _ = try await repository.create(JobDraft(name: "Job", enabled: false))
        let job = try await firstJob(repository)
        for name in ["", "   ", String(repeating: "x", count: 41), "a\nb"] {
            await assertAsyncThrows { try await repository.setGroup(job, group: name) }
        }
        try await repository.setGroup(job, group: String(repeating: "x", count: 40))
        try FileManager.default.removeItem(at: job.plistURL)
        await assertAsyncThrows { try await repository.setGroup(job, group: "Gone") }
    }

    func testDeleteRemovesEntryAndWritesPruneMissingLabels() async throws {
        let home = try TemporaryHome()
        let repository = JobRepository(homeDirectory: home.url, runner: InMemoryLaunchctl())
        let first = try await repository.create(JobDraft(name: "A", enabled: false))
        let second = try await repository.create(JobDraft(name: "B", enabled: false))
        for job in try await repository.listJobs().jobs {
            try await repository.setGroup(job, group: "G")
        }
        let deleted = try await firstJob(repository, label: first)
        try await repository.delete(deleted)
        XCTAssertEqual(try storedGroups(home), [second: "G"])

        try JSONEncoder().encode([second: "G", "local.joblet.vanished": "Old"]).write(to: groupsFile(home))
        let remaining = try await firstJob(repository)
        try await repository.setGroup(remaining, group: "H")
        XCTAssertEqual(try storedGroups(home), [second: "H"])
    }

    func testCorruptFileIsAWarningOnListAndIsNeverOverwritten() async throws {
        let home = try TemporaryHome()
        let repository = JobRepository(homeDirectory: home.url, runner: InMemoryLaunchctl())
        _ = try await repository.create(JobDraft(name: "Job", enabled: false))
        let corrupt = Data("{not json".utf8)
        try corrupt.write(to: groupsFile(home))
        let snapshot = try await repository.listJobs()
        XCTAssertEqual(snapshot.jobs.count, 1)
        XCTAssertNil(snapshot.jobs.first?.group)
        XCTAssertTrue(snapshot.warnings.contains { $0.contains("groups.json") })
        let job = try XCTUnwrap(snapshot.jobs.first)
        await assertAsyncThrows { try await repository.setGroup(job, group: "G") }
        try await repository.delete(job)
        XCTAssertEqual(try Data(contentsOf: groupsFile(home)), corrupt)
    }

    func testListingWithoutGroupsCreatesNoDataFiles() async throws {
        let home = try TemporaryHome()
        try home.writePlist(["Label": "com.example.x", "ProgramArguments": ["/bin/date"]], name: "x.plist")
        let snapshot = try await JobRepository(homeDirectory: home.url, runner: InMemoryLaunchctl()).listJobs()
        XCTAssertNil(snapshot.jobs.first?.group)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.url.appendingPathComponent("Library/Application Support").path))
    }

    private func groupsFile(_ home: TemporaryHome) -> URL {
        home.url.appendingPathComponent("Library/Application Support/Joblet/groups.json")
    }

    private func firstJob(_ repository: JobRepository, label: String? = nil) async throws -> LaunchJob {
        let jobs = try await repository.listJobs().jobs
        return try XCTUnwrap(jobs.first { label == nil || $0.label == label })
    }

    private func storedGroups(_ home: TemporaryHome) throws -> [String: String] {
        try JSONDecoder().decode([String: String].self, from: Data(contentsOf: groupsFile(home)))
    }
}
