import AppKit
import FileConvertCore
import Foundation
import SwiftUI
import UserNotifications

@main
@MainActor
struct FileConvertApp: App {
    @State private var model: FileConvertViewModel
    @State private var updateService: UpdateServiceModel
    private let onboardingWindow: OnboardingWindowController
    private let notificationRouter: SystemNotificationResponseRouter

    init() {
        if ProcessInfo.processInfo.environment["FILECONVERT_UI_TEST_APPEARANCE"] == "dark" {
            NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        }
        let runtime: any ApplicationRuntime
        do {
            runtime = try ApplicationBootstrap.makeRuntime()
        } catch {
            runtime = BootstrapFailureRuntime(error: error)
        }
        let model = FileConvertViewModel(runtime: runtime)
        let onboardingWindow = OnboardingWindowController()
        let notificationRouter = SystemNotificationResponseRouter()
        let environment = ProcessInfo.processInfo.environment
        let updateCoordinator: UpdateCoordinator?
        let updateBackend: any UpdateServicing
        if environment["FILECONVERT_UI_TESTING"] == "1",
           let rawScenario = environment["FILECONVERT_UI_TEST_SCENARIO"],
           rawScenario.hasPrefix("updates-") {
            let scenarioName = String(rawScenario.dropFirst("updates-".count))
            let isActiveWorkDeferral = scenarioName == "ready-active"
            let scenario = FakeUpdateService.Scenario(
                rawValue: isActiveWorkDeferral ? "ready" : scenarioName
            ) ?? .idle
            updateCoordinator = nil
            updateBackend = FakeUpdateService(
                scenario: scenario,
                installedVersion: InstalledVersion(version: "0.1.0", build: "1"),
                isImmediateInstallSafe: { !isActiveWorkDeferral }
            )
        } else {
            let coordinator = UpdateCoordinator(
                isImmediateInstallSafe: { [weak model] in
                    model?.isImmediateUpdateInstallSafe ?? false
                },
                prepareImmediateInstallation: { [weak model] in
                    await model?.reserveImmediateUpdateInstallation() ?? false
                },
                cancelImmediateInstallation: { [weak model] in
                    await model?.cancelUpdateInstallationReservation()
                }
            )
            updateCoordinator = coordinator
            updateBackend = coordinator
        }
        let updateService = UpdateServiceModel(service: updateBackend)
        model.onFoldersAuthorized = { [weak model, weak onboardingWindow] in
            guard let model else { return }
            onboardingWindow?.dismissWhenAuthorized(model: model)
        }
        if let updateCoordinator {
            model.onImmediateUpdateInstallSafetyChanged = { [weak updateCoordinator] _ in
                updateCoordinator?.activeWorkSafetyDidChange()
            }
        }
        notificationRouter.onOpenHistory = { [weak model] itemID in
            model?.requestHistoryNavigation(itemID: itemID)
        }
        _model = State(initialValue: model)
        _updateService = State(initialValue: updateService)
        self.onboardingWindow = onboardingWindow
        self.notificationRouter = notificationRouter
        Task { @MainActor [model, onboardingWindow] in
            await model.start()
            onboardingWindow.presentIfNeeded(model: model)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView()
                .environment(model)
        } label: {
            Label {
                Text("FileFlip — \(model.state.status.title)")
            } icon: {
                Image(systemName: model.state.status.systemImage)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(model.state.status.tint)
            }
            .accessibilityLabel("FileFlip, \(model.state.status.accessibilityDescription)")
        }
        .menuBarExtraStyle(.window)

        Window("Conversion History", id: "history") {
            HistoryView()
                .environment(model)
        }
        .defaultSize(width: AppLayout.historyDefaultWidth, height: AppLayout.historyDefaultHeight)

        Settings {
            FileConvertSettingsView()
                .environment(model)
                .environment(updateService)
        }
    }
}

@MainActor
private final class BootstrapFailureRuntime: ApplicationRuntime {
    private let error: Error

    init(error: Error) {
        self.error = error
    }

    func snapshot() async throws -> ApplicationSnapshot { throw error }
    func authorizeFolders(_ urls: [URL]) async throws { throw error }
    func setFolderEnabled(id: UUID, enabled: Bool) async throws { throw error }
    func removeFolder(id: UUID) async throws { throw error }
    func reauthorizeFolder(id: UUID, url: URL) async throws { throw error }
    func setMonitoringPaused(_ paused: Bool) async throws { throw error }
    func setLaunchAtLogin(_ enabled: Bool) async throws { throw error }
    func saveDefaults(_ defaults: FutureJobDefaults) async throws { throw error }
    func resolveTransparencyChoice(for item: HistoryItemState, backgroundARGB: UInt32) async throws { throw error }
    func resolveMediaTrackChoice(for item: HistoryItemState, audioTrack: Int?, subtitleTrack: Int?) async throws { throw error }
    func saveRetention(days: Int, byteLimit: UInt64) async throws { throw error }
    func undo(_ item: HistoryItemState) async throws -> UndoResult { throw error }
    func restoreToNewFile(_ item: HistoryItemState, destination: URL) async throws -> URL { throw error }
    func restoreRecovery(_ item: HistoryItemState, destination: URL) async throws -> URL { throw error }
    func acknowledgeRecovery(_ item: HistoryItemState) async throws { throw error }
    func clearHistory() async throws { throw error }
}

@MainActor
private final class SystemNotificationResponseRouter: NSObject, UNUserNotificationCenterDelegate {
    var onOpenHistory: ((UUID?) -> Void)?

    override init() {
        super.init()
        let viewHistory = UNNotificationAction(
            identifier: "VIEW_HISTORY",
            title: "View in History",
            options: [.foreground]
        )
        let reviewRecovery = UNNotificationAction(
            identifier: "REVIEW_RECOVERY",
            title: "Review Recovery…",
            options: [.foreground]
        )
        let historyCategory = UNNotificationCategory(
            identifier: "FILEFLIP_HISTORY",
            actions: [viewHistory],
            intentIdentifiers: []
        )
        let recoveryCategory = UNNotificationCategory(
            identifier: "FILEFLIP_RECOVERY",
            actions: [reviewRecovery],
            intentIdentifiers: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([historyCategory, recoveryCategory])
        UNUserNotificationCenter.current().delegate = self
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let itemID = (response.notification.request.content.userInfo["historyItemID"] as? String)
            .flatMap(UUID.init(uuidString:))
        await MainActor.run { [weak self] in
            NSApplication.shared.activate(ignoringOtherApps: true)
            self?.onOpenHistory?(itemID)
        }
    }
}
