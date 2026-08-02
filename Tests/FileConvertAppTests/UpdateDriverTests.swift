import Foundation
import Sparkle
import Testing
@testable import FileConvertApp

@Suite(.serialized)
struct UpdateDriverTests {
    private let release = UpdateRelease(
        version: "0.2.0",
        build: "2",
        releasePageURL: URL(string: "https://github.com/chasedputnam/file-flip/releases/tag/v0.2.0")
    )

    @Test @MainActor
    func permissionAndUpdateChoicesFollowAutomaticPreference() {
        let delegate = RecordingUpdateDriverDelegate()
        delegate.automaticUpdatesEnabled = true
        let driver = FileFlipUpdateDriver(delegate: delegate)

        let permission = driver.permissionResponse()
        #expect(permission.automaticUpdateChecks)
        #expect(permission.automaticUpdateDownloading?.boolValue == true)
        #expect(!permission.sendSystemProfile)

        var automaticChoice: SPUUserUpdateChoice?
        driver.handleUpdateFound(
            release,
            origin: .automatic,
            isTrustedInstallableUpdate: true,
            reply: { automaticChoice = $0 }
        )
        #expect(delegate.foundReleases == [release])
        #expect(delegate.origins == [.automatic])
        #expect(automaticChoice == .install)

        var manualChoice: SPUUserUpdateChoice?
        driver.handleUpdateFound(
            release,
            origin: .userInitiated,
            isTrustedInstallableUpdate: true,
            reply: { manualChoice = $0 }
        )
        #expect(manualChoice == nil)
        driver.beginAvailableUpdateDownload()
        #expect(manualChoice == .install)


        delegate.automaticUpdatesEnabled = false
        var readyChoice: SPUUserUpdateChoice?
        driver.showReady(toInstallAndRelaunch: { readyChoice = $0 })
        #expect(delegate.verificationInstallsOnQuit == [true])
        #expect(readyChoice == nil)
        var rejectedChoice: SPUUserUpdateChoice?
        driver.handleUpdateFound(
            release,
            origin: .automatic,
            isTrustedInstallableUpdate: false,
            reply: { rejectedChoice = $0 }
        )
        #expect(rejectedChoice == .dismiss)
        #expect(delegate.failures.last?.kind == .invalidMetadata)
    }

    @Test @MainActor
    func cancellationProgressVerificationInstallationAndCleanupAreForwarded() {
        let delegate = RecordingUpdateDriverDelegate()
        let driver = FileFlipUpdateDriver(delegate: delegate)
        var cancellationCount = 0

        driver.showUserInitiatedUpdateCheck { cancellationCount += 1 }
        #expect(delegate.userCheckCount == 1)
        driver.cancelAutomaticWork()
        #expect(cancellationCount == 1)
        driver.cancelAutomaticWork()
        #expect(cancellationCount == 1)

        driver.showDownloadInitiated { cancellationCount += 1 }
        driver.showDownloadDidReceiveExpectedContentLength(100)
        driver.showDownloadDidReceiveData(ofLength: 40)
        #expect(delegate.downloadStartCount == 1)
        #expect(delegate.expectedLengths == [100])
        #expect(delegate.receivedLengths == [40])

        driver.showDownloadDidStartExtractingUpdate()
        #expect(delegate.verificationStartCount == 1)
        driver.cancelAutomaticWork(deferUntilCallback: true)
        #expect(cancellationCount == 1)

        var readyChoice: SPUUserUpdateChoice?
        driver.showReady(toInstallAndRelaunch: { readyChoice = $0 })
        #expect(delegate.verificationFinishCount == 1)
        #expect(delegate.verificationInstallsOnQuit == [false])
        #expect(readyChoice == .skip)
        driver.installAndRelaunch()
        #expect(readyChoice == .skip)

        var retryCount = 0
        driver.showInstallingUpdate(withApplicationTerminated: false) { retryCount += 1 }
        #expect(delegate.installationStartCount == 1)
        #expect(driver.hasInstallationRetry)

        var acknowledgementCount = 0
        driver.showUpdaterError(
            NSError(domain: SUSparkleErrorDomain, code: 4_005),
            acknowledgement: { acknowledgementCount += 1 }
        )
        driver.retryInstallation()
        #expect(acknowledgementCount == 1)
        #expect(retryCount == 1)
        #expect(!driver.hasInstallationRetry)

        driver.showUpdateInstalledAndRelaunched(true) { acknowledgementCount += 1 }
        #expect(delegate.installationFinishCount == 1)
        #expect(acknowledgementCount == 2)

        driver.dismissUpdateInstallation()
        #expect(delegate.dismissCount == 2)
    }

