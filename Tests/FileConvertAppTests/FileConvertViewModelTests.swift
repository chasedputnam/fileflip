@testable import FileConvertApp
import FileConvertCore
import Foundation
import Testing
import UserNotifications

@MainActor
private final class SnapshotRuntime: ApplicationRuntime {
    var current: ApplicationSnapshot
    private(set) var resolvedTransparencyChoices: [(UUID, UInt32)] = []
    private(set) var resolvedMediaTrackChoices: [(UUID, Int?, Int?)] = []
    private(set) var restoredRecoveries: [(UUID, URL)] = []
    private(set) var acknowledgedRecoveries: [UUID] = []
    var restoreRecoveryError: RecoveryActionError?
    var acknowledgeRecoveryError: RecoveryActionError?
    var suspendRecoveryRestore = false
    private(set) var isRecoveryRestoreSuspended = false
    private var recoveryRestoreContinuation: CheckedContinuation<Void, Never>?
    var permitsUpdateInstallationReservation = true
    private(set) var updateInstallationReservationCount = 0
    private(set) var updateInstallationCancellationCount = 0
    var suspendUpdateInstallationReservation = false
    var suspendUpdateInstallationCancellation = false
    private(set) var isUpdateInstallationReservationSuspended = false
    private(set) var isUpdateInstallationCancellationSuspended = false
    private var updateInstallationReservationContinuation: CheckedContinuation<Void, Never>?
    private var updateInstallationCancellationContinuation: CheckedContinuation<Void, Never>?
    private(set) var savedDefaultsCount = 0
    private(set) var savedRetentionCount = 0

    init(_ snapshot: ApplicationSnapshot) {
        current = snapshot
    }

    func snapshot() async throws -> ApplicationSnapshot { current }
    func authorizeFolders(_ urls: [URL]) async throws {}
    func setFolderEnabled(id: UUID, enabled: Bool) async throws {}
    func removeFolder(id: UUID) async throws {}
    func reauthorizeFolder(id: UUID, url: URL) async throws {}
    func setMonitoringPaused(_ paused: Bool) async throws {}
    func reserveUpdateInstallation() async throws -> Bool {
        updateInstallationReservationCount += 1
        if suspendUpdateInstallationReservation {
            isUpdateInstallationReservationSuspended = true
            await withCheckedContinuation { updateInstallationReservationContinuation = $0 }
            isUpdateInstallationReservationSuspended = false
        }
        return permitsUpdateInstallationReservation
    }
    func cancelUpdateInstallationReservation() async {
        updateInstallationCancellationCount += 1
        if suspendUpdateInstallationCancellation {
            isUpdateInstallationCancellationSuspended = true
            await withCheckedContinuation { updateInstallationCancellationContinuation = $0 }
            isUpdateInstallationCancellationSuspended = false
        }
    }
    func setLaunchAtLogin(_ enabled: Bool) async throws {}
    func saveDefaults(_ defaults: FutureJobDefaults) async throws {
        savedDefaultsCount += 1
    }
    func saveRetention(days: Int, byteLimit: UInt64) async throws {
        savedRetentionCount += 1
    }
    func resolveTransparencyChoice(for item: HistoryItemState, backgroundARGB: UInt32) async throws {
        resolvedTransparencyChoices.append((item.id, backgroundARGB))
    }
    func resolveMediaTrackChoice(for item: HistoryItemState, audioTrack: Int?, subtitleTrack: Int?) async throws {
        resolvedMediaTrackChoices.append((item.id, audioTrack, subtitleTrack))
    }
    func undo(_ item: HistoryItemState) async throws -> UndoResult { throw FileConvertError.destinationExists }
    func restoreToNewFile(_ item: HistoryItemState, destination: URL) async throws -> URL { destination }
    func restoreRecovery(_ item: HistoryItemState, destination: URL) async throws -> URL {
        if suspendRecoveryRestore {
            isRecoveryRestoreSuspended = true
            await withCheckedContinuation { continuation in
                recoveryRestoreContinuation = continuation
            }
            isRecoveryRestoreSuspended = false
        }
        if let restoreRecoveryError { throw restoreRecoveryError }
        restoredRecoveries.append((item.id, destination))
        return destination
    }
    func acknowledgeRecovery(_ item: HistoryItemState) async throws {
        if let acknowledgeRecoveryError { throw acknowledgeRecoveryError }
        acknowledgedRecoveries.append(item.id)
    }
    func clearHistory() async throws {}

    func resumeRecoveryRestore() {
        let continuation = recoveryRestoreContinuation
        recoveryRestoreContinuation = nil
        continuation?.resume()
    }

