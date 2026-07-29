import AppKit
import FileConvertCore
import Foundation
import Observation
import UserNotifications

struct AppAlertState: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
    enum Action: Equatable {
        case reveal(URL)
    }

    var action: Action? = nil
}

struct HistoryNavigationRequest: Equatable {
    let id = UUID()
    let itemID: UUID?
}

enum TransparencyBackgroundChoice: Sendable {
    case white
    case black

    var argb: UInt32 {
        switch self {
        case .white: 0xFFFF_FFFF
        case .black: 0xFF00_0000
        }
    }
}

@MainActor
protocol TransparencyChoicePrompting: AnyObject {
    func chooseBackground(for fileName: String) -> TransparencyBackgroundChoice?
}

@MainActor
final class SystemTransparencyChoicePrompter: TransparencyChoicePrompting {
    func chooseBackground(for fileName: String) -> TransparencyBackgroundChoice? {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let prompt = NSAlert()
        prompt.alertStyle = .informational
        prompt.messageText = "Choose a transparency background"
        prompt.informativeText = "\(fileName) contains transparency, but JPEG does not. Choose the background FileFlip should use for this and future conversions."
        prompt.addButton(withTitle: "White Background")
        prompt.addButton(withTitle: "Black Background")
        prompt.addButton(withTitle: "Cancel")
        switch prompt.runModal() {
        case .alertFirstButtonReturn:
            return TransparencyBackgroundChoice.white
        case .alertSecondButtonReturn:
            return TransparencyBackgroundChoice.black
        default:
            return nil
        }
    }
}

struct MediaTrackPromptSelection: Sendable {
    let audioTrack: Int?
    let subtitleTrack: Int?
}

@MainActor
protocol MediaTrackChoicePrompting: AnyObject {
    func chooseTracks(
        for fileName: String,
        audio: [HistoryItemState.TrackChoiceOption],
        subtitles: [HistoryItemState.TrackChoiceOption]
    ) -> MediaTrackPromptSelection?
}

@MainActor
final class SystemMediaTrackChoicePrompter: MediaTrackChoicePrompting {
    func chooseTracks(
        for fileName: String,
        audio: [HistoryItemState.TrackChoiceOption],
        subtitles: [HistoryItemState.TrackChoiceOption]
    ) -> MediaTrackPromptSelection? {
        guard !audio.isEmpty || !subtitles.isEmpty else { return nil }
        NSApplication.shared.activate(ignoringOtherApps: true)
        let prompt = NSAlert()
        prompt.alertStyle = .informational
        prompt.messageText = "Choose media tracks"
        prompt.informativeText = "\(fileName) contains multiple eligible tracks. Choose the input FileFlip should convert."

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        let audioPicker = Self.addPicker(title: "Audio Track", options: audio, allowsNone: false, to: stack)
        let subtitlePicker = Self.addPicker(title: "Video Subtitle Track", options: subtitles, allowsNone: true, to: stack)
        stack.frame = NSRect(x: 0, y: 0, width: 360, height: CGFloat(stack.arrangedSubviews.count) * 28)
        prompt.accessoryView = stack
        prompt.addButton(withTitle: "Continue")
        prompt.addButton(withTitle: "Cancel")
        guard prompt.runModal() == .alertFirstButtonReturn else { return nil }
        let subtitleSelection = subtitlePicker.flatMap { picker -> Int? in
            guard picker.indexOfSelectedItem > 0 else { return nil }
            return subtitles[picker.indexOfSelectedItem - 1].index
        }
        return MediaTrackPromptSelection(
            audioTrack: audioPicker.map { audio[$0.indexOfSelectedItem].index },
            subtitleTrack: subtitleSelection
        )
    }

    private static func addPicker(
        title: String,
        options: [HistoryItemState.TrackChoiceOption],
        allowsNone: Bool,
        to stack: NSStackView
    ) -> NSPopUpButton? {
        guard !options.isEmpty else { return nil }
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        let label = NSTextField(labelWithString: title)
        label.frame.size.width = 120
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 230, height: 26))
        picker.setAccessibilityLabel(title)
        if allowsNone {
            picker.addItem(withTitle: "None")
        }
        picker.addItems(withTitles: options.map(\.label))
        row.addArrangedSubview(label)
        row.addArrangedSubview(picker)
        stack.addArrangedSubview(row)
        return picker
    }
}

