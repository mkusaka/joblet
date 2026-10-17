import AppKit
import ServiceManagement
import SwiftUI

@MainActor
struct JobletSettingsView: View {
    var body: some View {
        Form {
            Section("Joblet") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                Text("Scheduled jobs for your Mac, from a small window.")
                    .foregroundStyle(.secondary)
            }

            Section("How it works") {
                Text("macOS runs your jobs, so they keep running after you quit Joblet. Jobs run only while you are logged in as the current user.")
                Text("Daily and weekly schedules follow this Mac's local time. Jobs may not run on time while the Mac sleeps or is powered off, or when the network is unavailable.")
                    .foregroundStyle(.secondary)
                Button("Open Background Items Settings") {
                    SMAppService.openSystemSettingsLoginItems()
                }
            }

            Section("Files") {
                Text("You can view the command and schedule of existing jobs. Editing and deleting in the form apply only to jobs created by Joblet.")
                    .foregroundStyle(.secondary)
                Button("Open LaunchAgents Folder") {
                    let url = FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
                    NSWorkspace.shared.open(url)
                }
                Text("Logs show the last 64 KiB. Logs are never deleted automatically; rotate them from your script if needed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 570)
    }
}