    func resumeUpdateInstallationReservation() {
        let continuation = updateInstallationReservationContinuation
        updateInstallationReservationContinuation = nil
        continuation?.resume()
    }

    func resumeUpdateInstallationCancellation() {
        let continuation = updateInstallationCancellationContinuation
        updateInstallationCancellationContinuation = nil
        continuation?.resume()
    }
}

@MainActor
private final class RecordingNotificationService: NotificationService {
    struct Posted {
        let identifier: String
        let title: String
        let subtitle: String
        let body: String
        let historyItemID: String?
        let categoryIdentifier: String
        let threadIdentifier: String
        let hasSound: Bool
        let userInfoKeys: Set<String>
    }

    private(set) var posted: [Posted] = []
    private(set) var authorizationRequestCount = 0
    var postSucceeds = true

    func requestAuthorization() async {
        authorizationRequestCount += 1
    }

    func post(identifier: String, content: UNNotificationContent) async -> Bool {
        posted.append(
            Posted(
                identifier: identifier,
                title: content.title,
                subtitle: content.subtitle,
                body: content.body,
                historyItemID: content.userInfo["historyItemID"] as? String,
                categoryIdentifier: content.categoryIdentifier,
                threadIdentifier: content.threadIdentifier,
                hasSound: content.sound != nil,
                userInfoKeys: Set(content.userInfo.keys.compactMap { $0 as? String })
            )
        )
        return postSucceeds
    }
}

@MainActor
private final class RecordingTransparencyChoicePrompter: TransparencyChoicePrompting {
    let choice: TransparencyBackgroundChoice?
    private(set) var fileNames: [String] = []

    init(choice: TransparencyBackgroundChoice?) {
        self.choice = choice
    }

    func chooseBackground(for fileName: String) -> TransparencyBackgroundChoice? {
        fileNames.append(fileName)
        return choice
    }
}

@MainActor
private final class RecordingMediaTrackChoicePrompter: MediaTrackChoicePrompting {
    let selection: MediaTrackPromptSelection?
    private(set) var requests: [(fileName: String, audio: [HistoryItemState.TrackChoiceOption], subtitles: [HistoryItemState.TrackChoiceOption])] = []

    init(selection: MediaTrackPromptSelection?) {
        self.selection = selection
    }

    func chooseTracks(
        for fileName: String,
        audio: [HistoryItemState.TrackChoiceOption],
        subtitles: [HistoryItemState.TrackChoiceOption]
    ) -> MediaTrackPromptSelection? {
        requests.append((fileName, audio, subtitles))
        return selection
    }
}

@MainActor
private final class RecordingRecoveryActionPrompter: RecoveryActionPrompting {
    var confirmsRestore: Bool
    var destination: URL?
    var confirmsManualResolution: Bool
    private(set) var restoreConfirmationIDs: [UUID] = []
    private(set) var destinationChoiceIDs: [UUID] = []
    private(set) var manualConfirmationIDs: [UUID] = []

    init(
        confirmsRestore: Bool = true,
        destination: URL? = nil,
        confirmsManualResolution: Bool = true
    ) {
        self.confirmsRestore = confirmsRestore
        self.destination = destination
        self.confirmsManualResolution = confirmsManualResolution
    }

    func confirmRestore(for item: HistoryItemState) -> Bool {
        restoreConfirmationIDs.append(item.id)
        return confirmsRestore
    }

    func chooseRestoreDestination(for item: HistoryItemState) -> URL? {
        destinationChoiceIDs.append(item.id)
        return destination
    }

    func confirmManualResolution(for item: HistoryItemState) -> Bool {
        manualConfirmationIDs.append(item.id)
        return confirmsManualResolution
    }
}

@Test
func persistedConversionDurationIsNonnegative() {
    let createdAt = Date(timeIntervalSince1970: 100)

    #expect(conversionDuration(createdAt: createdAt, updatedAt: createdAt.addingTimeInterval(125)) == 125)
    #expect(conversionDuration(createdAt: createdAt, updatedAt: createdAt.addingTimeInterval(-1)) == 0)
    #expect(formattedConversionDuration(0) == "0ms")
    #expect(formattedConversionDuration(0.125) == "125ms")
    #expect(formattedConversionDuration(0.9999) == "999ms")
    #expect(formattedConversionDuration(1) == "1s")
    #expect(formattedConversionDuration(125) == "2m 5s")
    #expect(formattedConversionDuration(3_661) == "1h 1m")
}

