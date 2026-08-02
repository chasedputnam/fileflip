import Foundation
import Observation

@MainActor
@Observable
final class FakeUpdateService: UpdateServicing {
    enum Scenario: String, CaseIterable, Sendable {
        case idle
        case upToDate = "up-to-date"
        case available
        case downloading
        case downloadingUnknownLength = "downloading-unknown-length"
        case verifying
        case ready
        case failedNetwork = "failed-network"
        case failedMetadata = "failed-metadata"
        case failedDownload = "failed-download"
        case failedVerification = "failed-verification"
        case failedInstallation = "failed-installation"
        case failedConfiguration = "failed-configuration"
        case failedUnknown = "failed-unknown"
    }

    private(set) var viewState: UpdateViewState
    private(set) var automaticUpdatesEnabled: Bool
    private let isImmediateInstallSafe: () -> Bool
    private let releasesPageHandler: () -> Void

    init(
        scenario: Scenario = .idle,
        automaticUpdatesEnabled: Bool = true,
        installedVersion: InstalledVersion = .current(),
        isImmediateInstallSafe: @escaping () -> Bool = { true },
        releasesPageHandler: @escaping () -> Void = {}
    ) {
        self.automaticUpdatesEnabled = automaticUpdatesEnabled
        self.isImmediateInstallSafe = isImmediateInstallSafe
        self.releasesPageHandler = releasesPageHandler
        viewState = Self.makeState(scenario: scenario, installedVersion: installedVersion)
    }

    var canCheckForUpdates: Bool {
        switch viewState.phase {
        case .idle, .upToDate, .failed:
            true
        case .checking, .available, .downloading, .verifying, .ready, .installing:
            false
        }
    }

    var canInstallAndRelaunch: Bool {
        viewState.phase == .ready && isImmediateInstallSafe()
    }

    func setAutomaticUpdatesEnabled(_ enabled: Bool) {
        automaticUpdatesEnabled = enabled
        guard !enabled else { return }
        apply(.automaticUpdatesDisabled)
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        apply(.checkStarted(.userInitiated))
    }

    func downloadAvailableUpdate() {
        guard viewState.canDownloadAvailableUpdate else { return }
        apply(.downloadStarted)
    }

    func installAndRelaunch() {
        guard canInstallAndRelaunch else { return }
        apply(.installStarted)
    }

    func retryCurrentOperation() {
        guard viewState.canRetry else { return }
        apply(.retryStarted)
    }

    func dismissCurrentError() {
        guard viewState.canDismissError else { return }
        apply(.errorDismissed)
    }

    func openReleasesPage() {
        releasesPageHandler()
    }

    func apply(_ event: UpdateEvent) {
        viewState = UpdateStateReducer.reduce(viewState, event: event)
    }

    private static func makeState(
        scenario: Scenario,
        installedVersion: InstalledVersion
    ) -> UpdateViewState {
        let release = UpdateRelease(
            version: "0.2.0",
            build: "2",
            releasePageURL: URL(string: "https://github.com/chasedputnam/file-flip/releases/tag/v0.2.0")
        )
        var state = UpdateViewState(installedVersion: installedVersion)
        switch scenario {
        case .idle:
            break
        case .upToDate:
            state.phase = .upToDate
            state.lastSuccessfulCheck = Date(timeIntervalSince1970: 1_700_000_000)
        case .available:
            state.phase = .available
            state.checkOrigin = .automatic
            state.availableRelease = release
        case .downloading, .downloadingUnknownLength:
            state.phase = .downloading
            state.checkOrigin = .automatic
            state.availableRelease = release
            state.progress = UpdateProgress(
                transferredByteCount: 42,
                totalByteCount: scenario == .downloading ? 100 : nil
            )
        case .verifying:
            state.phase = .verifying
            state.checkOrigin = .automatic
            state.availableRelease = release
        case .ready:
            state.phase = .ready
            state.checkOrigin = .automatic
            state.availableRelease = release
            state.installsOnQuit = true
        case .failedNetwork:
            state.phase = .failed
            state.failure = UpdateFailure(kind: .networkUnavailable)
        case .failedMetadata:
            state.phase = .failed
            state.failure = UpdateFailure(kind: .invalidMetadata)
        case .failedDownload:
            state.phase = .failed
            state.failure = UpdateFailure(kind: .downloadFailed)
        case .failedVerification:
            state.phase = .failed
            state.failure = UpdateFailure(kind: .verificationFailed)
        case .failedInstallation:
            state.phase = .failed
            state.failure = UpdateFailure(kind: .installationFailed)
        case .failedConfiguration:
            state.phase = .failed
            state.failure = UpdateFailure(kind: .configurationInvalid)
        case .failedUnknown:
            state.phase = .failed
            state.failure = UpdateFailure(kind: .unknown)
        }
        return state
    }
}
