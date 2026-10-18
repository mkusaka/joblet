import AppKit
import JobletSparkle
import SwiftUI

@main
@MainActor
struct JobletApp: App {
    @NSApplicationDelegateAdaptor(JobletAppDelegate.self) private var appDelegate
    @StateObject private var store = AppEnvironment.makeStore()
    @StateObject private var launchAtLogin = LaunchAtLogin(stubbed: AppEnvironment.isUITesting)
    /// Never started in UI tests, so they cannot hit the network or show update prompts.
    @State private var updater = SparkleUpdater(startingUpdater: !AppEnvironment.isUITesting)
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        Window("Joblet", id: "main") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 860, minHeight: 590)
                .task(id: scenePhase) {
                    guard scenePhase == .active else { return }
                    await store.refresh()
                    while !Task.isCancelled {
                        do {
                            try await Task.sleep(nanoseconds: 10_000_000_000)
                        } catch {
                            return
                        }
                        guard !Task.isCancelled else { return }
                        await store.refresh()
                    }
                }
        }
        .defaultSize(width: 1040, height: 720)
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates(nil) }
                    .disabled(AppEnvironment.isUITesting)
            }
            CommandGroup(after: .newItem) {
                Button("Refresh Jobs") {
                    Task { await store.refresh() }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(store.isBusy || store.isRefreshing)
            }
        }

        MenuBarExtra("Joblet", systemImage: "clock.arrow.circlepath") {
            MenuBarView(updater: updater)
                .environmentObject(store)
                .task { await store.refresh() }
        }
        .menuBarExtraStyle(.window)

        Settings {
            JobletSettingsView(launchAtLogin: launchAtLogin)
        }
    }
}

@MainActor
final class JobletAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
    }
}