@MainActor
@Test
func latestConversionOutcomeDrivesMenuIconAndPostsNotifications() async {
    let root = AuthorizedRoot(url: URL(fileURLWithPath: "/Users/example/Downloads"), volumeUUID: UUID())
    let runtime = SnapshotRuntime(snapshot(root: root, history: []))
    let notifications = RecordingNotificationService()
    let model = FileConvertViewModel(runtime: runtime, notificationService: notifications)

    await model.refresh()
    #expect(model.state.status == .monitoring)
    #expect(model.state.status.systemImage == "externaldrive.badge.checkmark")
    #expect(notifications.posted.isEmpty)
    #expect(notifications.authorizationRequestCount == 1)

    let inFlightID = UUID()
    let converting = historyItem(
        id: inFlightID,
        fileName: "Screenshot 2026-07-24 211244.jpg",
        outcome: .converting,
        date: Date()
    )
    runtime.current = snapshot(root: root, history: [converting])
    await model.refresh()
    #expect(notifications.posted.isEmpty)

    let failed = historyItem(
        id: inFlightID,
        fileName: "Screenshot 2026-07-24 211244.jpg",
        outcome: .failed,
        date: Date()
    )
    runtime.current = snapshot(root: root, history: [failed])
    await model.refresh()

    #expect(model.state.status == .conversionFailed)
    #expect(model.state.status.systemImage == "externaldrive.fill.badge.exclamationmark")
    #expect(notifications.posted.count == 1)
    #expect(notifications.posted[0].title == "Conversion failed")
    #expect(notifications.posted[0].subtitle == "PNG → JPEG")
    #expect(notifications.posted[0].body == "Screenshot 2026-07-24 211244.jpg could not be converted. The original filename was restored. Open Conversion History for details before trying again.")
    #expect(notifications.authorizationRequestCount == 1)
    #expect(notifications.posted[0].historyItemID == failed.id.uuidString)
    #expect(notifications.posted[0].categoryIdentifier == "FILEFLIP_HISTORY")
    #expect(notifications.posted[0].threadIdentifier == "fileflip.conversions")
    #expect(notifications.posted[0].identifier == "fileconvert-\(failed.id.uuidString)-failed")
    #expect(notifications.posted[0].hasSound)
    #expect(notifications.posted[0].userInfoKeys == ["historyItemID"])

    let succeeded = historyItem(
        fileName: "/Users/example/Downloads/photo.jpg",
        outcome: .succeeded,
        date: Date().addingTimeInterval(1),
        conversionDuration: 125
    )
    runtime.current = snapshot(root: root, history: [succeeded, failed])
    await model.refresh()

    #expect(model.state.status == .monitoring)
    #expect(model.state.status.systemImage == "externaldrive.badge.checkmark")
    #expect(notifications.posted.count == 2)
    #expect(notifications.posted[1].title == "Conversion complete")
    #expect(notifications.posted[1].subtitle == "PNG → JPEG · 2m 5s")
    #expect(notifications.posted[1].body == "photo.jpg was converted successfully.")
    #expect(notifications.posted[1].historyItemID == succeeded.id.uuidString)
    #expect(notifications.posted[1].categoryIdentifier == "FILEFLIP_HISTORY")
    #expect(notifications.posted[1].threadIdentifier == "fileflip.conversions")
    #expect(notifications.posted[1].hasSound)
    #expect(notifications.posted[1].userInfoKeys == ["historyItemID"])

    let succeededWithoutDuration = historyItem(
        fileName: "second.jpg",
        outcome: .succeeded,
        date: Date().addingTimeInterval(2)
    )
    runtime.current = snapshot(root: root, history: [succeededWithoutDuration, succeeded, failed])
    await model.refresh()

    #expect(notifications.posted.count == 3)
    #expect(notifications.posted[2].subtitle == "PNG → JPEG")
}

@MainActor
@Test
func notificationHistoryNavigationSelectsRequestedItemAndCompletesOnce() async {
    let root = AuthorizedRoot(url: URL(fileURLWithPath: "/Users/example/Downloads"), volumeUUID: UUID())
    let newest = historyItem(fileName: "newest.jpg", outcome: .succeeded, date: Date())
    let requested = historyItem(fileName: "failed.png", outcome: .failed, date: Date().addingTimeInterval(-1))
    let runtime = SnapshotRuntime(snapshot(root: root, history: [newest, requested]))
    let model = FileConvertViewModel(runtime: runtime, notificationService: RecordingNotificationService())
    await model.refresh()

    model.requestHistoryNavigation(itemID: requested.id)

    #expect(model.state.selectedHistoryID == requested.id)
    let request = try! #require(model.historyNavigationRequest)
    #expect(request.itemID == requested.id)
    model.completeHistoryNavigation(request)
    #expect(model.historyNavigationRequest == nil)
    #expect(model.state.selectedHistoryID == requested.id)
}

