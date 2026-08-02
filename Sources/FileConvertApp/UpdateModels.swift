import Foundation
import Observation

struct InstalledVersion: Equatable, Sendable {
    var version: String
    var build: String

    static func current(bundle: Bundle = .main) -> InstalledVersion {
        InstalledVersion(
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown",
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
        )
    }
}

struct UpdateRelease: Equatable, Sendable {
    var version: String
    var build: String
    var releasePageURL: URL?
}

struct UpdateProgress: Equatable, Sendable {
    var transferredByteCount: Int64
    var totalByteCount: Int64?
    var fractionCompleted: Double?

    init(transferredByteCount: Int64, totalByteCount: Int64?) {
        let transferred = max(0, transferredByteCount)
        self.transferredByteCount = transferred
        if let totalByteCount, totalByteCount > 0 {
            let total = max(transferred, totalByteCount)
            self.totalByteCount = total
            fractionCompleted = min(1, max(0, Double(transferred) / Double(total)))
        } else {
            self.totalByteCount = nil
            fractionCompleted = nil
        }
    }

    func advanced(to transferredByteCount: Int64, totalByteCount: Int64?) -> UpdateProgress {
        var next = UpdateProgress(
            transferredByteCount: max(self.transferredByteCount, transferredByteCount),
            totalByteCount: totalByteCount ?? self.totalByteCount
        )
        if let currentFraction = fractionCompleted,
           let nextFraction = next.fractionCompleted,
           nextFraction < currentFraction {
            next.fractionCompleted = currentFraction
        }
        return next
    }
}

struct UpdateFailure: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case networkUnavailable
        case invalidMetadata
        case downloadFailed
        case verificationFailed
        case installationFailed
        case configurationInvalid
        case unknown
    }

    var kind: Kind

    var message: String {
        switch kind {
        case .networkUnavailable:
            "Couldn’t reach the update service. Check your connection and try again."
        case .invalidMetadata:
            "The update information could not be verified. FileFlip will keep using the installed version."
        case .downloadFailed:
            "The update could not be downloaded. Try again or download FileFlip from GitHub."
        case .verificationFailed:
            "The downloaded update could not be verified and will not be installed."
        case .installationFailed:
            "The update could not be installed. Try again or download FileFlip from GitHub."
        case .configurationInvalid:
            "Automatic updates are unavailable because the update configuration is invalid."
        case .unknown:
            "The update could not be completed. Try again or download FileFlip from GitHub."
        }
    }

    var canRetry: Bool {
        switch kind {
        case .networkUnavailable, .downloadFailed, .installationFailed, .unknown:
            true
        case .invalidMetadata, .verificationFailed, .configurationInvalid:
            false
        }
    }
}

enum UpdateCheckOrigin: Equatable, Sendable {
    case automatic
    case userInitiated
}

enum UpdatePhase: Equatable, Sendable {
    case idle
    case checking(UpdateCheckOrigin)
    case upToDate
    case available
    case downloading
    case verifying
    case ready
    case installing
    case failed
}

struct UpdateViewState: Equatable, Sendable {
    var installedVersion: InstalledVersion
    var phase: UpdatePhase = .idle
    var checkOrigin: UpdateCheckOrigin?
    var availableRelease: UpdateRelease?
    var progress: UpdateProgress?
    var failure: UpdateFailure?
    var lastSuccessfulCheck: Date?
    var installsOnQuit = false

    var canDownloadAvailableUpdate: Bool { phase == .available && availableRelease != nil }
    var canRetry: Bool { phase == .failed && failure?.canRetry == true }
    var canDismissError: Bool { phase == .failed && failure != nil }
}

enum UpdateEvent: Equatable, Sendable {
    case checkStarted(UpdateCheckOrigin)
    case updateFound(UpdateRelease)
    case noUpdateFound(Date)
    case downloadStarted
    case downloadProgress(transferredByteCount: Int64, totalByteCount: Int64?)
    case downloadCancelled
    case downloadFinished
    case verificationSucceeded(installsOnQuit: Bool)
    case installStarted
    case operationFailed(UpdateFailure)
    case automaticUpdatesDisabled
    case retryStarted
    case installationRetryStarted
    case errorDismissed
    case installationDismissed
}

