import AppKit
import Foundation
import Observation
import Sparkle

@MainActor
protocol FileFlipUpdateDriverDelegate: AnyObject {
    var automaticUpdatesEnabled: Bool { get }
    var updateViewState: UpdateViewState { get }

    func driverDidStartUserCheck(cancellation: @escaping () -> Void)
    func driverDidFindUpdate(_ release: UpdateRelease, origin: UpdateCheckOrigin)
    func driverDidFindNoUpdate()
    func driverDidStartDownload(cancellation: @escaping () -> Void)
    func driverDidReceiveExpectedContentLength(_ length: UInt64)
    func driverDidReceiveData(length: UInt64)
    func driverDidStartVerification()
    func driverDidFinishVerification(
        installsOnQuit: Bool,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    )
    func driverDidStartInstallation(retry: @escaping () -> Void)
    func driverDidFinishInstallation()
    func driverDidFail(_ failure: UpdateFailure, acknowledgement: @escaping () -> Void)
    func driverDidDismiss()
}

@MainActor
final class FileFlipUpdateDriver: NSObject, SPUUserDriver {
    private weak var delegate: (any FileFlipUpdateDriverDelegate)?
    private var activeCheckOrigin: UpdateCheckOrigin?
    private var updateFoundReply: ((SPUUserUpdateChoice) -> Void)?
    private var readyToInstallReply: ((SPUUserUpdateChoice) -> Void)?
    private var cancellation: (() -> Void)?
    private var cancelPendingAutomaticWork = false
    private var acknowledgement: (() -> Void)?
    private var retryTermination: (() -> Void)?

    init(delegate: any FileFlipUpdateDriverDelegate) {
        self.delegate = delegate
    }

