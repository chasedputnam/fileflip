import Foundation
import Testing
@testable import FileConvertApp

@Suite(.serialized)
struct UpdateModelsTests {
    private let installed = InstalledVersion(version: "0.1.0", build: "1")
    private let release = UpdateRelease(
        version: "0.2.0",
        build: "2",
        releasePageURL: URL(string: "https://github.com/chasedputnam/file-flip/releases/tag/v0.2.0")
    )

    @Test
    func completeManualLifecycleUsesOnlyValidTransitions() {
        let initial = UpdateViewState(installedVersion: installed)
        let checking = UpdateStateReducer.reduce(initial, event: .checkStarted(.userInitiated))
        #expect(checking.phase == .checking(.userInitiated))

        let available = UpdateStateReducer.reduce(checking, event: .updateFound(release))
        #expect(available.phase == .available)
        #expect(available.availableRelease == release)
        #expect(available.canDownloadAvailableUpdate)

        let downloading = UpdateStateReducer.reduce(available, event: .downloadStarted)
        #expect(downloading.phase == .downloading)

        let progressed = UpdateStateReducer.reduce(
            downloading,
            event: .downloadProgress(transferredByteCount: 50, totalByteCount: 100)
        )
        #expect(progressed.progress?.fractionCompleted == 0.5)

        let verifying = UpdateStateReducer.reduce(progressed, event: .downloadFinished)
        #expect(verifying.phase == .verifying)
        #expect(verifying.progress == nil)

        let ready = UpdateStateReducer.reduce(
            verifying,
            event: .verificationSucceeded(installsOnQuit: true)
        )
        #expect(ready.phase == .ready)
        #expect(ready.installsOnQuit)

        let installing = UpdateStateReducer.reduce(ready, event: .installStarted)
        #expect(installing.phase == .installing)
        #expect(!installing.installsOnQuit)
    }

    @Test
    func noUpdateRecordsOnlySuccessfulCheckTime() {
        let date = Date(timeIntervalSince1970: 123)
        let initial = UpdateViewState(installedVersion: installed)
        let checking = UpdateStateReducer.reduce(initial, event: .checkStarted(.automatic))
        let current = UpdateStateReducer.reduce(checking, event: .noUpdateFound(date))
        #expect(current.phase == .upToDate)
        #expect(current.lastSuccessfulCheck == date)
        #expect(current.availableRelease == nil)
    }

    @Test
    func invalidAndDuplicateEventsAreNoOps() {
        let idle = UpdateViewState(installedVersion: installed)
        let invalidIdleEvents: [UpdateEvent] = [
            .updateFound(release),
            .noUpdateFound(.now),
            .downloadStarted,
            .downloadProgress(transferredByteCount: 1, totalByteCount: 2),
            .downloadCancelled,
            .downloadFinished,
            .verificationSucceeded(installsOnQuit: true),
            .installStarted,
            .operationFailed(UpdateFailure(kind: .unknown)),
            .automaticUpdatesDisabled,
            .retryStarted,
            .installationRetryStarted,
            .errorDismissed,
            .installationDismissed,
        ]
        for event in invalidIdleEvents {
            #expect(UpdateStateReducer.reduce(idle, event: event) == idle)
        }

        let checking = UpdateStateReducer.reduce(idle, event: .checkStarted(.automatic))
        #expect(UpdateStateReducer.reduce(checking, event: .checkStarted(.userInitiated)) == checking)
        let available = UpdateStateReducer.reduce(checking, event: .updateFound(release))
        #expect(UpdateStateReducer.reduce(available, event: .updateFound(release)) == available)
        let downloading = UpdateStateReducer.reduce(available, event: .downloadStarted)
        #expect(UpdateStateReducer.reduce(downloading, event: .downloadStarted) == downloading)
    }

    @Test
    func progressIsClampedAndNeverMovesBackward() {
        let negative = UpdateProgress(transferredByteCount: -5, totalByteCount: 100)
        #expect(negative.transferredByteCount == 0)
        #expect(negative.fractionCompleted == 0)

        let overrun = UpdateProgress(transferredByteCount: 150, totalByteCount: 100)
        #expect(overrun.totalByteCount == 150)
        #expect(overrun.fractionCompleted == 1)

        let unknown = UpdateProgress(transferredByteCount: 10, totalByteCount: nil)
        #expect(unknown.fractionCompleted == nil)

        let halfway = UpdateProgress(transferredByteCount: 50, totalByteCount: 100)
        let stale = halfway.advanced(to: 40, totalByteCount: 200)
        #expect(stale.transferredByteCount == 50)
        #expect(stale.fractionCompleted == 0.5)
        let complete = stale.advanced(to: 250, totalByteCount: 200)
        #expect(complete.fractionCompleted == 1)
    }