@MainActor
@Test
func transparencyChoicePromptsOnceAndResumesWithSelectedBackground() async {
    let root = AuthorizedRoot(url: URL(fileURLWithPath: "/Users/example/Downloads"), volumeUUID: UUID())
    let item = historyItem(
        fileName: "Screenshot 2026-07-24 211244.jpg",
        outcome: .failed,
        date: Date(),
        requiredChoice: .transparencyBackground
    )
    let runtime = SnapshotRuntime(snapshot(root: root, history: [item]))
    let prompter = RecordingTransparencyChoicePrompter(choice: .white)
    let model = FileConvertViewModel(
        runtime: runtime,
        notificationService: RecordingNotificationService(),
        transparencyChoicePrompter: prompter
    )

    await model.refresh()
    #expect(model.state.defaults.image.alphaBackgroundARGB == 0xFFFF_FFFF)

    await model.refresh()
    #expect(prompter.fileNames == [item.fileName])
    #expect(runtime.resolvedTransparencyChoices.count == 1)
    #expect(runtime.resolvedTransparencyChoices[0].0 == item.id)
    #expect(runtime.resolvedTransparencyChoices[0].1 == 0xFFFF_FFFF)
}

@MainActor
@Test(arguments: [UInt32(0xFFFF_FFFF), UInt32(0xFF00_0000)])
func configuredTransparencyBackgroundSuppressesPrompt(_ backgroundARGB: UInt32) async {
    let root = AuthorizedRoot(url: URL(fileURLWithPath: "/Users/example/Downloads"), volumeUUID: UUID())
    let item = historyItem(
        fileName: "transparent.jpg",
        outcome: .failed,
        date: Date(),
        requiredChoice: .transparencyBackground
    )
    var defaults = FutureJobDefaults()
    defaults.image.alphaBackgroundARGB = backgroundARGB
    let runtime = SnapshotRuntime(snapshot(root: root, history: [item], defaults: defaults))
    let prompter = RecordingTransparencyChoicePrompter(choice: .white)
    let model = FileConvertViewModel(
        runtime: runtime,
        notificationService: RecordingNotificationService(),
        transparencyChoicePrompter: prompter
    )

    await model.refresh()

    #expect(model.state.defaults.image.alphaBackgroundARGB == backgroundARGB)
    #expect(prompter.fileNames.isEmpty)
    #expect(runtime.resolvedTransparencyChoices.isEmpty)
}

@MainActor
@Test
func mediaTrackChoiceUsesOneCombinedPromptAndResumesOnce() async {
    let root = AuthorizedRoot(url: URL(fileURLWithPath: "/Users/example/Downloads"), volumeUUID: UUID())
    let audio = [
        HistoryItemState.TrackChoiceOption(index: 0, label: "Track 1 · eng · aac"),
        HistoryItemState.TrackChoiceOption(index: 1, label: "Track 2 · spa · aac"),
    ]
    let subtitles = [
        HistoryItemState.TrackChoiceOption(index: 0, label: "Track 1 · eng · subrip"),
        HistoryItemState.TrackChoiceOption(index: 1, label: "Track 2 · fra · subrip"),
    ]
    let item = historyItem(
        fileName: "movie.mp4",
        outcome: .failed,
        date: Date(),
        requiredChoice: .mediaTracks(audio: audio, subtitles: subtitles),
        targetFormat: "Video · MP4"
    )
    let runtime = SnapshotRuntime(snapshot(root: root, history: [item]))
    let prompter = RecordingMediaTrackChoicePrompter(
        selection: MediaTrackPromptSelection(audioTrack: 1, subtitleTrack: nil)
    )
    let model = FileConvertViewModel(
        runtime: runtime,
        notificationService: RecordingNotificationService(),
        mediaTrackChoicePrompter: prompter
    )

    await model.refresh()
    await model.refresh()

    #expect(prompter.requests.count == 1)
    #expect(prompter.requests[0].fileName == "movie.mp4")
    #expect(prompter.requests[0].audio == audio)
    #expect(prompter.requests[0].subtitles == subtitles)
    #expect(runtime.resolvedMediaTrackChoices.count == 1)
    #expect(runtime.resolvedMediaTrackChoices[0].0 == item.id)
    #expect(runtime.resolvedMediaTrackChoices[0].1 == 1)
    #expect(runtime.resolvedMediaTrackChoices[0].2 == nil)
}