enum UpdateStateReducer {
    static func reduce(_ state: UpdateViewState, event: UpdateEvent) -> UpdateViewState {
        var next = state
        switch event {
        case let .checkStarted(origin):
            guard state.phase == .idle || state.phase == .upToDate || state.phase == .failed else { return state }
            next.phase = .checking(origin)
            next.checkOrigin = origin
            next.availableRelease = nil
            next.progress = nil
            next.failure = nil
            next.installsOnQuit = false

        case let .updateFound(release):
            guard case .checking = state.phase else { return state }
            next.phase = .available
            next.availableRelease = release
            next.progress = nil
            next.failure = nil

        case let .noUpdateFound(date):
            guard case .checking = state.phase else { return state }
            next.phase = .upToDate
            next.checkOrigin = nil
            next.availableRelease = nil
            next.progress = nil
            next.failure = nil
            next.lastSuccessfulCheck = date

        case .downloadStarted:
            guard state.phase == .available, state.availableRelease != nil else { return state }
            next.phase = .downloading
            next.progress = UpdateProgress(transferredByteCount: 0, totalByteCount: nil)
            next.failure = nil

        case let .downloadProgress(transferredByteCount, totalByteCount):
            guard state.phase == .downloading else { return state }
            next.progress = state.progress?.advanced(
                to: transferredByteCount,
                totalByteCount: totalByteCount
            ) ?? UpdateProgress(
                transferredByteCount: transferredByteCount,
                totalByteCount: totalByteCount
            )

        case .downloadCancelled:
            guard state.phase == .downloading else { return state }
            resetOperation(&next)

        case .downloadFinished:
            guard state.phase == .downloading else { return state }
            next.phase = .verifying
            next.progress = nil

        case let .verificationSucceeded(installsOnQuit):
            guard state.phase == .verifying, state.availableRelease != nil else { return state }
            next.phase = .ready
            next.installsOnQuit = installsOnQuit
            next.failure = nil

        case .installStarted:
            guard state.phase == .ready else { return state }
            next.phase = .installing
            next.installsOnQuit = false

        case let .operationFailed(failure):
            guard state.phase != .idle && state.phase != .upToDate && state.phase != .failed else { return state }
            next.phase = .failed
            next.progress = nil
            next.failure = failure
            next.installsOnQuit = false

        case .automaticUpdatesDisabled:
            switch state.phase {
            case .checking(.automatic):
                resetOperation(&next)
            case .available where state.checkOrigin == .automatic,
                 .downloading where state.checkOrigin == .automatic,
                 .ready where state.checkOrigin == .automatic:
                resetOperation(&next)
            default:
                return state
            }

        case .retryStarted:
            guard state.phase == .failed, state.failure?.canRetry == true else { return state }
            next.phase = .checking(.userInitiated)
            next.checkOrigin = .userInitiated
            next.progress = nil
            next.failure = nil
            next.installsOnQuit = false

        case .installationRetryStarted:
            guard state.phase == .failed,
                  state.failure?.kind == .installationFailed,
                  state.availableRelease != nil else {
                return state
            }
            next.phase = .ready
            next.progress = nil
            next.failure = nil
            next.installsOnQuit = false

        case .errorDismissed:
            guard state.phase == .failed else { return state }
            resetOperation(&next)

        case .installationDismissed:
            guard state.phase == .ready || state.phase == .installing else { return state }
            resetOperation(&next)
        }
        return next
    }

    private static func resetOperation(_ state: inout UpdateViewState) {
        state.phase = .idle
        state.checkOrigin = nil
        state.availableRelease = nil
        state.progress = nil
        state.failure = nil
        state.installsOnQuit = false
    }
}

@MainActor
protocol UpdateServicing: AnyObject {
    var viewState: UpdateViewState { get }
    var automaticUpdatesEnabled: Bool { get }
    var canCheckForUpdates: Bool { get }
    var canInstallAndRelaunch: Bool { get }

    func setAutomaticUpdatesEnabled(_ enabled: Bool)
    func checkForUpdates()
    func downloadAvailableUpdate()
    func installAndRelaunch()
    func retryCurrentOperation()
    func dismissCurrentError()
    func openReleasesPage()
}

@MainActor
@Observable
final class UpdateServiceModel: UpdateServicing {
    @ObservationIgnored private let service: any UpdateServicing

    init(service: any UpdateServicing) {
        self.service = service
    }

    var viewState: UpdateViewState { service.viewState }
    var automaticUpdatesEnabled: Bool { service.automaticUpdatesEnabled }
    var canCheckForUpdates: Bool { service.canCheckForUpdates }
    var canInstallAndRelaunch: Bool { service.canInstallAndRelaunch }

    func setAutomaticUpdatesEnabled(_ enabled: Bool) {
        service.setAutomaticUpdatesEnabled(enabled)
    }

    func checkForUpdates() {
        service.checkForUpdates()
    }

    func downloadAvailableUpdate() {
        service.downloadAvailableUpdate()
    }

    func installAndRelaunch() {
        service.installAndRelaunch()
    }

    func retryCurrentOperation() {
        service.retryCurrentOperation()
    }

    func dismissCurrentError() {
        service.dismissCurrentError()
    }

    func openReleasesPage() {
        service.openReleasesPage()
    }
}
