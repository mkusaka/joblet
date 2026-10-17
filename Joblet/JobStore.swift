import AppKit
import Combine
import Foundation
import JobletCore

@MainActor
final class JobStore: ObservableObject {
    @Published var jobs: [LaunchJob] = []
    @Published var warnings: [String] = []
    @Published var selectedID: String?
    @Published var isBusy = false
    @Published var errorMessage: String?
    @Published var lastRefreshed: Date?

    private let repository: JobRepository
    private var prepare: (() async -> Void)?

    /// `prepare` runs once before the first load (used to seed fixtures in UI-test mode).
    init(repository: JobRepository = JobRepository(), prepare: (() async -> Void)? = nil) {
        self.repository = repository
        self.prepare = prepare
    }

    var selectedJob: LaunchJob? {
        jobs.first { $0.id == selectedID }
    }

    func refresh() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        if let prepare {
            self.prepare = nil
            await prepare()
        }
        do {
            try await reload()
        } catch {
            errorMessage = "Could not refresh the job list.\n\(error.localizedDescription)"
        }
    }

    func save(_ draft: JobDraft, editing job: LaunchJob?) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try draft.validate()
            let savedLabel: String
            if let job {
                try await repository.update(job, draft: draft)
                savedLabel = job.label
            } else {
                savedLabel = try await repository.create(draft)
            }
            await reloadAfterMutation()
            selectedID = jobs.first { $0.label == savedLabel }?.id ?? selectedID
            return true
        } catch {
            errorMessage = error.localizedDescription
            // Reload after a partial failure as well, so displayed controls do
            // not continue to reflect the pre-operation registration state.
            await reloadAfterMutation()
            return false
        }
    }

    func setEnabled(_ job: LaunchJob, enabled: Bool) async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try await repository.setEnabled(job, enabled: enabled)
        } catch {
            errorMessage = error.localizedDescription
        }
        await reloadAfterMutation()
    }

    func runNow(_ job: LaunchJob) async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try await repository.runNow(job)
        } catch {
            errorMessage = error.localizedDescription
        }
        await reloadAfterMutation()
    }

    func delete(_ job: LaunchJob) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try await repository.delete(job)
            if selectedID == job.id { selectedID = nil }
            await reloadAfterMutation()
            return true
        } catch {
            errorMessage = error.localizedDescription
            await reloadAfterMutation()
            return false
        }
    }

    func log(for job: LaunchJob, stream: LogStream) async -> String {
        do {
            return try await repository.readLog(for: job, stream: stream)
        } catch {
            return "Could not read the log.\n\(error.localizedDescription)"
        }
    }

    func plist(for job: LaunchJob) async -> String {
        do {
            return try await repository.plistText(for: job)
        } catch {
            return "Could not read the plist.\n\(error.localizedDescription)"
        }
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openLogsFolder(for job: LaunchJob) {
        guard let path = job.standardOutPath ?? job.standardErrorPath else { return }
        guard path.hasPrefix("/"), !path.contains("\0") else {
            errorMessage = "The log destination is not an absolute path. Check the output paths in the plist."
            return
        }
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: url.path) {
            reveal(url)
        } else if !NSWorkspace.shared.open(url.deletingLastPathComponent()) {
            errorMessage = "Could not open the log folder. Try again after the first run."
        }
    }

    private func reload() async throws {
        let isInitialLoad = lastRefreshed == nil
        let snapshot = try await repository.listJobs()
        jobs = snapshot.jobs
        warnings = snapshot.warnings
        lastRefreshed = Date()
        if let selectedID, !jobs.contains(where: { $0.id == selectedID }) {
            self.selectedID = nil
        }
        if isInitialLoad, selectedID == nil { selectedID = jobs.first?.id }
    }

    private func reloadAfterMutation() async {
        do {
            try await reload()
        } catch {
            let explanation = "Could not reload the state after the operation. Refresh to check.\n\(error.localizedDescription)"
            if let previousError = errorMessage {
                errorMessage = previousError + "\n\n" + explanation
            } else {
                errorMessage = explanation
            }
        }
    }
}
