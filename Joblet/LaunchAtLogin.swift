import ServiceManagement

/// Start-at-login state backed by `SMAppService.mainApp`.
/// With `stubbed` (UI tests) it only tracks state in memory and never registers a real login item.
@MainActor
final class LaunchAtLogin: ObservableObject {
    @Published private(set) var status: SMAppService.Status
    @Published private(set) var errorMessage: String?
    private let stubbed: Bool

    init(stubbed: Bool) {
        self.stubbed = stubbed
        status = stubbed ? .notRegistered : SMAppService.mainApp.status
    }

    var isOn: Bool {
        status == .enabled || status == .requiresApproval
    }

    func refresh() {
        guard !stubbed else { return }
        status = SMAppService.mainApp.status
    }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        if stubbed {
            status = enabled ? .enabled : .notRegistered
            return
        }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        status = SMAppService.mainApp.status
    }
}