    @Test @MainActor
    func disablingDuringAutomaticCheckDismissesBeforeDownload() {
        let delegate = RecordingUpdateDriverDelegate()
        delegate.automaticUpdatesEnabled = false
        let driver = FileFlipUpdateDriver(delegate: delegate)
        var choice: SPUUserUpdateChoice?

        driver.cancelAutomaticWork(deferUntilCallback: true)
        driver.handleUpdateFound(
            release,
            origin: .automatic,
            isTrustedInstallableUpdate: true,
            reply: { choice = $0 }
        )

        #expect(choice == .dismiss)
        #expect(delegate.downloadStartCount == 0)
        #expect(delegate.dismissCount == 1)
    }

    @Test @MainActor
    func automaticErrorsAreAcknowledgedWithoutSettingsInteraction() {
        let delegate = RecordingUpdateDriverDelegate()
        let driver = FileFlipUpdateDriver(delegate: delegate)
        var acknowledgementCount = 0

        driver.showUpdateNotFoundWithError(
            NSError(domain: SUSparkleErrorDomain, code: 1_001),
            acknowledgement: { acknowledgementCount += 1 }
        )
        #expect(delegate.noUpdateCount == 1)
        #expect(acknowledgementCount == 1)

        delegate.updateViewState = UpdateStateReducer.reduce(
            delegate.updateViewState,
            event: .checkStarted(.automatic)
        )
        driver.showUpdaterError(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet),
            acknowledgement: { acknowledgementCount += 1 }
        )
        #expect(delegate.failures.last?.kind == .networkUnavailable)
        #expect(acknowledgementCount == 2)
        driver.finishError()
        #expect(acknowledgementCount == 2)

        delegate.updateViewState = UpdateStateReducer.reduce(
            delegate.updateViewState,
            event: .operationFailed(UpdateFailure(kind: .networkUnavailable))
        )
        delegate.updateViewState = UpdateStateReducer.reduce(
            delegate.updateViewState,
            event: .retryStarted
        )
        driver.showUpdaterError(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet),
            acknowledgement: { acknowledgementCount += 1 }
        )
        #expect(acknowledgementCount == 2)
        driver.finishError()
        driver.finishError()
        #expect(acknowledgementCount == 3)
    }

    @Test @MainActor
    func failureMappingIsPhaseAwareAndNeverExposesRawErrorText() {
        let cases: [(NSError, UpdatePhase, UpdateFailure.Kind)] = [
            (NSError(domain: SUSparkleErrorDomain, code: 3), .idle, .configurationInvalid),
            (NSError(domain: SUSparkleErrorDomain, code: 1_000), .checking(.userInitiated), .invalidMetadata),
            (NSError(domain: SUSparkleErrorDomain, code: 2_001), .downloading, .downloadFailed),
            (NSError(domain: SUSparkleErrorDomain, code: 3_001), .verifying, .verificationFailed),
            (NSError(domain: SUSparkleErrorDomain, code: 4_001), .installing, .installationFailed),
            (NSError(domain: SUSparkleErrorDomain, code: 9_999), .checking(.automatic), .unknown),
            (NSError(domain: "unexpected", code: 1), .checking(.automatic), .unknown),
        ]

        for (error, phase, expectedKind) in cases {
            let failure = FileFlipUpdateDriver.sanitizedFailure(for: error, phase: phase)
            #expect(failure.kind == expectedKind)
            #expect(!failure.message.contains(error.domain))
            #expect(!failure.message.contains("/Users/secret"))
        }

        let nestedNetwork = NSError(
            domain: SUSparkleErrorDomain,
            code: 1_002,
            userInfo: [NSUnderlyingErrorKey: NSError(
                domain: NSURLErrorDomain,
                code: NSURLErrorTimedOut,
                userInfo: [NSLocalizedDescriptionKey: "/Users/secret/private.mov"]
            )]
        )
        #expect(FileFlipUpdateDriver.sanitizedFailure(
            for: nestedNetwork,
            phase: .checking(.automatic)
        ).kind == .networkUnavailable)
    }

    @Test @MainActor
    func releaseLinksAreRestrictedToPublicRepositoryHTTPSPages() {
        let accepted = URL(string: "https://github.com/chasedputnam/file-flip/releases/tag/v0.2.0")
        #expect(FileFlipUpdateDriver.safeReleaseURL(accepted) == accepted)

        let rejected = [
            "http://github.com/chasedputnam/file-flip/releases/tag/v0.2.0",
            "https://github.com/chasedputnam/file-flip/releases-evil/tag/v0.2.0",
            "https://github.com/other/file-flip/releases/tag/v0.2.0",
            "https://user@github.com/chasedputnam/file-flip/releases/tag/v0.2.0",
            "https://github.com:444/chasedputnam/file-flip/releases/tag/v0.2.0",
            "https://example.com/chasedputnam/file-flip/releases/tag/v0.2.0",
        ]
        for value in rejected {
            #expect(FileFlipUpdateDriver.safeReleaseURL(URL(string: value)) == nil)
        }
    }

    @Test @MainActor
    func trustedInstallableUpdateWithoutReleaseLinkIsRejected() {
        let delegate = RecordingUpdateDriverDelegate()
        let driver = FileFlipUpdateDriver(delegate: delegate)
        var choice: SPUUserUpdateChoice?

        driver.handleUpdateFound(
            UpdateRelease(version: "0.2.0", build: "2", releasePageURL: nil),
            origin: .userInitiated,
            isTrustedInstallableUpdate: true,
            reply: { choice = $0 }
        )

        #expect(choice == .dismiss)
        #expect(delegate.foundReleases.isEmpty)
        #expect(delegate.failures.last?.kind == .invalidMetadata)
    }

    @Test @MainActor
    func trustedInstallableUpdateWithForeignReleaseLinkIsRejected() {
        let delegate = RecordingUpdateDriverDelegate()
        let driver = FileFlipUpdateDriver(delegate: delegate)
        var choice: SPUUserUpdateChoice?

        driver.handleUpdateFound(
            UpdateRelease(
                version: "0.2.0",
                build: "2",
                releasePageURL: URL(string: "https://example.com/chasedputnam/file-flip/releases/tag/v0.2.0")
            ),
            origin: .userInitiated,
            isTrustedInstallableUpdate: true,
            reply: { choice = $0 }
        )

        #expect(choice == .dismiss)
        #expect(delegate.foundReleases.isEmpty)
        #expect(delegate.failures.last?.kind == .invalidMetadata)
    }

    @Test @MainActor
    func trustedInstallableUpdateWithPublicReleaseLinkIsAccepted() {
        let delegate = RecordingUpdateDriverDelegate()
        let driver = FileFlipUpdateDriver(delegate: delegate)
        let release = UpdateRelease(
            version: "0.2.0",
            build: "2",
            releasePageURL: URL(string: "https://github.com/chasedputnam/file-flip/releases/tag/v0.2.0")
        )
        var choice: SPUUserUpdateChoice?

        driver.handleUpdateFound(
            release,
            origin: .userInitiated,
            isTrustedInstallableUpdate: true,
            reply: { choice = $0 }
        )

        #expect(choice == nil)
        #expect(delegate.foundReleases == [release])
        #expect(delegate.failures.isEmpty)
    }
}