@MainActor
@Test
func recoveryActionsFollowRecordedJobStateInsteadOfCurrentDefault() async {
    let root = AuthorizedRoot(url: URL(fileURLWithPath: "/Users/example/Downloads"), volumeUUID: UUID())
    var item = historyItem(fileName: "draft.pdf", outcome: .needsRecovery, date: Date())
    item.recoveryState = .unresolved(artifact: .available)
    item.recoveryOriginalFilename = "draft.docx"
    let destination = URL(fileURLWithPath: "/Users/example/Downloads/draft — Recovered.docx")
    var defaults = FutureJobDefaults()
    defaults.conversionBehavior = .keepOriginal
    let runtime = SnapshotRuntime(snapshot(root: root, history: [item], defaults: defaults))
    let prompter = RecordingRecoveryActionPrompter(destination: destination)
    let model = FileConvertViewModel(
        runtime: runtime,
        notificationService: RecordingNotificationService(),
        recoveryActionPrompter: prompter
    )

    await model.refresh()
    model.restoreRecovery(item)
    while model.isPerformingAction { await Task.yield() }

    #expect(prompter.restoreConfirmationIDs == [item.id])
    #expect(prompter.destinationChoiceIDs == [item.id])
    #expect(runtime.restoredRecoveries.count == 1)
    #expect(runtime.restoredRecoveries[0].0 == item.id)
    #expect(runtime.restoredRecoveries[0].1 == destination)
    #expect(model.alert == nil)
}

@MainActor
@Test
func manualRecoveryResolutionRequiresConfirmation() async {
    let root = AuthorizedRoot(url: URL(fileURLWithPath: "/Users/example/Downloads"), volumeUUID: UUID())
    var item = historyItem(fileName: "draft.pdf", outcome: .needsRecovery, date: Date())
    item.recoveryState = .unresolved(artifact: .available)
    let runtime = SnapshotRuntime(snapshot(root: root, history: [item]))
    let prompter = RecordingRecoveryActionPrompter(confirmsManualResolution: false)
    let model = FileConvertViewModel(
        runtime: runtime,
        notificationService: RecordingNotificationService(),
        recoveryActionPrompter: prompter
    )

    await model.refresh()
    model.acknowledgeRecovery(item)
    #expect(runtime.acknowledgedRecoveries.isEmpty)
    #expect(model.alert == nil)

    prompter.confirmsManualResolution = true
    model.acknowledgeRecovery(item)
    while model.isPerformingAction { await Task.yield() }

    #expect(prompter.manualConfirmationIDs == [item.id, item.id])
    #expect(runtime.acknowledgedRecoveries == [item.id])
    #expect(model.alert == nil)
}

@MainActor
@Test
func unresolvedRecoveryStatusTracksAllItemsAndLastResolution() async {
    let root = AuthorizedRoot(url: URL(fileURLWithPath: "/Users/example/Downloads"), volumeUUID: UUID())
    let runtime = SnapshotRuntime(snapshot(root: root, history: []))
    let notifications = RecordingNotificationService()
    let model = FileConvertViewModel(runtime: runtime, notificationService: notifications)
    await model.refresh()

    var older = historyItem(fileName: "older.pdf", outcome: .needsRecovery, date: Date())
    older.recoveryState = .unresolved(artifact: .available)
    var newer = historyItem(
        fileName: "newer.pdf",
        outcome: .needsRecovery,
        date: Date().addingTimeInterval(1)
    )
    newer.recoveryState = .unresolved(artifact: .available)
    runtime.current = snapshot(root: root, history: [newer, older])
    await model.refresh()

    #expect(model.state.status == .needsRecovery)
    #expect(model.state.statusDetail.contains("newer.pdf"))
    #expect(notifications.posted.count == 2)
    #expect(notifications.posted[0].body == "newer.pdf: The conversion needs review. Open Conversion History to review the recovery options.")
    #expect(notifications.posted[0].title == "File recovery required")
    #expect(notifications.posted[0].subtitle == "PNG → JPEG")
    #expect(notifications.posted[0].historyItemID == newer.id.uuidString)
    #expect(notifications.posted[0].categoryIdentifier == "FILEFLIP_RECOVERY")

    model.requestHistoryNavigation(itemID: newer.id)
    #expect(model.state.selectedHistoryID == newer.id)
    #expect(model.historyNavigationRequest?.itemID == newer.id)

    newer.recoveryState = .resolvedByRestore(filename: "newer — Recovered.docx", date: Date())
    runtime.current = snapshot(root: root, history: [newer, older])
    await model.refresh()
    #expect(model.state.status == .needsRecovery)
    #expect(model.state.statusDetail.contains("older.pdf"))

    older.recoveryState = .resolvedManually(date: Date())
    runtime.current = snapshot(root: root, history: [newer, older])
    await model.refresh()
    #expect(model.state.status == .monitoring)
}

