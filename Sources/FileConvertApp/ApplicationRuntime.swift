import FileConvertCore
import Foundation

@MainActor
protocol ApplicationRuntime: AnyObject {
    func snapshot() async throws -> ApplicationSnapshot
    func authorizeFolders(_ urls: [URL]) async throws
    func setFolderEnabled(id: UUID, enabled: Bool) async throws
    func removeFolder(id: UUID) async throws
    func reauthorizeFolder(id: UUID, url: URL) async throws
    func setMonitoringPaused(_ paused: Bool) async throws
    func setLaunchAtLogin(_ enabled: Bool) async throws
    func saveDefaults(_ defaults: FutureJobDefaults) async throws
    func resolveTransparencyChoice(for item: HistoryItemState, backgroundARGB: UInt32) async throws
    func resolveMediaTrackChoice(
        for item: HistoryItemState,
        audioTrack: Int?,
        subtitleTrack: Int?
    ) async throws
    func saveRetention(days: Int, byteLimit: UInt64) async throws
    func undo(_ item: HistoryItemState) async throws -> UndoResult
    func restoreToNewFile(_ item: HistoryItemState, destination: URL) async throws -> URL
    func restoreRecovery(_ item: HistoryItemState, destination: URL) async throws -> URL
    func acknowledgeRecovery(_ item: HistoryItemState) async throws
    func clearHistory() async throws
}

struct ApplicationSnapshot: Sendable {
    let monitoringStatus: RenamePipeline.Status
    let convertingCount: Int
    let roots: [AuthorizedRoot]
    let providers: [ProviderState]
    let history: [HistoryItemState]
    let backupUsage: UInt64
    let backupLimit: UInt64
    let retentionDays: Int
    let launchAtLoginStatus: LaunchAtLoginStatus
    let defaults: FutureJobDefaults

    init(
        monitoringStatus: RenamePipeline.Status,
        convertingCount: Int,
        roots: [AuthorizedRoot],
        providers: [ProviderState],
        history: [HistoryItemState],
        backupUsage: UInt64,
        backupLimit: UInt64,
        retentionDays: Int,
        launchAtLoginStatus: LaunchAtLoginStatus,
        defaults: FutureJobDefaults
    ) {
        self.monitoringStatus = monitoringStatus
        self.convertingCount = convertingCount
        self.roots = roots
        self.providers = providers
        self.history = history
        self.backupUsage = backupUsage
        self.backupLimit = backupLimit
        self.retentionDays = retentionDays
        self.launchAtLoginStatus = launchAtLoginStatus
        self.defaults = defaults
    }
}
