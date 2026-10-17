import Foundation
import JobletCore

/// The single place where the JobStore's repository is constructed.
/// With `-ui-testing` (or `JOBLET_UI_TESTING=1`) the app uses a fresh temporary home and an
/// in-memory launchctl, so UI tests never touch the real launchd domain or ~/Library/LaunchAgents.
@MainActor
enum AppEnvironment {
    static var isUITesting: Bool {
        CommandLine.arguments.contains("-ui-testing")
            || ProcessInfo.processInfo.environment["JOBLET_UI_TESTING"] == "1"
    }

    static func makeStore() -> JobStore {
        guard isUITesting else { return JobStore() }
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("joblet-ui-testing-\(UUID().uuidString)", isDirectory: true)
        let launchctl = InMemoryLaunchctl()
        let repository = JobRepository(homeDirectory: home, runner: launchctl)
        return JobStore(repository: repository) {
            await seedFixtures(repository: repository, launchctl: launchctl, home: home)
        }
    }

    /// Two Joblet jobs (one enabled, one disabled) and one existing, non-Joblet LaunchAgent.
    private static func seedFixtures(repository: JobRepository, launchctl: InMemoryLaunchctl, home: URL) async {
        _ = try? await repository.create(JobDraft(name: "Nightly Backup", command: "echo backup",
                                                  schedule: JobSchedule(kind: .daily, hour: 2, minute: 0)))
        _ = try? await repository.create(JobDraft(name: "Paused Cleanup", command: "echo cleanup",
                                                  schedule: JobSchedule(kind: .interval, intervalMinutes: 30),
                                                  enabled: false))
        let label = "com.example.existing-agent"
        let url = home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
        let plist: [String: Any] = ["Label": label, "ProgramArguments": ["/bin/echo", "existing"], "StartInterval": 3600]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0),
              FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
        else { return }
        await launchctl.setDisabled(false, label: label)
        await launchctl.register(label, path: url.path)
    }
}
