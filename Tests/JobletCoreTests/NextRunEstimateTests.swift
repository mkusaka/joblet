import Foundation
@testable import JobletCore
import XCTest

final class NextRunEstimateTests: XCTestCase {
    private let lastRun = Date(timeIntervalSince1970: 1_800_000_000)

    private var home: TemporaryHome?

    private func makeJob(_ schedule: JobSchedule, enabled: Bool = true) async throws -> JobRepository {
        let home = try TemporaryHome()
        self.home = home
        let repository = JobRepository(homeDirectory: home.url, runner: InMemoryLaunchctl())
        _ = try await repository.create(JobDraft(name: "Estimate", schedule: schedule, enabled: enabled))
        return repository
    }

    private func onlyJob(_ repository: JobRepository) async throws -> LaunchJob {
        let jobs = try await repository.listJobs().jobs
        return try XCTUnwrap(jobs.first)
    }

    private func writeLog(_ path: String?, _ text: String, modified: Date) throws {
        let url = try URL(fileURLWithPath: XCTUnwrap(path))
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    func testIntervalEstimateIsNewestLogWritePlusInterval() async throws {
        let repository = try await makeJob(JobSchedule(kind: .interval, intervalMinutes: 30))
        let created = try await onlyJob(repository)
        try writeLog(created.standardOutPath, "out\n", modified: lastRun)
        try writeLog(created.standardErrorPath, "err\n", modified: lastRun.addingTimeInterval(60))
        let job = try await onlyJob(repository)
        XCTAssertEqual(job.lastLogWrite, lastRun.addingTimeInterval(60))
        XCTAssertEqual(job.nextRunEstimate(now: lastRun), lastRun.addingTimeInterval(60 + 30 * 60))
        // An overdue estimate stays in the past; the UI words it as due now instead of inventing a time.
        XCTAssertEqual(job.nextRunEstimate(now: lastRun.addingTimeInterval(86400)), lastRun.addingTimeInterval(60 + 30 * 60))
    }

    func testEmptyOrMissingLogsGiveNoIntervalEstimate() async throws {
        let repository = try await makeJob(JobSchedule(kind: .interval, intervalMinutes: 30))
        let created = try await onlyJob(repository)
        XCTAssertNil(created.lastLogWrite, "freshly created empty logs are not a run")
        XCTAssertNil(created.nextRunEstimate())
        try FileManager.default.removeItem(atPath: XCTUnwrap(created.standardOutPath))
        try FileManager.default.removeItem(atPath: XCTUnwrap(created.standardErrorPath))
        let job = try await onlyJob(repository)
        XCTAssertNil(job.lastLogWrite)
        XCTAssertNil(job.nextRunEstimate())
    }

    func testDisabledJobHasNoEstimate() async throws {
        let repository = try await makeJob(JobSchedule(kind: .interval, intervalMinutes: 30), enabled: false)
        let created = try await onlyJob(repository)
        try writeLog(created.standardOutPath, "out\n", modified: lastRun)
        let job = try await onlyJob(repository)
        XCTAssertEqual(job.lastLogWrite, lastRun)
        XCTAssertNil(job.nextRunEstimate(now: lastRun))
    }

    func testCalendarEstimateFollowsTheRule() async throws {
        let repository = try await makeJob(JobSchedule(kind: .daily, hour: 9, minute: 30))
        let job = try await onlyJob(repository)
        let now = Date()
        XCTAssertNotNil(job.nextRunEstimate(now: now))
        XCTAssertEqual(job.nextRunEstimate(now: now), job.schedule?.nextCalendarRun(after: now))
    }
}