    @Test
    func failuresPreserveInstalledVersionAndExposeOnlySanitizedMessages() {
        var state = UpdateViewState(installedVersion: installed)
        state = UpdateStateReducer.reduce(state, event: .checkStarted(.userInitiated))
        state = UpdateStateReducer.reduce(
            state,
            event: .operationFailed(UpdateFailure(kind: .networkUnavailable))
        )
        #expect(state.phase == .failed)
        #expect(state.installedVersion == installed)
        #expect(state.lastSuccessfulCheck == nil)
        #expect(state.canRetry)
        #expect(state.failure?.message.contains("/Users/") == false)

        let retrying = UpdateStateReducer.reduce(state, event: .retryStarted)
        #expect(retrying.phase == .checking(.userInitiated))
        #expect(retrying.installedVersion == installed)

        let failedAgain = UpdateStateReducer.reduce(
            retrying,
            event: .operationFailed(UpdateFailure(kind: .verificationFailed))
        )
        #expect(!failedAgain.canRetry)
        #expect(UpdateStateReducer.reduce(failedAgain, event: .retryStarted) == failedAgain)
        let dismissed = UpdateStateReducer.reduce(failedAgain, event: .errorDismissed)
        #expect(dismissed.phase == .idle)
        #expect(dismissed.installedVersion == installed)
    }
    @Test
    func installationRetryReturnsVerifiedReleaseToReadyState() {
        var state = UpdateViewState(installedVersion: installed)
        state = UpdateStateReducer.reduce(state, event: .checkStarted(.userInitiated))
        state = UpdateStateReducer.reduce(state, event: .updateFound(release))
        state = UpdateStateReducer.reduce(state, event: .downloadStarted)
        state = UpdateStateReducer.reduce(state, event: .downloadFinished)
        state = UpdateStateReducer.reduce(state, event: .verificationSucceeded(installsOnQuit: false))
        state = UpdateStateReducer.reduce(state, event: .installStarted)
        state = UpdateStateReducer.reduce(
            state,
            event: .operationFailed(UpdateFailure(kind: .installationFailed))
        )

        let retrying = UpdateStateReducer.reduce(state, event: .installationRetryStarted)

        #expect(retrying.phase == .ready)
        #expect(retrying.availableRelease == release)
        #expect(retrying.failure == nil)
        #expect(!retrying.installsOnQuit)
    }


    @Test
    func disablingAutomaticUpdatesCancelsOnlyAutomaticWork() {
        let idle = UpdateViewState(installedVersion: installed)
        let automaticCheck = UpdateStateReducer.reduce(idle, event: .checkStarted(.automatic))
        #expect(UpdateStateReducer.reduce(automaticCheck, event: .automaticUpdatesDisabled).phase == .idle)

        let manualCheck = UpdateStateReducer.reduce(idle, event: .checkStarted(.userInitiated))
        #expect(UpdateStateReducer.reduce(manualCheck, event: .automaticUpdatesDisabled) == manualCheck)
        let manualAvailable = UpdateStateReducer.reduce(manualCheck, event: .updateFound(release))
        #expect(UpdateStateReducer.reduce(manualAvailable, event: .automaticUpdatesDisabled) == manualAvailable)

        let available = UpdateStateReducer.reduce(automaticCheck, event: .updateFound(release))
        let downloading = UpdateStateReducer.reduce(available, event: .downloadStarted)
        #expect(UpdateStateReducer.reduce(downloading, event: .automaticUpdatesDisabled).phase == .idle)

        let verifying = UpdateStateReducer.reduce(downloading, event: .downloadFinished)
        #expect(UpdateStateReducer.reduce(verifying, event: .automaticUpdatesDisabled) == verifying)
        let ready = UpdateStateReducer.reduce(
            verifying,
            event: .verificationSucceeded(installsOnQuit: true)
        )
        #expect(UpdateStateReducer.reduce(ready, event: .automaticUpdatesDisabled).phase == .idle)
    }

