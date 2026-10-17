import AppKit
import JobletCore
import JobletSparkle
import SwiftUI

@MainActor
struct MenuBarView: View {
    let updater: SparkleUpdater
    @EnvironmentObject private var store: JobStore
    @Environment(\.openWindow) private var openWindow

    private var managedJobs: [LaunchJob] {
        store.jobs.filter(\.isManaged)
    }

    private var runningCount: Int {
        managedJobs.filter { $0.runtime.phase == .running }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Joblet").font(.headline)
                    Text("\(managedJobs.count) jobs · \(runningCount) running")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await store.refresh() }
                } label: {
                    if store.isBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise").labelStyle(.iconOnly)
                    }
                }
                .buttonStyle(.plain)
                .disabled(store.isBusy)
                .help("Refresh")
            }

            Divider()

            if store.isBusy && store.jobs.isEmpty {
                Text("Loading jobs…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else if managedJobs.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Register your first job.")
                        .font(.callout.weight(.medium))
                    Text("Pick a command and leave the rest to macOS.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            } else {
                VStack(spacing: 4) {
                    ForEach(Array(managedJobs.prefix(5))) { job in
                        Button {
                            store.selectedID = job.id
                            showMainWindow()
                        } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(job.name)
                                        .font(.callout.weight(.medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(nextRunText(job))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 6)
                                JobStatusBadge(runtime: job.runtime)
                            }
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Open details for \(job.name)")
                    }
                }

                if managedJobs.count > 5 {
                    Text("\(managedJobs.count - 5) more in the main window")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !store.warnings.isEmpty || store.errorMessage != nil {
                Label("Some items need attention", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Divider()

            Button(action: showMainWindow) {
                HStack {
                    Text("Open Joblet")
                    Spacer()
                    Image(systemName: "arrow.up.forward.app")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            HStack {
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .buttonStyle(.borderless)
                Spacer()
                Button("Check for Updates…") { updater.checkForUpdates(nil) }
                    .buttonStyle(.borderless)
                    .disabled(AppEnvironment.isUITesting)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.borderless)
                    .help("Quit Joblet. Registered jobs keep running under macOS.")
            }
            .font(.caption)
        }
        .padding(16)
        .frame(width: 320)
    }

    private func nextRunText(_ job: LaunchJob) -> String {
        guard job.runtime.isEnabled == true, let next = job.schedule?.nextCalendarRun() else {
            return job.scheduleDescription
        }
        return "Next: \(calendarEstimateText(next))"
    }

    private func showMainWindow() {
        openWindow(id: "main")
        NSApplication.shared.activate()
    }
}