@MainActor
private final class RecordingUpdateDriverDelegate: FileFlipUpdateDriverDelegate {
    var automaticUpdatesEnabled = false
    var updateViewState = UpdateViewState(
        installedVersion: InstalledVersion(version: "0.1.0", build: "1")
    )
    var userCheckCount = 0
    var foundReleases: [UpdateRelease] = []
    var origins: [UpdateCheckOrigin] = []
    var noUpdateCount = 0
    var downloadStartCount = 0
    var expectedLengths: [UInt64] = []
    var receivedLengths: [UInt64] = []
    var verificationStartCount = 0
    var verificationFinishCount = 0
    var verificationInstallsOnQuit: [Bool] = []
    var installationStartCount = 0
    var installationFinishCount = 0
    var failures: [UpdateFailure] = []
    var dismissCount = 0

    func driverDidStartUserCheck(cancellation: @escaping () -> Void) {
        userCheckCount += 1
    }

    func driverDidFindUpdate(_ release: UpdateRelease, origin: UpdateCheckOrigin) {
        foundReleases.append(release)
        origins.append(origin)
    }

    func driverDidFindNoUpdate() {
        noUpdateCount += 1
    }

    func driverDidStartDownload(cancellation: @escaping () -> Void) {
        downloadStartCount += 1
    }

    func driverDidReceiveExpectedContentLength(_ length: UInt64) {
        expectedLengths.append(length)
    }

    func driverDidReceiveData(length: UInt64) {
        receivedLengths.append(length)
    }

    func driverDidStartVerification() {
        verificationStartCount += 1
    }

    func driverDidFinishVerification(
        installsOnQuit: Bool,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        verificationFinishCount += 1
        verificationInstallsOnQuit.append(installsOnQuit)
    }

    func driverDidStartInstallation(retry: @escaping () -> Void) {
        installationStartCount += 1
    }

    func driverDidFinishInstallation() {
        installationFinishCount += 1
    }

    func driverDidFail(_ failure: UpdateFailure, acknowledgement: @escaping () -> Void) {
        failures.append(failure)
    }

    func driverDidDismiss() {
        dismissCount += 1
    }
}