    @Test
    func cancellationAndDismissalClearEphemeralUpdateState() {
        let idle = UpdateViewState(installedVersion: installed)
        let checking = UpdateStateReducer.reduce(idle, event: .checkStarted(.automatic))
        let available = UpdateStateReducer.reduce(checking, event: .updateFound(release))
        let downloading = UpdateStateReducer.reduce(available, event: .downloadStarted)
        let cancelled = UpdateStateReducer.reduce(downloading, event: .downloadCancelled)
        #expect(cancelled.phase == .idle)
        #expect(cancelled.availableRelease == nil)
        #expect(cancelled.checkOrigin == nil)

        let verifying = UpdateStateReducer.reduce(downloading, event: .downloadFinished)
        let ready = UpdateStateReducer.reduce(
            verifying,
            event: .verificationSucceeded(installsOnQuit: true)
        )
        let dismissedReady = UpdateStateReducer.reduce(ready, event: .installationDismissed)
        #expect(dismissedReady.phase == .idle)

        let installing = UpdateStateReducer.reduce(ready, event: .installStarted)
        let dismissedInstalling = UpdateStateReducer.reduce(installing, event: .installationDismissed)
        #expect(dismissedInstalling.phase == .idle)
    }

    @Test @MainActor
    func fakeServiceIsDeterministicAndNeverPerformsNetworkWork() {
        let service = FakeUpdateService(
            scenario: .available,
            installedVersion: installed,
            isImmediateInstallSafe: { false }
        )
        #expect(service.viewState.phase == .available)
        #expect(service.viewState.canDownloadAvailableUpdate)
        service.downloadAvailableUpdate()
        #expect(service.viewState.phase == .downloading)
        service.setAutomaticUpdatesEnabled(false)
        #expect(service.viewState.phase == .idle)
        #expect(!service.automaticUpdatesEnabled)

        let blocked = FakeUpdateService(
            scenario: .ready,
            installedVersion: installed,
            isImmediateInstallSafe: { false }
        )
        #expect(!blocked.canInstallAndRelaunch)
        blocked.installAndRelaunch()
        #expect(blocked.viewState.phase == .ready)
    }
    @Test @MainActor
    func relaunchSafetyGatePreservesNormalQuitAndClosesActiveWorkRace() {
        var isSafe = true
        var relaunchCount = 0
        let gate = UpdateInstallSafetyGate(isSafe: { isSafe })

        #expect(!gate.shouldPostponeRelaunch { relaunchCount += 1 })
        #expect(relaunchCount == 0)

        isSafe = false
        #expect(gate.shouldPostponeRelaunch { relaunchCount += 1 })
        gate.activeWorkSafetyDidChange()
        #expect(relaunchCount == 0)

        isSafe = true
        gate.activeWorkSafetyDidChange()
        gate.activeWorkSafetyDidChange()
        #expect(relaunchCount == 1)
    }

    @Test @MainActor
    func failedPostReservationCommitReleasesImmediateInstallationReservation() async {
        var installationCount = 0
        var cancellationCount = 0

        await UpdateCoordinator.performImmediateInstallation(
            prepare: { true },
            commit: {
                installationCount += 1
                return false
            },
            cancel: { cancellationCount += 1 }
        )

        #expect(installationCount == 1)
        #expect(cancellationCount == 1)
    }

    @Test @MainActor
    func duplicateImmediateInstallCannotCommitBeforeOwningPreparationDrains() async {
        let transaction = ImmediateInstallationTransaction()
        var preparationContinuation: CheckedContinuation<Void, Never>?
        var preparationCount = 0
        var installationCount = 0
        var cancellationCount = 0

        let owner = Task { @MainActor in
            await transaction.run(
                prepare: {
                    preparationCount += 1
                    await withCheckedContinuation { preparationContinuation = $0 }
                    return true
                },
                commit: {
                    installationCount += 1
                    return true
                },
                cancel: { cancellationCount += 1 },
                stateDidChange: {}
            )
        }
        await Task.yield()

        let duplicateCommitted = await transaction.run(
            prepare: {
                preparationCount += 1
                return true
            },
            commit: {
                installationCount += 1
                return true
            },
            cancel: { cancellationCount += 1 },
            stateDidChange: {}
        )

        #expect(!duplicateCommitted)
        #expect(preparationCount == 1)
        #expect(installationCount == 0)
        #expect(cancellationCount == 0)

        preparationContinuation?.resume()
        let ownerCommitted = await owner.value
        #expect(ownerCommitted)
        #expect(installationCount == 1)
        #expect(cancellationCount == 0)
    }

