import Sparkle

@MainActor
public final class SparkleUpdater {
    private let controller: SPUStandardUpdaterController

    public init(startingUpdater: Bool) {
        controller = SPUStandardUpdaterController(
            startingUpdater: startingUpdater,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    public var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }

    public func start() throws {
        try controller.updater.start()
    }

    @objc
    public func checkForUpdates(_ sender: Any?) {
        controller.checkForUpdates(sender)
    }
}
