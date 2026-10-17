import AppKit
import ServiceManagement
import SwiftUI

@MainActor
struct JobletSettingsView: View {
    @ObservedObject var launchAtLogin: LaunchAtLogin

    private var bundledMCPURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/joblet-mcp", isDirectory: false)
    }

    private var hasBundledMCP: Bool {
        FileManager.default.isExecutableFile(atPath: bundledMCPURL.path)
    }

    var body: some View {
        Form {
            Section("Joblet") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                Text("Scheduled jobs for your Mac, from a small window.")
                    .foregroundStyle(.secondary)
            }

            Section("General") {
                Toggle("Open Joblet at login", isOn: Binding(get: { launchAtLogin.isOn }, set: { launchAtLogin.setEnabled($0) }))
                    .accessibilityIdentifier("launch-at-login-toggle")
                if launchAtLogin.status == .requiresApproval {
                    Text("Approve Joblet in System Settings > General > Login Items to finish enabling this.")
                        .foregroundStyle(.secondary)
                    Button("Open Login Items Settings") { SMAppService.openSystemSettingsLoginItems() }
                } else if launchAtLogin.status == .notFound {
                    Text("The login item could not be found. Move Joblet to /Applications and try again.")
                        .foregroundStyle(.secondary)
                }
                if let message = launchAtLogin.errorMessage {
                    Text(message).foregroundStyle(.red)
                }
            }

            Section("Agent integration (MCP)") {
                Text("Let Codex or Claude Code operate your jobs. The MCP server uses stdio and works without Joblet running.")
                if hasBundledMCP {
                    LabeledContent("MCP executable") {
                        Text(bundledMCPURL.path)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    HStack {
                        Button("Copy Read-Only Config") { copyMCPJSON(arguments: []) }
                        Button("Copy Config with Create, Edit and Run") {
                            copyMCPJSON(arguments: ["--allow-write", "--allow-run"])
                        }
                    }
                } else {
                    Text("This build does not include the MCP server. Run scripts/build-app.sh to build Joblet.app with it; building in Xcode alone does not bundle it.")
                        .foregroundStyle(.secondary)
                }
                Text("The copied JSON uses the Claude Desktop / Claude Code format. See docs/MCP.md for Codex TOML and the full flag list. Write access lets an agent register and run commands as you, so connect only agents you trust. Deleting needs --allow-delete separately.")
                    .font(.callout)
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
        .frame(width: 590, height: 770)
        .onAppear { launchAtLogin.refresh() }
    }

    private func copyMCPJSON(arguments: [String]) {
        let config: [String: Any] = ["mcpServers": ["joblet": ["command": bundledMCPURL.path, "args": arguments]]]
        guard let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(String(decoding: data, as: UTF8.self), forType: .string)
    }
}