    @Test @MainActor
    func installationRetryUsesReservationPreparationBeforeRetrying() async {
        let transaction = ImmediateInstallationTransaction()
        var prepared = false
        var retryCount = 0
        var cancellationCount = 0

        let committed = await transaction.run(
            prepare: {
                prepared = true
                return true
            },
            commit: {
                #expect(prepared)
                retryCount += 1
                return true
            },
            cancel: { cancellationCount += 1 },
            stateDidChange: {}
        )

        #expect(committed)
        #expect(retryCount == 1)
        #expect(cancellationCount == 0)
    }

    @Test @MainActor
    func committedImmediateInstallRemainsOwnedUntilSparkleStartsInstallation() async {
        let transaction = ImmediateInstallationTransaction()
        var installationCount = 0

        let initialCommit = await transaction.run(
            prepare: { true },
            commit: {
                installationCount += 1
                return true
            },
            cancel: {},
            stateDidChange: {}
        )
        #expect(initialCommit)
        #expect(transaction.isInFlight)

        let duplicateCommitted = await transaction.run(
            prepare: { true },
            commit: {
                installationCount += 1
                return true
            },
            cancel: {},
            stateDidChange: {}
        )

        #expect(!duplicateCommitted)
        #expect(installationCount == 1)
        transaction.finish(stateDidChange: {})
        #expect(!transaction.isInFlight)
    }

    @Test @MainActor
    func retryCannotReacquireUntilFailedOwnerCleanupCompletes() async {
        let transaction = ImmediateInstallationTransaction()
        var cancellationContinuation: CheckedContinuation<Void, Never>?
        var retryCount = 0

        let initialCommit = await transaction.run(
            prepare: { true },
            commit: { true },
            cancel: {},
            stateDidChange: {}
        )
        #expect(initialCommit)

        let cleanup = Task { @MainActor in
            await transaction.cancelOwnedReservation(
                cancel: {
                    await withCheckedContinuation { cancellationContinuation = $0 }
                },
                stateDidChange: {}
            )
        }
        await Task.yield()

        let earlyRetryCommitted = await transaction.run(
            prepare: { true },
            commit: {
                retryCount += 1
                return true
            },
            cancel: {},
            stateDidChange: {}
        )
        #expect(!earlyRetryCommitted)
        #expect(retryCount == 0)

        cancellationContinuation?.resume()
        await cleanup.value
        #expect(!transaction.isInFlight)
        let retriedAfterCleanup = await transaction.run(
            prepare: { true },
            commit: {
                retryCount += 1
                return true
            },
            cancel: {},
            stateDidChange: {}
        )
        #expect(retriedAfterCleanup)
        #expect(retryCount == 1)
    }

    @Test @MainActor
    func postInstallStartFailureCancelsReservationExactlyOnce() async {
        await assertTerminalInstallationCleanupCancelsOnce()
    }

    @Test @MainActor
    func postInstallStartDismissalCancelsReservationExactlyOnce() async {
        await assertTerminalInstallationCleanupCancelsOnce()
    }

    @Test @MainActor
    func postInstallStartCompletionReleasesReservationExactlyOnce() async {
        await assertTerminalInstallationCleanupCancelsOnce()
    }

    @MainActor
    private func assertTerminalInstallationCleanupCancelsOnce() async {
        let transaction = ImmediateInstallationTransaction()
        var cancellationCount = 0

        let committed = await transaction.run(
            prepare: { true },
            commit: { true },
            cancel: {},
            stateDidChange: {}
        )
        #expect(committed)
        #expect(transaction.isInFlight)
        transaction.installationDidStart()
        #expect(transaction.installationStarted)

        await transaction.cancelOwnedReservation(
            cancel: { cancellationCount += 1 },
            stateDidChange: {}
        )
        await transaction.cancelOwnedReservation(
            cancel: { cancellationCount += 1 },
            stateDidChange: {}
        )

        #expect(cancellationCount == 1)
        #expect(!transaction.isInFlight)
    }