@MainActor
@Test
func recoveryRestoreCancellationDoesNotCallRuntime() async {
    let root = AuthorizedRoot(url: URL(fileURLWithPath: "/Users/example/Downloads"), volumeUUID: UUID())
    var item = historyItem(fileName: "draft.pdf", outcome: .needsRecovery, date: Date())
    item.recoveryState = .unresolved(artifact: .available)
    let runtime = SnapshotRuntime(snapshot(root: root, history: [item]))
    let prompter = RecordingRecoveryActionPrompter(confirmsRestore: false)
    let model = FileConvertViewModel(
        runtime: runtime,
        notificationService: RecordingNotificationService(),
        recoveryActionPrompter: prompter
    )
    await model.refresh()

    model.restoreRecovery(item)
    #expect(runtime.restoredRecoveries.isEmpty)
    #expect(prompter.destinationChoiceIDs.isEmpty)

    prompter.confirmsRestore = true
    prompter.destination = nil
    model.restoreRecovery(item)
    #expect(runtime.restoredRecoveries.isEmpty)
    #expect(prompter.destinationChoiceIDs == [item.id])
}

@MainActor
@Test
func recoveryErrorsProduceSpecificActionableAlerts() async {
    let root = AuthorizedRoot(url: URL(fileURLWithPath: "/Users/example/Downloads"), volumeUUID: UUID())
    var item = historyItem(fileName: "draft.pdf", outcome: .needsRecovery, date: Date())
    item.recoveryState = .unresolved(artifact: .available)
    let destination = URL(fileURLWithPath: "/Users/example/Downloads/draft — Recovered.docx")
    let runtime = SnapshotRuntime(snapshot(root: root, history: [item]))
    let model = FileConvertViewModel(
        runtime: runtime,
        notificationService: RecordingNotificationService(),
        recoveryActionPrompter: RecordingRecoveryActionPrompter(destination: destination)
    )
    await model.refresh()

    let cases: [(RecoveryActionError, String)] = [
        (.invalidRecovery, "This recovery item is no longer unresolved. Refresh Conversion History and review its current status."),
        (.destinationExists, "That destination is already occupied. No files were changed. Choose a different destination and try again."),
        (.artifactUnavailable, "The retained recovery data is unavailable. No file was restored. You can keep the item unresolved or mark it as resolved manually."),
        (.integrityFailure, "The retained recovery data failed its integrity check. No file was restored."),
        (.permissionDenied, "FileFlip cannot write to that destination. No file was restored. Choose a writable location."),
        (.publicationFailed, "FileFlip could not publish the restored file. No existing file was changed. Choose another destination and try again."),
        (
            .restoredButResolutionWriteFailed(filename: destination.lastPathComponent),
            "\(destination.lastPathComponent) was restored, but FileFlip could not update recovery status. Keep the restored file and retry or mark the item as resolved."
        ),
    ]
    for (error, message) in cases {
        runtime.restoreRecoveryError = error
        model.restoreRecovery(item)
        while model.isPerformingAction { await Task.yield() }
        #expect(model.alert?.title == "Action Could Not Be Completed")
        #expect(model.alert?.message == message)
        model.dismissAlert()
    }

    runtime.acknowledgeRecoveryError = .resolutionWriteFailed
    model.acknowledgeRecovery(item)
    while model.isPerformingAction { await Task.yield() }
    #expect(model.alert?.message == "FileFlip could not mark this item as resolved. It remains unresolved, and its retained recovery data stays protected.")
}

@MainActor
@Test
func startupDoesNotRetainPriorFailureInMenuIcon() async {
    let root = AuthorizedRoot(url: URL(fileURLWithPath: "/Users/example/Downloads"), volumeUUID: UUID())
    let priorFailure = historyItem(fileName: "old-failure.jpg", outcome: .failed, date: Date())
    let notifications = RecordingNotificationService()
    let model = FileConvertViewModel(
        runtime: SnapshotRuntime(snapshot(root: root, history: [priorFailure])),
        notificationService: notifications
    )

    await model.refresh()

    #expect(model.state.status == .monitoring)
    #expect(model.state.status.systemImage == "externaldrive.badge.checkmark")
    #expect(notifications.posted.isEmpty)
}
@MainActor
@Test
func deniedNotificationDeliveryDoesNotCreateInAppFallbackOrReplayUnchangedOutcome() async {
    let root = AuthorizedRoot(url: URL(fileURLWithPath: "/Users/example/Downloads"), volumeUUID: UUID())
    let runtime = SnapshotRuntime(snapshot(root: root, history: []))
    let notifications = RecordingNotificationService()
    notifications.postSucceeds = false
    let model = FileConvertViewModel(runtime: runtime, notificationService: notifications)
    await model.refresh()

    let failed = historyItem(fileName: "private/failure.jpg", outcome: .failed, date: Date())
    runtime.current = snapshot(root: root, history: [failed])
    await model.refresh()

    #expect(notifications.posted.count == 1)
    #expect(notifications.posted[0].body.hasPrefix("failure.jpg "))
    #expect(model.alert == nil)

    await model.refresh()
    #expect(notifications.posted.count == 1)
}

