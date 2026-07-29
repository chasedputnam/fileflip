import Foundation
import Observation

@MainActor
@Observable
public final class AppCoordinator {
    public enum MonitoringStatus: String, Sendable { case inactive, active, paused, blocked }

    public private(set) var status: MonitoringStatus = .inactive
    public private(set) var startupError: String?
    private var instanceLock: SingleInstanceLock?

    public init() {}

    public func start(bundleIdentifier: String = "app.fileconvert.FileConvert") {
        guard instanceLock == nil else { return }
        do {
            let storage = try ApplicationStorage.prepare(bundleIdentifier: bundleIdentifier)
            instanceLock = try SingleInstanceLock(url: storage.appending(path: "instance.lock"))
            status = .inactive
            startupError = nil
        } catch {
            status = .blocked
            startupError = String(describing: error)
        }
    }

    public func stop() {
        instanceLock = nil
        status = .inactive
    }
}