@MainActor
protocol RecoveryActionPrompting: AnyObject {
    func confirmRestore(for item: HistoryItemState) -> Bool
    func chooseRestoreDestination(for item: HistoryItemState) -> URL?
    func confirmManualResolution(for item: HistoryItemState) -> Bool
}

@MainActor
final class SystemRecoveryActionPrompter: RecoveryActionPrompting {
    func confirmRestore(for item: HistoryItemState) -> Bool {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let prompt = NSAlert()
        prompt.alertStyle = .informational
        prompt.messageText = "Restore the retained file?"
        prompt.informativeText = "\(item.fileName) needs recovery. FileFlip will create a separate copy of the retained original at a location you choose. The current file will remain unchanged."
        prompt.addButton(withTitle: "Choose Destination…")
        prompt.addButton(withTitle: "Cancel")
        return prompt.runModal() == .alertFirstButtonReturn
    }

    func chooseRestoreDestination(for item: HistoryItemState) -> URL? {
        let panel = NSSavePanel()
        let delegate = UnoccupiedDestinationDelegate()
        panel.delegate = delegate
        panel.title = "Restore Retained File"
        panel.message = "Choose a new destination. FileFlip will not replace an existing file or change the current file."
        panel.prompt = "Restore Copy"
        panel.nameFieldStringValue = Self.recoveredName(
            for: item.recoveryOriginalFilename ?? item.fileName
        )
        panel.directoryURL = item.recoverySuggestedDirectory
        return panel.runModal() == .OK ? panel.url : nil
    }

    func confirmManualResolution(for item: HistoryItemState) -> Bool {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let prompt = NSAlert()
        prompt.alertStyle = .warning
        prompt.messageText = "Mark recovery as resolved?"
        prompt.informativeText = "No file will be restored for \(item.fileName). Recovery warnings will stop, and the retained artifact can be removed by the configured retention policy."
        prompt.addButton(withTitle: "Mark as Resolved")
        prompt.addButton(withTitle: "Cancel")
        return prompt.runModal() == .alertFirstButtonReturn
    }

    private static func recoveredName(for fileName: String) -> String {
        let url = URL(filePath: fileName)
        let stem = url.deletingPathExtension().lastPathComponent
        let suffix = url.pathExtension
        return suffix.isEmpty ? "\(stem) — Recovered" : "\(stem) — Recovered.\(suffix)"
    }
}

private final class UnoccupiedDestinationDelegate: NSObject, NSOpenSavePanelDelegate {
    func panel(_ sender: Any, validate url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw NSError(
                domain: "FileFlip.RecoveryDestination",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Choose a destination that does not already exist."]
            )
        }
    }
}

@MainActor
protocol NotificationService: AnyObject {
    func requestAuthorization() async
    func post(identifier: String, content: UNNotificationContent) async -> Bool
}

@MainActor
final class SystemNotificationService: NotificationService {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func requestAuthorization() async {
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    func post(identifier: String, content: UNNotificationContent) async -> Bool {
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            return false
        }
        do {
            try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
            return true
        } catch {
            return false
        }
    }
}

@MainActor
@Observable
final class FileConvertViewModel {
    private(set) var state = AppViewState()
    private(set) var alert: AppAlertState?
    private(set) var isPerformingAction = false
    private(set) var undoConflict: HistoryItemState?
    private(set) var historyNavigationRequest: HistoryNavigationRequest?
    @ObservationIgnored var onFoldersAuthorized: (() -> Void)?
    @ObservationIgnored private var defaultsSaveTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var isRefreshing = false
    @ObservationIgnored private var hasRequestedNotificationAuthorization = false
    @ObservationIgnored private var promptedTransparencyChoiceIDs: Set<UUID> = []
    @ObservationIgnored private var promptedMediaTrackChoiceIDs: Set<UUID> = []

    private let runtime: any ApplicationRuntime
    private let notificationService: any NotificationService
    private let transparencyChoicePrompter: any TransparencyChoicePrompting
    private let mediaTrackChoicePrompter: any MediaTrackChoicePrompting
    private let recoveryActionPrompter: any RecoveryActionPrompting
    private let folderPicker: FolderPicker
    private var notifiedJobOutcomes: [UUID: PersistentJobState] = [:]
    private var hasLoadedSnapshot = false
    private var latestSessionOutcome: PersistentJobState?
    private var observedJobOutcomes: [UUID: PersistentJobState] = [:]