@MainActor
@Test
func immediateUpdateInstallationSafetyTracksLoadedAndConvertingState() async {
    let root = AuthorizedRoot(url: URL(fileURLWithPath: "/Users/example/Downloads"), volumeUUID: UUID())
    let runtime = SnapshotRuntime(snapshot(root: root, history: []))
    let model = FileConvertViewModel(
        runtime: runtime,
        notificationService: RecordingNotificationService()
    )
    var reportedSafety: [Bool] = []
    model.onImmediateUpdateInstallSafetyChanged = { reportedSafety.append($0) }

    #expect(!model.isImmediateUpdateInstallSafe)
    await model.refresh()
    #expect(model.isImmediateUpdateInstallSafe)

    runtime.current = snapshot(root: root, history: [], convertingCount: 1)
    #expect(model.isImmediateUpdateInstallSafe)
    let refreshedSafety = await model.refreshImmediateUpdateInstallSafety()
    #expect(!refreshedSafety)
    #expect(!model.isImmediateUpdateInstallSafe)

    runtime.current = snapshot(root: root, history: [])
    await model.refresh()
    #expect(model.isImmediateUpdateInstallSafe)
    #expect(reportedSafety == [false, true, false, true])
}

@MainActor
@Test
func immediateUpdateInstallationUsesRuntimeReservation() async {
    let root = AuthorizedRoot(url: URL(fileURLWithPath: "/Users/example/Downloads"), volumeUUID: UUID())
    let runtime = SnapshotRuntime(snapshot(root: root, history: []))
    let model = FileConvertViewModel(
        runtime: runtime,
        notificationService: RecordingNotificationService()
    )

    await model.refresh()
    let reserved = await model.reserveImmediateUpdateInstallation()
    #expect(reserved)
    #expect(runtime.updateInstallationReservationCount == 1)

    await model.cancelUpdateInstallationReservation()
    #expect(runtime.updateInstallationCancellationCount == 1)
}

@MainActor
@Test
func immediateUpdateReservationKeepsActionsDisabledThroughReserveAndCleanup() async {
    let root = AuthorizedRoot(url: URL(fileURLWithPath: "/Users/example/Downloads"), volumeUUID: UUID())
    let runtime = SnapshotRuntime(snapshot(root: root, history: []))
    runtime.suspendUpdateInstallationReservation = true
    let model = FileConvertViewModel(
        runtime: runtime,
        notificationService: RecordingNotificationService()
    )
    await model.refresh()

    let reservation = Task { @MainActor in
        await model.reserveImmediateUpdateInstallation()
    }
    await Task.yield()
    #expect(runtime.isUpdateInstallationReservationSuspended)
    #expect(model.isPerformingAction)

    runtime.resumeUpdateInstallationReservation()
    let reserved = await reservation.value
    #expect(reserved)
    #expect(model.isPerformingAction)

    runtime.suspendUpdateInstallationCancellation = true
    let cancellation = Task { @MainActor in
        await model.cancelUpdateInstallationReservation()
    }
    await Task.yield()
    #expect(runtime.isUpdateInstallationCancellationSuspended)
    #expect(model.isPerformingAction)

    runtime.resumeUpdateInstallationCancellation()
    await cancellation.value
    #expect(!model.isPerformingAction)
}

@MainActor
@Test
func recoveryPromptIsNotPresentedWhileUpdateReservationIsInFlight() async {
    let root = AuthorizedRoot(url: URL(fileURLWithPath: "/Users/example/Downloads"), volumeUUID: UUID())
    var item = historyItem(fileName: "draft.pdf", outcome: .needsRecovery, date: Date())
    item.recoveryState = .unresolved(artifact: .available)
    let runtime = SnapshotRuntime(snapshot(root: root, history: [item]))
    runtime.suspendUpdateInstallationReservation = true
    let prompter = RecordingRecoveryActionPrompter()
    let model = FileConvertViewModel(
        runtime: runtime,
        notificationService: RecordingNotificationService(),
        recoveryActionPrompter: prompter
    )
    await model.refresh()

    let reservation = Task { @MainActor in
        await model.reserveImmediateUpdateInstallation()
    }
    await Task.yield()
    #expect(model.isPerformingAction)

    model.acknowledgeRecovery(item)
    #expect(prompter.manualConfirmationIDs.isEmpty)

    runtime.resumeUpdateInstallationReservation()
    _ = await reservation.value
    await model.cancelUpdateInstallationReservation()
}