    @Test @MainActor
    func overlappingTerminalCleanupJoinsTheOwningCancellation() async {
        let transaction = ImmediateInstallationTransaction()
        var cancellationContinuation: CheckedContinuation<Void, Never>?
        var cancellationCount = 0
        var firstCompleted = false
        var secondCompleted = false

        let committed = await transaction.run(
            prepare: { true },
            commit: { true },
            cancel: {},
            stateDidChange: {}
        )
        #expect(committed)

        let first = Task { @MainActor in
            await transaction.cancelOwnedReservation(
                cancel: {
                    cancellationCount += 1
                    await withCheckedContinuation { cancellationContinuation = $0 }
                },
                stateDidChange: {}
            )
            firstCompleted = true
        }
        await Task.yield()

        let second = Task { @MainActor in
            await transaction.cancelOwnedReservation(
                cancel: { cancellationCount += 1 },
                stateDidChange: {}
            )
            secondCompleted = true
        }
        await Task.yield()

        #expect(cancellationCount == 1)
        #expect(!firstCompleted)
        #expect(!secondCompleted)

        cancellationContinuation?.resume()
        await first.value
        await second.value
        #expect(firstCompleted)
        #expect(secondCompleted)
        #expect(!transaction.isInFlight)
    }

    @Test @MainActor
    func commitFailureCleanupJoinsConcurrentTerminalCleanup() async {
        let transaction = ImmediateInstallationTransaction()
        var cancellationContinuation: CheckedContinuation<Void, Never>?
        var cancellationCount = 0
        var commitFailureCompleted = false
        var terminalCleanupCompleted = false

        let commitFailure = Task { @MainActor in
            let committed = await transaction.run(
                prepare: { true },
                commit: { false },
                cancel: {
                    cancellationCount += 1
                    await withCheckedContinuation { cancellationContinuation = $0 }
                },
                stateDidChange: {}
            )
            #expect(!committed)
            commitFailureCompleted = true
        }
        await Task.yield()

        let terminalCleanup = Task { @MainActor in
            await transaction.cancelOwnedReservation(
                cancel: { cancellationCount += 1 },
                stateDidChange: {}
            )
            terminalCleanupCompleted = true
        }
        await Task.yield()

        #expect(cancellationCount == 1)
        #expect(!commitFailureCompleted)
        #expect(!terminalCleanupCompleted)

        cancellationContinuation?.resume()
        await commitFailure.value
        await terminalCleanup.value
        #expect(commitFailureCompleted)
        #expect(terminalCleanupCompleted)
        #expect(!transaction.isInFlight)
    }

    @Test @MainActor
    func prepareFailureJoinsConcurrentTerminalCleanup() async {
        let transaction = ImmediateInstallationTransaction()
        var preparationContinuation: CheckedContinuation<Void, Never>?
        var cancellationContinuation: CheckedContinuation<Void, Never>?
        var cancellationCount = 0
        var prepareFailureCompleted = false
        var terminalCleanupCompleted = false

        let prepareFailure = Task { @MainActor in
            let committed = await transaction.run(
                prepare: {
                    await withCheckedContinuation { preparationContinuation = $0 }
                    return false
                },
                commit: { true },
                cancel: {},
                stateDidChange: {}
            )
            #expect(!committed)
            prepareFailureCompleted = true
        }
        await Task.yield()

        let terminalCleanup = Task { @MainActor in
            await transaction.cancelOwnedReservation(
                cancel: {
                    cancellationCount += 1
                    await withCheckedContinuation { cancellationContinuation = $0 }
                },
                stateDidChange: {}
            )
            terminalCleanupCompleted = true
        }
        await Task.yield()

        preparationContinuation?.resume()
        await Task.yield()
        #expect(cancellationCount == 1)
        #expect(!prepareFailureCompleted)
        #expect(!terminalCleanupCompleted)

        cancellationContinuation?.resume()
        await prepareFailure.value
        await terminalCleanup.value
        #expect(prepareFailureCompleted)
        #expect(terminalCleanupCompleted)
        #expect(!transaction.isInFlight)
    }

}