    init(
        runtime: any ApplicationRuntime,
        notificationService: any NotificationService = SystemNotificationService(),
        transparencyChoicePrompter: any TransparencyChoicePrompting = SystemTransparencyChoicePrompter(),
        mediaTrackChoicePrompter: any MediaTrackChoicePrompting = SystemMediaTrackChoicePrompter(),
        recoveryActionPrompter: any RecoveryActionPrompting = SystemRecoveryActionPrompter(),
        folderPicker: FolderPicker = FolderPicker()
    ) {
        self.runtime = runtime
        self.notificationService = notificationService
        self.transparencyChoicePrompter = transparencyChoicePrompter
        self.mediaTrackChoicePrompter = mediaTrackChoicePrompter
        self.folderPicker = folderPicker
        self.recoveryActionPrompter = recoveryActionPrompter
    }

    func start() async {
        await refresh()
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                await self?.refresh(showAlert: false)
            }
        }
    }

    func refresh(showAlert: Bool = true) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let snapshot = try await runtime.snapshot()
            let priorOutcomes = observedJobOutcomes
            if hasLoadedSnapshot,
               let latest = snapshot.history.first(where: {
                   priorOutcomes[$0.id] != $0.outcome
                       && ($0.outcome == .succeeded || $0.outcome == .failed)
               }) {
                latestSessionOutcome = latest.outcome
            }
            apply(snapshot)
            await resolvePendingTransparencyChoice()
            await resolvePendingMediaTrackChoice()
            if hasLoadedSnapshot {
                await notifyAboutNewActionableItems(previousOutcomes: priorOutcomes)
            } else {
                notifiedJobOutcomes = Dictionary(uniqueKeysWithValues: state.history.map { ($0.id, $0.outcome) })
                hasLoadedSnapshot = true
            }
            observedJobOutcomes = Dictionary(uniqueKeysWithValues: state.history.map { ($0.id, $0.outcome) })
            if !state.folders.isEmpty && !hasRequestedNotificationAuthorization {
                hasRequestedNotificationAuthorization = true
                await notificationService.requestAuthorization()
            }
        } catch {
            state.isLoading = false
            state.status = .blocked
            state.statusDetail = "FileFlip could not load its local state. Your files were not changed."
            if showAlert {
                present(error, title: "Unable to Load FileFlip")
            }
        }
    }

    func chooseFolders() {
        guard let urls = folderPicker.chooseFolders() else { return }
        perform { try await self.runtime.authorizeFolders(urls) }
    }

    func reauthorize(_ folder: WatchedFolderState) {
        guard let url = folderPicker.chooseFolderToReauthorize(named: folder.name) else { return }
        perform { try await self.runtime.reauthorizeFolder(id: folder.id, url: url) }
    }

    func setFolderEnabled(_ folder: WatchedFolderState, enabled: Bool) {
        perform { try await self.runtime.setFolderEnabled(id: folder.id, enabled: enabled) }
    }

    func removeFolder(_ folder: WatchedFolderState) {
        perform { try await self.runtime.removeFolder(id: folder.id) }
    }

    func toggleMonitoring() {
        let pause = !state.isMonitoringPaused
        perform { try await self.runtime.setMonitoringPaused(pause) }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        perform { try await self.runtime.setLaunchAtLogin(enabled) }
    }

    func updateDefaults(_ defaults: FutureJobDefaults) {
        state.defaults = defaults
        defaultsSaveTask?.cancel()
        defaultsSaveTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(150))
                guard let self else { return }
                try await self.runtime.saveDefaults(defaults)
            } catch is CancellationError {
                return
            } catch {
                self?.present(error, title: "Defaults Could Not Be Saved")
            }
        }
    }

    func updateRetention(days: Int? = nil, byteLimit: UInt64? = nil) {
        let newDays = days ?? state.backup.retentionDays
        let newLimit = byteLimit ?? state.backup.limitBytes
        state.backup.retentionDays = newDays
        state.backup.limitBytes = newLimit
        perform { try await self.runtime.saveRetention(days: newDays, byteLimit: newLimit) }
    }

    func undo(_ item: HistoryItemState) {
        perform {
            switch try await self.runtime.undo(item) {
            case .restored:
                self.undoConflict = nil
            case let .conflict(currentURL):
                var conflict = item
                conflict.availability = .undoConflict(currentURL: currentURL)

                self.undoConflict = conflict
            }
        }
    }

    func requestHistoryNavigation(itemID: UUID? = nil) {
        if let itemID {
            selectHistory(itemID)
        }
        historyNavigationRequest = HistoryNavigationRequest(itemID: itemID)
    }

    func completeHistoryNavigation(_ request: HistoryNavigationRequest) {
        if historyNavigationRequest == request {
            historyNavigationRequest = nil
        }
    }

    func restoreConflictToNewFile(_ item: HistoryItemState) {
        let panel = NSSavePanel()
        panel.title = "Restore Original to a New File"
        panel.message = "The current file changed after conversion. Choose a different name so neither version is overwritten."
        panel.prompt = "Restore Copy"
        panel.nameFieldStringValue = Self.keepBothName(for: item.fileName)
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        perform {
            _ = try await self.runtime.restoreToNewFile(item, destination: destination)
            self.undoConflict = nil
        }
    }

    func restoreRecovery(_ item: HistoryItemState) {
        guard item.canRestoreRetainedFile,
              recoveryActionPrompter.confirmRestore(for: item),
              let destination = recoveryActionPrompter.chooseRestoreDestination(for: item) else {
            return
        }
        selectHistory(item.id)
        perform {
            let restored = try await self.runtime.restoreRecovery(item, destination: destination)
            self.alert = AppAlertState(
                title: "Recovery Complete",
                message: "\(restored.lastPathComponent) was restored successfully.",
                action: .reveal(restored)
            )
        }
    }

    func acknowledgeRecovery(_ item: HistoryItemState) {
        guard item.needsRecoveryAction,
              recoveryActionPrompter.confirmManualResolution(for: item) else {
            return
        }
        selectHistory(item.id)
        perform {
            try await self.runtime.acknowledgeRecovery(item)
            self.alert = AppAlertState(
                title: "Recovery Marked Resolved",
                message: "No file was restored. Recovery warnings for \(item.fileName) have stopped."
            )
        }
    }

    func selectHistory(_ id: UUID?) {
        state.selectedHistoryID = id
    }

    func clearHistory() {
        perform { try await self.runtime.clearHistory() }
    }

    func dismissUndoConflict() {
        undoConflict = nil
    }

    func dismissAlert() {
        alert = nil
    }

    func performAlertAction(_ action: AppAlertState.Action) {
        switch action {
        case let .reveal(url):
            if FileManager.default.fileExists(atPath: url.path) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
        alert = nil
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !isPerformingAction else { return }
        isPerformingAction = true
        Task { @MainActor in
            defer { isPerformingAction = false }
            do {
                try await action()
                await refresh()
            } catch {
                present(error, title: "Action Could Not Be Completed")
            }
        }
    }

    private func apply(_ snapshot: ApplicationSnapshot) {
        let hadNoFolders = state.folders.isEmpty
        state.folders = snapshot.roots.map(WatchedFolderState.init)
        state.providers = snapshot.providers
        state.history = Array(snapshot.history.prefix(100))
        state.backup = BackupState(
            usedBytes: snapshot.backupUsage,
            limitBytes: snapshot.backupLimit,
            retentionDays: snapshot.retentionDays
        )
        state.defaults = snapshot.defaults
        state.launchAtLogin = snapshot.launchAtLoginStatus == .enabled
        state.launchAtLoginRequiresApproval = snapshot.launchAtLoginStatus == .requiresApproval
        state.isMonitoringPaused = snapshot.monitoringStatus == .paused
        state.isLoading = false
        if hadNoFolders && !state.folders.isEmpty {
            onFoldersAuthorized?()
        }

        let recovery = state.history.first(where: \.needsRecoveryAction)
        let choice = state.history.first { $0.errorSummary?.contains("fidelity policy") == true }
        let providerFailure = state.history.first.flatMap { item in
            item.errorSummary?.contains("required local provider") == true ? item : nil
        }
        let inaccessibleEnabledRoot = state.folders.contains { $0.isEnabled && $0.status != .active }
        let activeRootCount = state.folders.filter { $0.isEnabled && $0.status == .active }.count

        if let recovery {
            state.status = .needsRecovery
            state.statusDetail = "\(recovery.fileName) needs review. FileFlip will not overwrite either version automatically."
        } else if let choice {
            state.status = .needsChoice
            state.statusDetail = "Choose a future-job policy for \(choice.fileName), then rename it again."
        } else if snapshot.convertingCount > 0 {
            state.status = .converting
            state.statusDetail = snapshot.convertingCount == 1 ? "Converting 1 file locally." : "Converting \(snapshot.convertingCount) files locally."
        } else if latestSessionOutcome == .failed {
            state.status = .conversionFailed
            state.statusDetail = "The last conversion failed. Review Conversion History and the file before trying again."
        } else if state.isMonitoringPaused {
            state.status = .paused
            state.statusDetail = "New rename events will not be queued. A final replacement already in progress may finish safely."
        } else if activeRootCount == 0 && state.folders.contains(where: \.isEnabled) {
            state.status = .blocked
            state.statusDetail = "No enabled folder can be monitored. Reauthorize a folder to continue."
        } else if snapshot.monitoringStatus == .degraded || inaccessibleEnabledRoot || providerFailure != nil {
            state.status = .degraded
            state.statusDetail = providerFailure == nil
                ? "Some monitoring is unavailable. Review watched folders and provider status."
                : "A required local provider is unavailable. Affected formats are disabled; other monitoring remains active."
        } else if activeRootCount > 0 {
            state.status = .monitoring
            state.statusDetail = activeRootCount == 1 ? "Monitoring 1 authorized folder." : "Monitoring \(activeRootCount) authorized folders."
        } else {
            state.status = .idle
            state.statusDetail = "Authorize or enable a folder to begin monitoring."
        }
    }

    private func resolvePendingTransparencyChoice() async {
        guard state.defaults.image.alphaBackgroundARGB == nil,
              let item = state.history.first(where: {
                  $0.requiredChoice == .transparencyBackground
                      && !promptedTransparencyChoiceIDs.contains($0.id)
              }) else {
            return
        }
        promptedTransparencyChoiceIDs.insert(item.id)
        guard let choice = transparencyChoicePrompter.chooseBackground(for: item.fileName) else {
            return
        }

        isPerformingAction = true
        defer { isPerformingAction = false }
        do {
            try await runtime.resolveTransparencyChoice(for: item, backgroundARGB: choice.argb)
            state.defaults.image.alphaBackgroundARGB = choice.argb
        } catch {
            present(error, title: "Conversion Could Not Resume")
        }
    }

    private func resolvePendingMediaTrackChoice() async {
        guard let item = state.history.first(where: {
            guard case .mediaTracks = $0.requiredChoice else { return false }
            return !promptedMediaTrackChoiceIDs.contains($0.id)
        }), case let .mediaTracks(audio, subtitles) = item.requiredChoice else {
            return
        }
        let requestedAudio: [HistoryItemState.TrackChoiceOption]
        let requestedSubtitles: [HistoryItemState.TrackChoiceOption]
        switch item.targetFormat.lowercased() {
        case let target where target.contains("audio"):
            requestedAudio = state.defaults.audio.trackIndex == nil ? audio : []
            requestedSubtitles = []
        default:
            requestedAudio = state.defaults.video.audioTrack == nil ? audio : []
            requestedSubtitles = state.defaults.video.subtitleTrack == nil ? subtitles : []
        }
        guard !requestedAudio.isEmpty || !requestedSubtitles.isEmpty else { return }

        promptedMediaTrackChoiceIDs.insert(item.id)
        guard let selection = mediaTrackChoicePrompter.chooseTracks(
            for: item.fileName,
            audio: requestedAudio,
            subtitles: requestedSubtitles
        ) else {
            return
        }
        let isAudioTarget = item.targetFormat.lowercased().contains("audio")
        let resolvedAudio = selection.audioTrack
            ?? (!audio.isEmpty
                ? (isAudioTarget ? state.defaults.audio.trackIndex : state.defaults.video.audioTrack)
                : nil)
        let resolvedSubtitle = selection.subtitleTrack
            ?? (!subtitles.isEmpty ? state.defaults.video.subtitleTrack : nil)
        isPerformingAction = true
        defer { isPerformingAction = false }
        do {
            try await runtime.resolveMediaTrackChoice(
                for: item,
                audioTrack: resolvedAudio,
                subtitleTrack: resolvedSubtitle
            )
        } catch {
            present(error, title: "Conversion Could Not Resume")
        }
    }

    private func notifyAboutNewActionableItems(previousOutcomes: [UUID: PersistentJobState]) async {
        for item in state.history where previousOutcomes[item.id] != item.outcome && notifiedJobOutcomes[item.id] != item.outcome {
            guard item.outcome == .succeeded || item.outcome == .failed || item.outcome == .needsRecovery else { continue }
            let content = UNMutableNotificationContent()
            if item.outcome == .succeeded {
                content.title = "Conversion Complete"
                content.body = "\(item.fileName) was converted successfully."
            } else if item.outcome == .needsRecovery {
                content.title = "File Recovery Required"
                content.body = "\(item.fileName): \(item.errorSummary ?? "The conversion needs review.") \(Self.notificationNextAction(for: item))"
            } else {
                content.title = "Conversion Failed"
                content.body = "\(item.fileName) could not be converted. The original filename was restored. \(Self.notificationNextAction(for: item))"
            }
            content.userInfo = ["historyItemID": item.id.uuidString]
            content.categoryIdentifier = item.outcome == .needsRecovery ? "FILEFLIP_RECOVERY" : "FILEFLIP_HISTORY"
            content.sound = .default
            if await notificationService.post(identifier: "fileconvert-\(item.id.uuidString)-\(item.outcome.rawValue)", content: content) {
                notifiedJobOutcomes[item.id] = item.outcome
            }
        }
    }

    private static func notificationNextAction(for item: HistoryItemState) -> String {
        if item.outcome == .needsRecovery {
            return "Open Conversion History to review the recovery options."
        }
        if item.errorSummary?.contains("policy") == true {
            return "Open Settings › Defaults, choose a policy, then rename the file again."
        }
        return "Open Conversion History for details before trying again."
    }

    private func present(_ error: Error, title: String) {
        let message: String
        switch error {
        case RootAuthorizationError.permissionDenied:
            message = "Folder access was denied. No files were changed. Choose the folder again to continue."
        case RootAuthorizationError.volumeChanged:
            message = "This folder is on a different volume than the one you authorized. Choose the original folder or remove it."
        case let FileConvertError.validationFailed(detail):
            message = detail
        case let FileConvertError.providerUnavailable(reason):
            message = "The required local provider is unavailable: \(reason)"
        case FileConvertError.unsupportedPair:
            message = "This source and destination format pair is not supported."
        case FileConvertError.sourceChanged:
            message = "The file changed, so FileFlip refused to overwrite it."
        case FileConvertError.insufficientDiskSpace:
            message = "There is not enough local space to preserve a backup and complete the conversion safely."
        case RecoveryActionError.invalidRecovery:
            message = "This recovery item is no longer unresolved. Refresh Conversion History and review its current status."
        case RecoveryActionError.destinationExists:
            message = "That destination is already occupied. No files were changed. Choose a different destination and try again."
        case RecoveryActionError.artifactUnavailable:
            message = "The retained recovery data is unavailable. No file was restored. You can keep the item unresolved or mark it as resolved manually."
        case RecoveryActionError.integrityFailure:
            message = "The retained recovery data failed its integrity check. No file was restored."
        case RecoveryActionError.permissionDenied:
            message = "FileFlip cannot write to that destination. No file was restored. Choose a writable location."
        case RecoveryActionError.publicationFailed:
            message = "FileFlip could not publish the restored file. No existing file was changed. Choose another destination and try again."
        case let RecoveryActionError.restoredButResolutionWriteFailed(filename):
            message = "\(filename) was restored, but FileFlip could not update recovery status. Keep the restored file and retry or mark the item as resolved."
        case RecoveryActionError.resolutionWriteFailed:
            message = "FileFlip could not mark this item as resolved. It remains unresolved, and its retained recovery data stays protected."
        default:
            message = "FileFlip stopped safely. Review the current status and try again."
        }
        alert = AppAlertState(title: title, message: message)
    }

    private static func keepBothName(for fileName: String) -> String {
        let url = URL(filePath: fileName)
        let stem = url.deletingPathExtension().lastPathComponent
        let suffix = url.pathExtension
        return suffix.isEmpty ? "\(stem) — Original" : "\(stem) — Original.\(suffix)"
    }
}