@MainActor
@Test
func defaultsAndRetentionMutationsAreRejectedDuringUpdateReservation() async {
    let root = AuthorizedRoot(url: URL(fileURLWithPath: "/Users/example/Downloads"), volumeUUID: UUID())
    let runtime = SnapshotRuntime(snapshot(root: root, history: []))
    let model = FileConvertViewModel(
        runtime: runtime,
        notificationService: RecordingNotificationService()
    )
    await model.refresh()
    let reserved = await model.reserveImmediateUpdateInstallation()
    #expect(reserved)

    let originalDefaults = model.state.defaults
    let originalDays = model.state.backup.retentionDays
    let originalLimit = model.state.backup.limitBytes
    var changedDefaults = originalDefaults
    changedDefaults.image.quality = 0.5
    let changedDays = originalDays == 7 ? 30 : 7
    let changedLimit = originalLimit == UInt64(5 << 30) ? UInt64(10 << 30) : UInt64(5 << 30)

    model.updateDefaults(changedDefaults)
    model.updateRetention(days: changedDays, byteLimit: changedLimit)

    #expect(model.state.defaults == originalDefaults)
    #expect(model.state.backup.retentionDays == originalDays)
    #expect(model.state.backup.limitBytes == originalLimit)
    #expect(runtime.savedDefaultsCount == 0)
    #expect(runtime.savedRetentionCount == 0)

    await model.cancelUpdateInstallationReservation()
}


@MainActor
@Test
func immediateUpdateInstallationWaitsForRecoveryWorkToFinish() async {
    let root = AuthorizedRoot(url: URL(fileURLWithPath: "/Users/example/Downloads"), volumeUUID: UUID())
    var item = historyItem(fileName: "draft.pdf", outcome: .needsRecovery, date: Date())
    item.recoveryState = .unresolved(artifact: .available)
    let destination = URL(fileURLWithPath: "/Users/example/Downloads/draft — Recovered.pdf")
    let runtime = SnapshotRuntime(snapshot(root: root, history: [item]))
    runtime.suspendRecoveryRestore = true
    let model = FileConvertViewModel(
        runtime: runtime,
        notificationService: RecordingNotificationService(),
        recoveryActionPrompter: RecordingRecoveryActionPrompter(destination: destination)
    )

    await model.refresh()
    #expect(model.isImmediateUpdateInstallSafe)

    model.restoreRecovery(item)
    #expect(!model.isImmediateUpdateInstallSafe)
    while !runtime.isRecoveryRestoreSuspended { await Task.yield() }
    #expect(!model.isImmediateUpdateInstallSafe)

    runtime.resumeRecoveryRestore()
    while model.isPerformingAction { await Task.yield() }
    #expect(model.isImmediateUpdateInstallSafe)
}



private func snapshot(
    root: AuthorizedRoot,
    history: [HistoryItemState],
    defaults: FutureJobDefaults = FutureJobDefaults(),
    convertingCount: Int = 0
) -> ApplicationSnapshot {
    ApplicationSnapshot(
        monitoringStatus: .monitoring,
        convertingCount: convertingCount,
        roots: [root],
        providers: [],
        history: history,
        backupUsage: 0,
        backupLimit: 10 << 30,
        retentionDays: 30,
        launchAtLoginStatus: .disabled,
        defaults: defaults
    )
}

private func historyItem(
    id: UUID = UUID(),
    fileName: String,
    outcome: PersistentJobState,
    date: Date,
    requiredChoice: HistoryItemState.RequiredChoice? = nil,
    targetFormat: String = "JPEG",
    conversionDuration: TimeInterval? = nil
) -> HistoryItemState {
    HistoryItemState(
        id: id,
        rootID: UUID(),
        fileName: fileName,
        sourceFormat: "PNG",
        targetFormat: targetFormat,
        outcome: outcome,
        conversionBehavior: .replaceWithBackup,
        date: date,
        conversionDuration: conversionDuration,
        providerName: "Native Image",
        providerVersion: "1",
        fidelityWarning: nil,
        errorSummary: outcome == .failed ? "The conversion failed." : nil,
        requiredChoice: requiredChoice,
        availability: .unavailable
    )
}