    func show(
        _ request: SPUUpdatePermissionRequest,
        reply: @escaping (SUUpdatePermissionResponse) -> Void
    ) {
        reply(permissionResponse())
    }
    func permissionResponse() -> SUUpdatePermissionResponse {
        let enabled = delegate?.automaticUpdatesEnabled ?? false
        return SUUpdatePermissionResponse(
            automaticUpdateChecks: enabled,
            automaticUpdateDownloading: NSNumber(value: enabled),
            sendSystemProfile: false
        )
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        activeCheckOrigin = .userInitiated
        self.cancellation = cancellation
        delegate?.driverDidStartUserCheck(cancellation: cancellation)
    }

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        let release = UpdateRelease(
            version: appcastItem.displayVersionString,
            build: appcastItem.versionString,
            releasePageURL: [appcastItem.infoURL, appcastItem.releaseNotesURL]
                .lazy
                .compactMap(Self.safeReleaseURL)
                .first
        )
        handleUpdateFound(
            release,
            origin: state.userInitiated ? .userInitiated : .automatic,
            isTrustedInstallableUpdate: !appcastItem.isInformationOnlyUpdate
                && appcastItem.signingValidationStatus == .succeeded,
            reply: reply
        )

    }

    func handleUpdateFound(
        _ release: UpdateRelease,
        origin: UpdateCheckOrigin,
        isTrustedInstallableUpdate: Bool,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        cancellation = nil
        activeCheckOrigin = origin
        guard isTrustedInstallableUpdate, let releasePageURL = release.releasePageURL,
              Self.safeReleaseURL(releasePageURL) != nil else {
            reply(.dismiss)
            delegate?.driverDidFail(UpdateFailure(kind: .invalidMetadata), acknowledgement: {})
            return
        }
        if origin == .automatic, cancelPendingAutomaticWork {
            cancelPendingAutomaticWork = false
            reply(.dismiss)
            delegate?.driverDidDismiss()
            return
        }
        delegate?.driverDidFindUpdate(release, origin: origin)
        updateFoundReply = reply
        if origin == .automatic, delegate?.automaticUpdatesEnabled == true {
            consumeUpdateFoundReply(.install)
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(
        _ error: any Error,
        acknowledgement: @escaping () -> Void
    ) {
        clearEphemeralHandlers()
        delegate?.driverDidFindNoUpdate()
        acknowledgement()
    }

    var hasInstallationRetry: Bool { retryTermination != nil }

    func showUpdaterError(
        _ error: any Error,
        acknowledgement: @escaping () -> Void
    ) {
        updateFoundReply = nil
        readyToInstallReply = nil
        cancellation = nil
        let failure = Self.sanitizedFailure(for: error, phase: delegate?.updateViewState.phase ?? .idle)
        let origin = delegate?.updateViewState.checkOrigin ?? activeCheckOrigin ?? .automatic
        guard origin != .automatic else {
            activeCheckOrigin = nil
            delegate?.driverDidFail(failure, acknowledgement: {})
            acknowledgement()
            return
        }
        self.acknowledgement = acknowledgement
        delegate?.driverDidFail(failure, acknowledgement: acknowledgement)
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
        updateFoundReply = nil
        delegate?.driverDidStartDownload(cancellation: cancellation)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        delegate?.driverDidReceiveExpectedContentLength(expectedContentLength)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        delegate?.driverDidReceiveData(length: length)
    }

    func showDownloadDidStartExtractingUpdate() {
        cancellation = nil
        delegate?.driverDidStartVerification()
    }

    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard !cancelPendingAutomaticWork else {
            cancelPendingAutomaticWork = false
            delegate?.driverDidFinishVerification(installsOnQuit: false, reply: reply)
            reply(.skip)
            delegate?.driverDidDismiss()
            return
        }
        // Sparkle attempts to install a prepared update on normal termination
        // while this callback remains pending, regardless of FileFlip's download preference.
        readyToInstallReply = reply
        delegate?.driverDidFinishVerification(installsOnQuit: true, reply: reply)
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {
        readyToInstallReply = nil
        retryTermination = applicationTerminated ? nil : retryTerminatingApplication
        delegate?.driverDidStartInstallation(retry: retryTerminatingApplication)
    }

    func showUpdateInstalledAndRelaunched(
        _ relaunched: Bool,
        acknowledgement: @escaping () -> Void
    ) {
        clearEphemeralHandlers()
        delegate?.driverDidFinishInstallation()
        acknowledgement()
    }

    func dismissUpdateInstallation() {
        clearEphemeralHandlers()
        delegate?.driverDidDismiss()
    }

    func showUpdateInFocus() {}

    func beginAvailableUpdateDownload() {
        consumeUpdateFoundReply(.install)
    }
    @discardableResult
    func installAndRelaunch() -> Bool {
        guard let reply = readyToInstallReply else { return false }
        readyToInstallReply = nil
        reply(.install)
        return true
    }

    func cancelAutomaticWork(deferUntilCallback: Bool = false) {
        if let cancellation {
            self.cancellation = nil
            cancellation()
            return
        }
        if let updateFoundReply {
            self.updateFoundReply = nil
            updateFoundReply(.dismiss)
            return
        }
        if let readyToInstallReply {
            self.readyToInstallReply = nil
            readyToInstallReply(.skip)
            return
        }
        cancelPendingAutomaticWork = deferUntilCallback
    }

    func retryInstallation() {
        let acknowledgement = self.acknowledgement
        let retry = retryTermination
        clearEphemeralHandlers()
        acknowledgement?()
        retry?()
    }

    func finishError() {
        let handler = acknowledgement
        clearEphemeralHandlers()
        handler?()
    }

    private func consumeUpdateFoundReply(_ choice: SPUUserUpdateChoice) {
        guard let reply = updateFoundReply else { return }
        updateFoundReply = nil
        reply(choice)
    }

    private func clearEphemeralHandlers() {
        updateFoundReply = nil
        readyToInstallReply = nil
        cancellation = nil
        acknowledgement = nil
        retryTermination = nil
        activeCheckOrigin = nil
        cancelPendingAutomaticWork = false
    }

    static func safeReleaseURL(_ url: URL?) -> URL? {
        let releasesPathPrefix = "/chasedputnam/file-flip/releases/"
        guard let url,
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "github.com",
              url.user == nil,
              url.password == nil,
              url.port == nil,
              url.path.hasPrefix(releasesPathPrefix) else {
            return nil
        }
        return url
    }

    static func sanitizedFailure(for error: any Error, phase: UpdatePhase) -> UpdateFailure {
        let nsError = error as NSError
        if errorChain(nsError).contains(where: { $0.domain == NSURLErrorDomain }) {
            return UpdateFailure(kind: .networkUnavailable)
        }
        if nsError.domain == SUSparkleErrorDomain {
            switch nsError.code {
            case 1...7:
                return UpdateFailure(kind: .configurationInvalid)
            case 1_000...1_999:
                return UpdateFailure(kind: .invalidMetadata)
            case 2_000...2_999:
                return UpdateFailure(kind: .downloadFailed)
            case 3_000...3_999:
                return UpdateFailure(kind: .verificationFailed)
            case 4_000...4_999:
                return UpdateFailure(kind: .installationFailed)
            default:
                return UpdateFailure(kind: .unknown)
            }
        }
        switch phase {
        case .downloading:
            return UpdateFailure(kind: .downloadFailed)
        case .verifying:
            return UpdateFailure(kind: .verificationFailed)
        case .ready, .installing:
            return UpdateFailure(kind: .installationFailed)
        case .idle, .checking, .upToDate, .available, .failed:
            return UpdateFailure(kind: .unknown)
        }
    }

    private static func errorChain(_ root: NSError) -> [NSError] {
        var errors: [NSError] = []
        var current: NSError? = root
        while let error = current, !errors.contains(where: { $0 === error }) {
            errors.append(error)
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return errors
    }
}

@MainActor
final class UpdateInstallSafetyGate {
    private let isSafe: () -> Bool
    private var postponedRelaunchHandler: (() -> Void)?

    init(isSafe: @escaping () -> Bool) {
        self.isSafe = isSafe
    }

    var allowsImmediateInstallation: Bool {
        isSafe()
    }

    func shouldPostponeRelaunch(untilInvoking handler: @escaping () -> Void) -> Bool {
        guard !isSafe() else { return false }
        postponedRelaunchHandler = handler
        return true
    }

    func activeWorkSafetyDidChange() {
        guard isSafe(), let handler = postponedRelaunchHandler else { return }
        postponedRelaunchHandler = nil
        handler()
    }
}

@MainActor
final class ImmediateInstallationTransaction {
    private(set) var installationStarted = false
    private(set) var isInFlight = false
    private var cleanupTask: Task<Void, Never>?

    func run(
        prepare: () async -> Bool,
        commit: () -> Bool,
        cancel: @escaping () async -> Void,
        stateDidChange: @escaping () -> Void
    ) async -> Bool {
        guard !isInFlight else { return false }
        isInFlight = true
        installationStarted = false
        stateDidChange()

        guard await prepare() else {
            if let cleanupTask {
                await cleanupTask.value
            } else {
                finish(stateDidChange: stateDidChange)
            }
            return false
        }
        guard commit() else {
            await cancelOwnedReservation(cancel: cancel, stateDidChange: stateDidChange)
            return false
        }
        return true
    }

    func installationDidStart() {
        guard isInFlight else { return }
        installationStarted = true
    }

    func finish(stateDidChange: () -> Void) {
        guard isInFlight else { return }
        cleanupTask = nil
        isInFlight = false
        installationStarted = false
        stateDidChange()
    }

    func cancelOwnedReservation(
        cancel: @escaping () async -> Void,
        stateDidChange: @escaping () -> Void
    ) async {
        if let cleanupTask {
            await cleanupTask.value
            return
        }
        guard isInFlight else { return }

        let cleanupTask = Task { @MainActor [weak self] in
            await cancel()
            self?.finish(stateDidChange: stateDidChange)
        }
        self.cleanupTask = cleanupTask
        await cleanupTask.value
    }
}

@MainActor
@Observable
final class UpdateCoordinator: NSObject, UpdateServicing, FileFlipUpdateDriverDelegate, SPUUpdaterDelegate {
    private(set) var viewState: UpdateViewState
    private(set) var automaticUpdatesEnabled = false
    private(set) var canCheckForUpdates = false
    private(set) var canInstallAndRelaunch = false

    @ObservationIgnored private let installSafetyGate: UpdateInstallSafetyGate
    @ObservationIgnored private let prepareImmediateInstallation: () async -> Bool
    @ObservationIgnored private let cancelImmediateInstallation: () async -> Void
    @ObservationIgnored private let immediateInstallationTransaction = ImmediateInstallationTransaction()
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var receivedByteCount: UInt64 = 0
    @ObservationIgnored private var expectedByteCount: UInt64?
    @ObservationIgnored private var pendingRetryCheck = false

    @ObservationIgnored private lazy var userDriver = FileFlipUpdateDriver(delegate: self)
    @ObservationIgnored private lazy var updater = SPUUpdater(
        hostBundle: .main,
        applicationBundle: .main,
        userDriver: userDriver,
        delegate: self
    )

    var updateViewState: UpdateViewState { viewState }

    init(
        isImmediateInstallSafe: @escaping () -> Bool,
        prepareImmediateInstallation: @escaping () async -> Bool,
        cancelImmediateInstallation: @escaping () async -> Void
    ) {
        installSafetyGate = UpdateInstallSafetyGate(isSafe: isImmediateInstallSafe)
        self.prepareImmediateInstallation = prepareImmediateInstallation
        self.cancelImmediateInstallation = cancelImmediateInstallation
        viewState = UpdateViewState(installedVersion: .current())
        super.init()
        startUpdater()
    }

    func activeWorkSafetyDidChange() {
        refreshInstallAvailability()
        installSafetyGate.activeWorkSafetyDidChange()
    }

    func setAutomaticUpdatesEnabled(_ enabled: Bool) {
        updater.automaticallyChecksForUpdates = enabled
        // Keep Sparkle on its scheduled user-driver path. FileFlip's user driver
        // accepts eligible automatic updates without prompting and retains safe
        // cancellation callbacks that Sparkle's silent driver does not expose.
        updater.automaticallyDownloadsUpdates = false
        synchronizeUpdaterProperties()
        guard !enabled else { return }
        if viewState.checkOrigin == .automatic {
            let awaitsCancellableCallback = switch viewState.phase {
            case .checking, .verifying: true
            default: false
            }
            userDriver.cancelAutomaticWork(deferUntilCallback: awaitsCancellableCallback)
        }
        apply(.automaticUpdatesDisabled)
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        updater.checkForUpdates()
    }

    func downloadAvailableUpdate() {
        guard viewState.canDownloadAvailableUpdate else { return }
        userDriver.beginAvailableUpdateDownload()
    }

    func installAndRelaunch() {
        guard canInstallAndRelaunch else { return }
        beginImmediateInstallation { [weak self] in
            guard let self else { return false }
            return self.viewState.phase == .ready
                && self.installSafetyGate.allowsImmediateInstallation
                && self.userDriver.installAndRelaunch()
        }
    }

    private func beginImmediateInstallation(
        commit: @escaping () -> Bool,
        restoreFailure: (() -> Void)? = nil
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let didCommit = await self.immediateInstallationTransaction.run(
                prepare: self.prepareImmediateInstallation,
                commit: commit,
                cancel: self.cancelImmediateInstallation,
                stateDidChange: { self.refreshInstallAvailability() }
            )
            if !didCommit {
                restoreFailure?()
            }
        }
    }

    @discardableResult
    static func performImmediateInstallation(
        prepare: () async -> Bool,
        commit: () -> Bool,
        cancel: () async -> Void
    ) async -> Bool {
        guard await prepare() else { return false }
        guard commit() else {
            await cancel()
            return false
        }
        return true
    }

    func retryCurrentOperation() {
        guard viewState.canRetry else { return }
        if userDriver.hasInstallationRetry {
            let failure = viewState.failure
            apply(.installationRetryStarted)
            beginImmediateInstallation(
                commit: { [weak self] in
                    guard let self else { return false }
                    guard self.viewState.phase == .ready,
                          self.installSafetyGate.allowsImmediateInstallation else { return false }
                    self.userDriver.retryInstallation()
                    return true
                },
                restoreFailure: { [weak self] in
                    guard let self, let failure else { return }
                    self.apply(.operationFailed(failure))
                }
            )
            return
        }
        apply(.retryStarted)
        pendingRetryCheck = true
        userDriver.finishError()
        runPendingRetryCheck()
    }

    func dismissCurrentError() {
        guard viewState.canDismissError else { return }
        apply(.errorDismissed)
        userDriver.finishError()
    }

    func openReleasesPage() {
        guard let url = URL(string: "https://github.com/chasedputnam/file-flip/releases") else { return }
        NSWorkspace.shared.open(url)
    }

    func driverDidStartUserCheck(cancellation: @escaping () -> Void) {
        apply(.checkStarted(.userInitiated))
    }

    func driverDidFindUpdate(_ release: UpdateRelease, origin: UpdateCheckOrigin) {
        if case .checking = viewState.phase {
            apply(.updateFound(release))
        } else {
            apply(.checkStarted(origin))
            apply(.updateFound(release))
        }
        viewState.lastSuccessfulCheck = updater.lastUpdateCheckDate ?? Date()
    }

    func driverDidFindNoUpdate() {
        if case .checking = viewState.phase {
            apply(.noUpdateFound(Date()))
        } else {
            apply(.checkStarted(.automatic))
            apply(.noUpdateFound(Date()))
        }
    }

    func driverDidStartDownload(cancellation: @escaping () -> Void) {
        receivedByteCount = 0
        expectedByteCount = nil
        apply(.downloadStarted)
    }

    func driverDidReceiveExpectedContentLength(_ length: UInt64) {
        expectedByteCount = length
        publishDownloadProgress()
    }

    func driverDidReceiveData(length: UInt64) {
        receivedByteCount = receivedByteCount.addingReportingOverflow(length).overflow
            ? UInt64.max
            : receivedByteCount + length
        publishDownloadProgress()
    }

    func driverDidStartVerification() {
        apply(.downloadFinished)
    }

    func driverDidFinishVerification(
        installsOnQuit: Bool,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        apply(.verificationSucceeded(installsOnQuit: installsOnQuit))
    }

    func driverDidStartInstallation(retry: @escaping () -> Void) {
        immediateInstallationTransaction.installationDidStart()
        apply(.installStarted)
    }

    func driverDidFinishInstallation() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.immediateInstallationTransaction.cancelOwnedReservation(
                cancel: self.cancelImmediateInstallation,
                stateDidChange: { self.refreshInstallAvailability() }
            )
            self.apply(.installationDismissed)
        }
    }

    func driverDidFail(_ failure: UpdateFailure, acknowledgement: @escaping () -> Void) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.immediateInstallationTransaction.cancelOwnedReservation(
                cancel: self.cancelImmediateInstallation,
                stateDidChange: { self.refreshInstallAvailability() }
            )
            if self.viewState.phase == .idle || self.viewState.phase == .upToDate {
                self.apply(.checkStarted(.automatic))
            }
            self.apply(.operationFailed(failure))
        }
    }

    func driverDidDismiss() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.immediateInstallationTransaction.cancelOwnedReservation(
                cancel: self.cancelImmediateInstallation,
                stateDidChange: { self.refreshInstallAvailability() }
            )
            switch self.viewState.phase {
            case .ready, .installing:
                self.apply(.installationDismissed)
            case .failed:
                self.apply(.errorDismissed)
            case .downloading:
                self.apply(.downloadCancelled)
            default:
                break
            }
        }
    }

    func updater(
        _ updater: SPUUpdater,
        shouldPostponeRelaunchForUpdate update: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        let shouldPostpone = installSafetyGate.shouldPostponeRelaunch(untilInvoking: installHandler)
        refreshInstallAvailability()
        return shouldPostpone
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: (any Error)?
    ) {
        synchronizeUpdaterProperties()
    }

    private func startUpdater() {
        do {
            updater.automaticallyDownloadsUpdates = false
            try updater.start()
            observeUpdaterProperties()
            synchronizeUpdaterProperties()
        } catch {
            canCheckForUpdates = false
            apply(.checkStarted(.automatic))
            apply(.operationFailed(UpdateFailure(kind: .configurationInvalid)))
        }
    }

    private func observeUpdaterProperties() {
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.synchronizeUpdaterProperties() }
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.synchronizeUpdaterProperties() }
            },
            updater.observe(\.automaticallyDownloadsUpdates, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.synchronizeUpdaterProperties() }
            },
            updater.observe(\.lastUpdateCheckDate, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.synchronizeUpdaterProperties() }
            },
        ]
    }

    private func synchronizeUpdaterProperties() {
        automaticUpdatesEnabled = updater.automaticallyChecksForUpdates
        canCheckForUpdates = updater.canCheckForUpdates
        if let lastCheck = updater.lastUpdateCheckDate,
           viewState.phase == .upToDate || viewState.lastSuccessfulCheck != nil {
            viewState.lastSuccessfulCheck = lastCheck
        }
        refreshInstallAvailability()
        runPendingRetryCheck()
    }

    private func runPendingRetryCheck() {
        guard pendingRetryCheck, updater.canCheckForUpdates else { return }
        pendingRetryCheck = false
        updater.checkForUpdates()
    }

    private func refreshInstallAvailability() {
        canInstallAndRelaunch = !immediateInstallationTransaction.isInFlight
            && viewState.phase == .ready
            && installSafetyGate.allowsImmediateInstallation
    }

    private func publishDownloadProgress() {
        apply(.downloadProgress(
            transferredByteCount: Int64(clamping: receivedByteCount),
            totalByteCount: expectedByteCount.map { Int64(clamping: $0) }
        ))
    }

    private func apply(_ event: UpdateEvent) {
        viewState = UpdateStateReducer.reduce(viewState, event: event)
        refreshInstallAvailability()
    }
}
