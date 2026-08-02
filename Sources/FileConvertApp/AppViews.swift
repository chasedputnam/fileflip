import FileConvertCore
import SwiftUI

private enum AccessibilityID {
    static let status = "status.summary"
    static let pauseResume = "monitoring.pause-resume"
    static let addFolder = "folders.add"
    static let openHistory = "history.open"
    static let onboarding = "onboarding.content"
    static let onboardingAuthorize = "onboarding.authorize"
    static let historyList = "history.list"
    static let historyDetail = "history.detail"
    static let historyUndo = "history.undo"
    static let historyKeepBoth = "history.keep-both"
    static let historyClear = "history.clear"
    static let historyRestoreRecovery = "history.restore-recovery"
    static let historyResolveRecovery = "history.resolve-recovery"
    static let providerList = "providers.list"
    static let settings = "settings.content"
}

struct MenuBarContentView: View {
    @Environment(FileConvertViewModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.medium) {
            statusSection

            sectionDivider

            VStack(alignment: .leading, spacing: AppSpacing.xSmall) {
                Text("Recent Activity")
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .tracking(0.8)
                    .foregroundStyle(AppColor.secondaryInk)
                if model.state.recentActivity.isEmpty {
                    Text("Conversions and actionable failures will appear here.")
                        .font(.callout)
                        .foregroundStyle(AppColor.secondaryInk)
                        .padding(.vertical, AppSpacing.small)
                } else {
                    ForEach(model.state.recentActivity) { item in
                        Button {
                            model.selectHistory(item.id)
                            openHistory()
                        } label: {
                            RecentActivityRow(item: item)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(item.fileName), \(item.outcomeText), \(item.sourceFormat) to \(item.targetFormat)")
                        .accessibilityValue(item.conversionDurationText ?? "Completion time unavailable")
                    }
                }
            }

            sectionDivider

            HStack(spacing: AppSpacing.small) {
                if let recovery = model.state.history.first(where: \.needsRecoveryAction) {
                    Button("Review Recovery", systemImage: "cross.case.fill") {
                        model.selectHistory(recovery.id)
                        openHistory()
                    }
                    .accessibilityHint("Opens the unresolved recovery item in Conversion History")
                }
                Button("History", systemImage: "clock.arrow.circlepath") {
                    openHistory()
                }
                .keyboardShortcut("h", modifiers: [.command])
                .accessibilityIdentifier(AccessibilityID.openHistory)

                Button("Settings", systemImage: "gearshape") {
                    openSettings()
                    activateFrontmostApplicationWindow()
                }
                .keyboardShortcut(",", modifiers: [.command])

                Spacer()

                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q", modifiers: [.command])
            }
            .controlSize(.small)
        }
        .padding(AppSpacing.large)
        .frame(width: AppLayout.menuWidth)
        .background(popoverBackground)
        .animation(reduceMotion ? nil : AppMotion.stateChange, value: model.state.status)
        .onChange(of: model.historyNavigationRequest) { _, request in
            guard let request else { return }
            if let itemID = request.itemID {
                model.selectHistory(itemID)
            }
            openHistory()
            model.completeHistoryNavigation(request)
        }
        .overlay {
            if model.state.isLoading {
                ProgressView("Loading local state…")
                    .padding(AppSpacing.large)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: AppRadius.panel))
                    .accessibilityIdentifier("status.loading")
            }
        }
        .alert(item: Binding(get: { model.alert }, set: { _ in model.dismissAlert() })) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
        }
    }
    private func openHistory() {
        openWindow(id: "history")
        activateFrontmostApplicationWindow()
    }

    private func activateFrontmostApplicationWindow() {
        Task { @MainActor in
            await Task.yield()
            NSApplication.shared.activate(ignoringOtherApps: true)
            NSApplication.shared.windows.first {
                $0.isVisible && $0.level == .normal && $0.canBecomeKey
            }?.makeKeyAndOrderFront(nil)
        }
    }


    @ViewBuilder
    private var statusSection: some View {
        HStack(alignment: .center, spacing: AppSpacing.medium) {
            AppStatusMark(state: model.state.status)
            VStack(alignment: .leading, spacing: AppSpacing.xSmall) {
                Text(model.state.status.title)
                    .font(.headline)
                    .foregroundStyle(AppColor.primaryInk)
                Text(model.state.statusDetail)
                    .font(.caption)
                    .foregroundStyle(AppColor.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: AppSpacing.small)
            if !model.state.folders.isEmpty {
                Button(
                    model.state.isMonitoringPaused ? "Resume" : "Pause",
                    systemImage: model.state.isMonitoringPaused ? "play.fill" : "pause.fill"
                ) {
                    model.toggleMonitoring()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.isPerformingAction)
                .keyboardShortcut("p", modifiers: [.command])
                .accessibilityHint(model.state.isMonitoringPaused ? "Processes only new rename events after monitoring resumes" : "Stops queuing new conversions; a safe final replacement may finish")
                .accessibilityIdentifier(AccessibilityID.pauseResume)
            }
        }
        .accessibilityIdentifier(AccessibilityID.status)
        .accessibilityLabel("File-Flip status: \(model.state.status.accessibilityDescription). \(model.state.statusDetail)")

        if model.state.folders.isEmpty {
            AppEmptyState(
                systemImage: "folder.badge.plus",
                title: "Choose where File-Flip works",
                message: "Only folders you authorize are monitored. Existing files are never scanned for conversions."
            )
            Button("Authorize Folders", systemImage: "folder.badge.plus") {
                model.chooseFolders()
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isPerformingAction)
            .keyboardShortcut("+", modifiers: [.command])
            .accessibilityHint("Opens the macOS folder picker without preselecting a folder")
            .accessibilityIdentifier(AccessibilityID.onboardingAuthorize)
        }
    }

    private var sectionDivider: some View {
        Divider()
            .overlay(AppColor.divider)
    }

    private var popoverBackground: Color {
        if reduceTransparency || colorSchemeContrast == .increased {
            Color(nsColor: .windowBackgroundColor)
        } else {
            AppColor.popoverSurface
        }
    }
}

private struct RecentActivityRow: View {
    @State private var isHovered = false
    let item: HistoryItemState

    var body: some View {
        HStack(spacing: AppSpacing.small) {
            AppIconTile(
                systemImage: presentation.systemImage,
                foreground: presentation.foreground,
                fill: presentation.fill
            )
            VStack(alignment: .leading, spacing: AppSpacing.xSmall) {
                Text(item.fileName)
                    .fontWeight(.medium)
                    .foregroundStyle(AppColor.primaryInk)
                    .lineLimit(1)
                Text("\(item.sourceFormat) → \(item.targetFormat) · \(item.outcomeText)")
                    .font(.caption)
                    .foregroundStyle(AppColor.secondaryInk)
                    .lineLimit(1)
            }
            Spacer(minLength: AppSpacing.xSmall)
            if let duration = item.conversionDurationText {
                Text(duration)
                    .font(.caption2)
                    .foregroundStyle(AppColor.secondaryInk)
                    .lineLimit(1)
            } else {
                Text(item.date, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(AppColor.secondaryInk)
                    .lineLimit(1)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppColor.secondaryInk)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, AppSpacing.xSmall)
        .padding(.vertical, AppSpacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHovered ? AppColor.controlFill : Color.clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onHover { isHovered = $0 }
    }

    private var presentation: (systemImage: String, foreground: Color, fill: Color) {
        if item.showsSuccessMark {
            return ("checkmark", AppColor.success, AppColor.successFill)
        }
        return switch item.outcome {
        case .failed:
            ("exclamationmark", AppColor.critical, AppColor.criticalFill)
        case .needsRecovery:
            ("cross.case.fill", AppColor.critical, AppColor.criticalFill)
        case .skipped, .cancelled:
            ("minus", AppColor.warning, AppColor.warningFill)
        default:
            ("arrow.triangle.2.circlepath", AppColor.progress, AppColor.progressFill)
        }
    }
}

struct OnboardingView: View {
    @Environment(FileConvertViewModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xLarge) {
            Label("Convert by Renaming", systemImage: "arrow.triangle.2.circlepath")
                .font(.largeTitle.bold())
            Text("Rename a file’s extension in an authorized folder. File-Flip checks the file’s real format, converts it locally when the pair is available, and keeps a recoverable original.")
                .font(.title3)
                .fixedSize(horizontal: false, vertical: true)
            AppPanel {
                VStack(alignment: .leading, spacing: AppSpacing.medium) {
                    Label("Private by design", systemImage: "lock.shield")
                        .font(.headline)
                    Text("Files, names, paths, and history stay on this Mac. No folder is selected or watched until you choose it.")
                    Text("Desktop and Downloads are common choices, but neither is preselected.")
                        .foregroundStyle(.secondary)
                }
            }
            Button("Choose Folders…") { model.chooseFolders() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .accessibilityHint("Opens a system folder picker that allows one or more folders")
                .accessibilityIdentifier(AccessibilityID.onboardingAuthorize)
                .disabled(model.isPerformingAction)
        }
        .padding(AppSpacing.xxLarge)
        .frame(width: AppLayout.onboardingWidth)
    }
}

private enum SettingsTab: Hashable {
    case general
    case folders
    case defaults
    case formats
    case storage
    case updates
}

struct FileConvertSettingsView: View {
    @Environment(FileConvertViewModel.self) private var model
    @State private var selectedTab = SettingsTab.general

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            WatchedFoldersSettingsView()
                .tabItem { Label("Folders", systemImage: "folder") }
                .tag(SettingsTab.folders)
            PolicySettingsView()
                .tabItem { Label("Defaults", systemImage: "slider.horizontal.3") }
                .tag(SettingsTab.defaults)
            ProviderSettingsView()
                .tabItem { Label("Formats", systemImage: "square.grid.2x2") }
                .tag(SettingsTab.formats)
            StorageSettingsView()
                .tabItem { Label("Storage", systemImage: "externaldrive") }
                .tag(SettingsTab.storage)
            UpdateSettingsView()
                .tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }
                .tag(SettingsTab.updates)
        }
        .disabled(model.isPerformingAction)
        .padding(AppSpacing.large)
        .frame(minWidth: AppLayout.settingsMinimumWidth, minHeight: AppLayout.settingsMinimumHeight)
    }
}

private struct GeneralSettingsView: View {
    @Environment(FileConvertViewModel.self) private var model

    var body: some View {
        Form {
            Section("Monitoring") {
                LabeledContent("Status") { AppStatusMark(state: model.state.status) }
                Button(model.state.isMonitoringPaused ? "Resume Monitoring" : "Pause Monitoring") {
                    model.toggleMonitoring()
                }
                .disabled(model.state.folders.isEmpty || model.isPerformingAction)
            }
            Section("Login") {
                Toggle("Launch File-Flip when I log in", isOn: Binding(
                    get: { model.state.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
                .accessibilityIdentifier("settings.launch-at-login")
                .toggleStyle(.checkbox)
                if model.state.launchAtLoginRequiresApproval {
                    Text("Approval is required in System Settings › General › Login Items.")
                        .foregroundStyle(AppColor.warning)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct WatchedFoldersSettingsView: View {
    @Environment(FileConvertViewModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.large) {
            HStack {
                Text("Watched Folders").font(.title2.bold())
                Spacer()
                Button("Add Folder…", systemImage: "plus") { model.chooseFolders() }
                    .accessibilityIdentifier(AccessibilityID.addFolder)
            }
            if model.state.folders.isEmpty {
                AppEmptyState(
                    systemImage: "folder.badge.plus",
                    title: "No folders authorized",
                    message: "Add only the folders where rename-to-convert should be active."
                )
            } else {
                List(model.state.folders) { folder in
                    HStack(spacing: AppSpacing.medium) {
                        Image(systemName: folder.needsReauthorization ? "folder.badge.questionmark" : "folder")
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: AppSpacing.xSmall) {
                            Text(folder.name).font(.headline)
                            Text(folder.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Text(folder.statusText)
                                .font(.caption)
                                .foregroundStyle(folder.needsReauthorization ? AppColor.warning : Color.secondary)
                        }
                        Spacer()
                        if folder.needsReauthorization {
                            Button("Reauthorize…") { model.reauthorize(folder) }
                                .accessibilityLabel("Reauthorize \(folder.name)")
                        }
                        Toggle("Monitor \(folder.name)", isOn: Binding(
                            get: { folder.isEnabled },
                            set: { model.setFolderEnabled(folder, enabled: $0) }
                        ))
                        .labelsHidden()
                        Button("Remove", systemImage: "minus.circle") { model.removeFolder(folder) }
                            .labelStyle(.iconOnly)
                            .accessibilityLabel("Remove \(folder.name) from watched folders")
                    }
                }
            }
        }
    }
}

private struct PolicySettingsView: View {
    @Environment(FileConvertViewModel.self) private var model

    var body: some View {
        Form {
            Text("Changes apply only to conversions requested after you save them. A conversion already running keeps the policy captured when it began.")
                .foregroundStyle(.secondary)
            Section("Conversion result") {
                Picker("After conversion", selection: conversionBehavior) {
                    Text("Keep original and create converted copy").tag(ConversionBehavior.keepOriginal)
                    Text("Replace file and keep recoverable backup").tag(ConversionBehavior.replaceWithBackup)
                }
                .accessibilityIdentifier("settings.conversion-behavior")
                Text(model.state.defaults.conversionBehavior == .keepOriginal
                     ? "Keeps two visible files: the exact original under its original extension and the converted result under the renamed extension. Both use disk space."
                     : "Keeps one visible converted file. The exact original remains in private backup storage until the configured retention limits remove it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Images") {
                LabeledContent("Quality") {
                    Slider(value: imageQuality, in: 0.5 ... 1, step: 0.05)
                        .frame(width: AppLayout.sliderWidth)
                        .accessibilityValue("\(Int(model.state.defaults.image.quality * 100)) percent")
                        .accessibilityIdentifier("defaults.image.quality")
                }
                Picker("Multiple frames", selection: imageFrames) {
                    Text("Ask before converting").tag(ImageFrameChoice.ask)
                    Text("Use first frame").tag(ImageFrameChoice.first)
                    Text("Preserve all when supported").tag(ImageFrameChoice.all)
                }
                .accessibilityIdentifier("defaults.image.frames")
                Picker("Transparency when target cannot preserve it", selection: imageBackground) {
                    Text("Ask before converting").tag(UInt32?.none)
                    Text("White background").tag(UInt32?.some(0xFFFF_FFFF))
                    Text("Black background").tag(UInt32?.some(0xFF00_0000))
                }
                Picker("Metadata", selection: imageMetadata) {
                    Text("Preserve").tag(MetadataMode.preserve)
                    Text("Remove").tag(MetadataMode.strip)
                }
                Picker("Orientation", selection: imageOrientation) {
                    Text("Normalize pixels").tag(ImageOrientationMode.normalizePixels)
                    Text("Preserve orientation tag").tag(ImageOrientationMode.preserveTag)
                }
                .accessibilityIdentifier("defaults.image.orientation")
                Picker("Color profile", selection: imageColorProfile) {
                    Text("Preserve").tag(ImageColorProfileMode.preserve)
                    Text("Convert to sRGB").tag(ImageColorProfileMode.convertToSRGB)
                    Text("Remove").tag(ImageColorProfileMode.strip)
                }
                .accessibilityIdentifier("defaults.image.color-profile")
            }
            Section("Audio and Video") {
                Picker("Audio bitrate", selection: audioBitrate) {
                    Text("Compatibility default").tag(Int?.none)
                    Text("128 kbps").tag(Int?.some(128_000))
                    Text("256 kbps").tag(Int?.some(256_000))
                }
                .accessibilityIdentifier("defaults.audio.bitrate")
                Picker("Audio sample rate", selection: audioSampleRate) {
                    Text("Compatibility default").tag(Int?.none)
                    Text("44.1 kHz").tag(Int?.some(44_100))
                    Text("48 kHz").tag(Int?.some(48_000))
                }
                .accessibilityIdentifier("defaults.audio.sample-rate")
                Picker("Audio track", selection: audioTrack) {
                    Text("Ask when ambiguous").tag(Int?.none)
                    Text("First track").tag(Int?.some(0))
                }
                Stepper("Video quality: \(model.state.defaults.video.quality)", value: videoQuality, in: 0 ... 51)
                .accessibilityIdentifier("defaults.video.quality")
                Picker("Video audio track", selection: videoAudioTrack) {
                    Text("Ask when ambiguous").tag(Int?.none)
                    Text("First track").tag(Int?.some(0))
                }
                Picker("Video subtitle track", selection: videoSubtitleTrack) {
                    Text("Ask when ambiguous").tag(Int?.none)
                    Text("First track").tag(Int?.some(0))
                }
                .accessibilityIdentifier("defaults.video.subtitle-track")
                Text("Lower video quality values preserve more detail and use more space.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Documents") {
                Toggle("Allow conversions with disclosed layout or feature loss", isOn: documentLoss)
                    .accessibilityIdentifier("defaults.document.loss")
                Picker("Page selection", selection: documentPage) {
                    Text("Ask for multi-page sources").tag(Int?.none)
                    Text("First page").tag(Int?.some(0))
                }
                LabeledContent("Rendered image quality") {
                    Slider(value: documentImageQuality, in: 0.5 ... 1, step: 0.05)
                        .frame(width: AppLayout.sliderWidth)
                        .accessibilityValue("\(Int(model.state.defaults.document.imageQuality * 100)) percent")
                        .accessibilityIdentifier("defaults.document.image-quality")
                }
            }
            Section("Spreadsheets") {
                Picker("Worksheet", selection: spreadsheetSheet) {
                    Text("Ask for multi-sheet workbooks").tag(Int?.none)
                    Text("First worksheet").tag(Int?.some(0))
                }
                Picker("CSV delimiter", selection: spreadsheetDelimiter) {
                    Text("Comma").tag(",")
                    Text("Tab").tag("\t")
                    Text("Semicolon").tag(";")
                }
                Toggle("Export formula results instead of formulas", isOn: spreadsheetValues)
                    .accessibilityIdentifier("defaults.spreadsheet.formula-values")
            }
        }
        .formStyle(.grouped)
    }

    private var conversionBehavior: Binding<ConversionBehavior> { binding(\.conversionBehavior) }
    private var imageQuality: Binding<Double> { binding(\.image.quality) }
    private var imageFrames: Binding<ImageFrameChoice> { binding(\.image.frames) }
    private var imageBackground: Binding<UInt32?> { binding(\.image.alphaBackgroundARGB) }
    private var imageMetadata: Binding<MetadataMode> { binding(\.image.metadata) }
    private var imageOrientation: Binding<ImageOrientationMode> { binding(\.image.orientation) }
    private var imageColorProfile: Binding<ImageColorProfileMode> { binding(\.image.colorProfile) }
    private var audioBitrate: Binding<Int?> { binding(\.audio.bitrate) }
    private var audioSampleRate: Binding<Int?> { binding(\.audio.sampleRate) }
    private var audioTrack: Binding<Int?> { binding(\.audio.trackIndex) }
    private var videoQuality: Binding<Int> { binding(\.video.quality) }
    private var videoAudioTrack: Binding<Int?> { binding(\.video.audioTrack) }
    private var videoSubtitleTrack: Binding<Int?> { binding(\.video.subtitleTrack) }
    private var documentLoss: Binding<Bool> { binding(\.document.acceptsFidelityLoss) }
    private var documentPage: Binding<Int?> { binding(\.document.pageIndex) }
    private var documentImageQuality: Binding<Double> { binding(\.document.imageQuality) }
    private var spreadsheetDelimiter: Binding<String> { binding(\.spreadsheet.delimiter) }
    private var spreadsheetSheet: Binding<Int?> { binding(\.spreadsheet.sheetIndex) }
    private var spreadsheetValues: Binding<Bool> { binding(\.spreadsheet.formulaValuesOnly) }

    private func binding<Value>(_ keyPath: WritableKeyPath<FutureJobDefaults, Value>) -> Binding<Value> {
        Binding(
            get: { model.state.defaults[keyPath: keyPath] },
            set: { value in
                var defaults = model.state.defaults
                defaults[keyPath: keyPath] = value
                model.updateDefaults(defaults)
            }
        )
    }
}

private struct ProviderSettingsView: View {
    @Environment(FileConvertViewModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.large) {
            Text("Available Formats").font(.title2.bold())
            Text("Only independently certified source-to-target pairs are shown. An unavailable provider never causes FileFlip to rename bytes without converting them.")
                .foregroundStyle(.secondary)
            if model.state.providers.isEmpty {
                AppEmptyState(
                    systemImage: "exclamationmark.triangle",
                    title: "No certified providers available",
                    message: "Conversions remain disabled until a verified local provider is available."
                )
            } else {
                List(model.state.providers, id: \ProviderState.id) { (provider: ProviderState) in
                    DisclosureGroup {
                        if provider.pairs.isEmpty {
                            Text("No conversion pairs are currently available.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(provider.pairs, id: \.self) { pair in Text(pair) }
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: AppSpacing.xSmall) {
                                Text(provider.name).font(.headline)
                                Text(provider.detail)
                                    .font(.caption)
                                    .foregroundStyle(provider.isAvailable ? Color.secondary : AppColor.warning)
                            }
                            Spacer()
                            Image(systemName: provider.isAvailable ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(provider.isAvailable ? AppColor.success : AppColor.warning)
                                .accessibilityHidden(true)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(provider.name), \(provider.detail)")
                        .accessibilityIdentifier("provider.\(provider.id)")
                    }
                }
            }
        }
    }
}

private struct StorageSettingsView: View {
    @Environment(FileConvertViewModel.self) private var model

    var body: some View {
        Form {
            Section("Recoverable Originals") {
                LabeledContent("Backup usage", value: model.state.backup.usageText)
                Picker("Retain backups", selection: Binding(
                    get: { model.state.backup.retentionDays },
                    set: { model.updateRetention(days: $0) }
                )) {
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                }
                Picker("Maximum storage", selection: Binding(
                    get: { model.state.backup.limitBytes },
                    set: { model.updateRetention(byteLimit: $0) }
                )) {
                    Text("5 GB").tag(UInt64(5 << 30))
                    Text("10 GB").tag(UInt64(10 << 30))
                    Text("25 GB").tag(UInt64(25 << 30))
                }
                Text("Pruning removes only retained backups. It never removes the only user-visible file.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Privacy") {
                Label("All conversions and history stay on this Mac", systemImage: "lock.shield")
                Text("File-Flip does not send file names, paths, contents, history, or usage events to an external service.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct UpdateSettingsView: View {
    @Environment(UpdateServiceModel.self) private var service

    private var state: UpdateViewState { service.viewState }

    var body: some View {
        Form {
            Section("Installed Version") {
                LabeledContent("Version", value: state.installedVersion.version)
                LabeledContent("Build", value: state.installedVersion.build)
            }

            Section("Automatic Updates") {
                Toggle("Automatically keep FileFlip up to date", isOn: Binding(
                    get: { service.automaticUpdatesEnabled },
                    set: { service.setAutomaticUpdatesEnabled($0) }
                ))
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("updates.automatic")
                .accessibilityLabel(
                    "Automatically keep FileFlip up to date, \(service.automaticUpdatesEnabled ? "On" : "Off")"
                )
                .accessibilityValue(service.automaticUpdatesEnabled ? "On" : "Off")
                Text("FileFlip checks the signed public GitHub release feed. File names, paths, contents, conversion history, and usage data are never sent.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Update Status") {
                Label(statusTitle, systemImage: statusSystemImage)
                    .foregroundStyle(statusColor)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Update status")
                    .accessibilityValue(statusDescription)
                    .accessibilityIdentifier("updates.status")

                if let release = state.availableRelease {
                    LabeledContent("Available version", value: release.version)
                    LabeledContent("Available build", value: release.build)
                    if let releasePageURL = release.releasePageURL {
                        Link("View Release on GitHub", destination: releasePageURL)
                            .accessibilityIdentifier("updates.release-link")
                    }
                }

                if let progress = state.progress {
                    updateProgress(progress)
                }

                if let lastCheck = state.lastSuccessfulCheck {
                    LabeledContent("Last successful check") {
                        Text(lastCheck.formatted(date: .abbreviated, time: .shortened))
                    }
                }

                if state.phase == .ready {
                    Text(readyDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let failure = state.failure {
                    Text(failure.message)
                        .foregroundStyle(AppColor.critical)
                        .accessibilityIdentifier("updates.failure")
                }

                actionButtons
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func updateProgress(_ progress: UpdateProgress) -> some View {
        if let fraction = progress.fractionCompleted {
            ProgressView("Download progress", value: fraction)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Download progress, \(Int(fraction * 100)) percent")
                .accessibilityValue("\(Int(fraction * 100)) percent")
                .accessibilityIdentifier("updates.progress")
        } else {
            ProgressView("Download progress")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Download progress, In progress")
                .accessibilityValue("In progress")
                .accessibilityIdentifier("updates.progress")
        }
        Text(progressDescription(progress))
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var actionButtons: some View {
        HStack {
            switch state.phase {
            case .idle, .upToDate:
                Button("Check for Updates") { service.checkForUpdates() }
                    .disabled(!service.canCheckForUpdates)
                    .accessibilityIdentifier("updates.check")
            case .available:
                Button("Download Update") { service.downloadAvailableUpdate() }
                    .disabled(!state.canDownloadAvailableUpdate)
                    .accessibilityIdentifier("updates.download")
            case .ready:
                Button("Install and Relaunch") { service.installAndRelaunch() }
                    .disabled(!service.canInstallAndRelaunch)
                    .accessibilityHint(service.canInstallAndRelaunch
                        ? "Installs the verified update and relaunches FileFlip."
                        : "Finish the active conversion or recovery action first.")
                    .accessibilityIdentifier("updates.install")
            case .failed:
                if state.canRetry {
                    Button("Retry") { service.retryCurrentOperation() }
                        .accessibilityIdentifier("updates.retry")
                }
                Button("Dismiss") { service.dismissCurrentError() }
                    .accessibilityIdentifier("updates.dismiss")
                Button("Open GitHub Releases") { service.openReleasesPage() }
                    .accessibilityIdentifier("updates.releases")
            case .checking, .downloading, .verifying, .installing:
                EmptyView()
            }
        }
    }

    private var statusTitle: String {
        switch state.phase {
        case .idle: "Ready to Check"
        case .checking: "Checking for Updates"
        case .upToDate: "FileFlip Is Up to Date"
        case .available: "Update Available"
        case .downloading: "Downloading Update"
        case .verifying: "Verifying Update"
        case .ready: "Ready to Install"
        case .installing: "Installing Update"
        case .failed: "Update Failed"
        }
    }

    private var statusDescription: String {
        if let failure = state.failure {
            return "\(statusTitle). \(failure.message)"
        }
        if state.phase == .ready {
            return "\(statusTitle). \(readyDescription)"
        }
        return statusTitle
    }

    private var statusSystemImage: String {
        switch state.phase {
        case .idle: "arrow.triangle.2.circlepath"
        case .checking, .downloading, .verifying, .installing: "arrow.down.circle"
        case .upToDate: "checkmark.circle.fill"
        case .available: "arrow.down.circle.fill"
        case .ready: "checkmark.seal.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch state.phase {
        case .upToDate, .ready: AppColor.success
        case .checking, .available, .downloading, .verifying, .installing: AppColor.progress
        case .failed: AppColor.critical
        case .idle: .secondary
        }
    }

    private var readyDescription: String {
        let installTiming = state.installsOnQuit
            ? "The verified update will install when FileFlip quits."
            : "The verified update is ready to install."
        guard !service.canInstallAndRelaunch else { return installTiming }
        return "\(installTiming) Finish the active conversion or recovery action before installing and relaunching."
    }

    private func progressDescription(_ progress: UpdateProgress) -> String {
        let transferred = ByteCountFormatter.string(
            fromByteCount: progress.transferredByteCount,
            countStyle: .file
        )
        guard let total = progress.totalByteCount else {
            return "\(transferred) downloaded"
        }
        let totalText = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        return "\(transferred) of \(totalText) downloaded"
    }
}

struct HistoryView: View {
    @Environment(FileConvertViewModel.self) private var model
    @State private var confirmsClear = false

    private var selectedHistoryID: UUID? {
        guard let selectedID = model.state.selectedHistoryID,
              model.state.history.contains(where: { $0.id == selectedID }) else {
            return model.state.history.first?.id
        }
        return selectedID
    }

    private var selectedItem: HistoryItemState? {
        model.state.history.first { $0.id == selectedHistoryID }
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                if model.state.history.isEmpty {
                    AppEmptyState(
                        systemImage: "clock.arrow.circlepath",
                        title: "No conversion history",
                        message: "Successful conversions and failures that begin work will appear here."
                    )
                    .padding(AppSpacing.large)
                } else {
                    List(model.state.history, selection: Binding(
                        get: { selectedHistoryID },
                        set: { model.selectHistory($0) }
                    )) { item in
                        HistoryRow(item: item)
                            .tag(item.id)
                            .accessibilityIdentifier("history.item.\(item.id.uuidString)")
                    }
                }
                Divider()
                Button("Clear History…", systemImage: "trash", role: .destructive) { confirmsClear = true }
                    .disabled(model.state.history.isEmpty || model.isPerformingAction)
                    .padding(AppSpacing.medium)
                    .accessibilityIdentifier(AccessibilityID.historyClear)
            }
            .navigationSplitViewColumnWidth(
                min: AppLayout.historySidebarMinimumWidth,
                ideal: AppLayout.historySidebarIdealWidth
            )
        } detail: {
            if let selectedItem {
                HistoryDetailView(item: selectedItem)
            } else {
                AppEmptyState(
                    systemImage: "doc.text.magnifyingglass",
                    title: "Select an activity",
                    message: "Choose a conversion to inspect its outcome, provider, warnings, and recovery options."
                )
                .padding(AppSpacing.xLarge)
            }
        }
        .frame(minWidth: AppLayout.historyMinimumWidth, minHeight: AppLayout.historyMinimumHeight)
        .confirmationDialog(
            "Clear conversion history?",
            isPresented: $confirmsClear,
            titleVisibility: .visible
        ) {
            Button("Clear History and Delete Backups", role: .destructive) { model.clearHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Completed and resolved history and its associated backups will be deleted. Unresolved recovery items and retained recovery data remain protected. User-visible files are not deleted.")
        }
        .sheet(item: Binding(
            get: { model.undoConflict },
            set: { if $0 == nil { model.dismissUndoConflict() } }
        )) { item in
            UndoConflictView(item: item)
        }
        .alert(item: Binding(get: { model.alert }, set: { _ in model.dismissAlert() })) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
        }
    }
}

private struct HistoryRow: View {
    let item: HistoryItemState

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xSmall) {
            HStack {
                Text(item.fileName).font(.headline).lineLimit(1)
                Spacer()
                Image(systemName: item.showsSuccessMark ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(item.showsSuccessMark ? AppColor.success : AppColor.warning)
                    .accessibilityHidden(true)
            }
            Text("\(item.sourceFormat) → \(item.targetFormat) · \(item.outcomeText)")
                .font(.caption).foregroundStyle(.secondary)
            Text(item.behaviorText)
                .font(.caption2).foregroundStyle(.secondary)
            if let duration = item.conversionDurationText {
                Text(duration)
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text(item.date, style: .relative)
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.fileName), \(item.outcomeText), \(item.sourceFormat) to \(item.targetFormat)")
    }
}

private struct HistoryDetailView: View {
    @Environment(FileConvertViewModel.self) private var model
    let item: HistoryItemState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.xLarge) {
                VStack(alignment: .leading, spacing: AppSpacing.small) {
                    Text(item.fileName).font(.title2.bold())
                    Text("\(item.sourceFormat) → \(item.targetFormat)")
                        .font(.title3).foregroundStyle(.secondary)
                    Label(item.outcomeText, systemImage: item.showsSuccessMark ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(item.showsSuccessMark ? AppColor.success : AppColor.warning)
                }
                AppPanel {
                    Grid(alignment: .leading, horizontalSpacing: AppSpacing.large, verticalSpacing: AppSpacing.small) {
                        GridRow { Text("Date").foregroundStyle(.secondary); Text(item.date.formatted(date: .abbreviated, time: .shortened)) }
                        if let duration = item.conversionDurationText {
                            GridRow { Text("Duration").foregroundStyle(.secondary); Text(duration) }
                        }
                        GridRow { Text("Provider").foregroundStyle(.secondary); Text(providerText) }
                        GridRow { Text("File access").foregroundStyle(.secondary); Text(availabilityText) }
                        GridRow { Text("Result").foregroundStyle(.secondary); Text(item.behaviorText) }
                        if let recoveryDetailText {
                            GridRow { Text("Recovery").foregroundStyle(.secondary); Text(recoveryDetailText) }
                        }

                    }
                }
                if let warning = item.fidelityWarning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(AppColor.warning)
                        .accessibilityLabel("Fidelity warning: \(warning)")
                }
                if let error = item.errorSummary {
                    VStack(alignment: .leading, spacing: AppSpacing.small) {
                        Text("What happened").font(.headline)
                        Text(error)
                        Text("Safe next step").font(.headline)
                        Text(safeNextAction)
                        Text("File-Flip does not display provider output that could contain private paths or document content.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if item.needsRecoveryAction {
                    AppPanel {
                        VStack(alignment: .leading, spacing: AppSpacing.medium) {
                            Text("Recovery options").font(.headline)
                            Text("The current file will remain unchanged. Restore the retained original as a separate file at a destination you choose.")
                            if item.canRestoreRetainedFile {
                                Button("Restore Retained File…", systemImage: "arrow.down.doc") {
                                    model.restoreRecovery(item)
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(model.isPerformingAction)
                                .accessibilityHint("Creates a separate recovered copy without changing the current file")
                                .accessibilityIdentifier(AccessibilityID.historyRestoreRecovery)
                            } else {
                                Label("Recovery data unavailable", systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(AppColor.warning)
                            }
                            Button("Mark as Resolved…") {
                                model.acknowledgeRecovery(item)
                            }
                            .disabled(model.isPerformingAction)
                            .accessibilityHint("Records manual resolution without restoring a file and allows normal retention cleanup")
                            .accessibilityIdentifier(AccessibilityID.historyResolveRecovery)
                        }
                    }
                }
                if item.canUndo {
                    Button("Undo Conversion", systemImage: "arrow.uturn.backward") { model.undo(item) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut("z", modifiers: [.command])
                        .disabled(model.isPerformingAction)
                        .accessibilityHint(item.conversionBehavior == .keepOriginal ? "Removes the unchanged converted copy only if both visible files still match" : "Restores the exact retained original only if the converted file has not changed")
                        .accessibilityIdentifier(AccessibilityID.historyUndo)
                } else if item.outcome == .succeeded {
                    Text(item.conversionBehavior == .keepOriginal
                         ? "Undo is unavailable because one or both visible files changed or cannot be accessed."
                         : "Undo is unavailable because the file or its retained original cannot be accessed.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(AppSpacing.xLarge)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("history.detail-scroll")
    }

    private var safeNextAction: String {
        switch item.recoveryState {
        case .unresolved(artifact: .available):
            return "Restore the retained original to a separate file, or mark recovery as resolved after handling it manually."
        case .unresolved(artifact: .unavailable):
            return "Keep the item unresolved while investigating, or mark it as resolved if recovery was completed another way."
        case .resolvedByRestore, .resolvedManually:
            return "No further recovery action is required."
        case .notApplicable:
            break
        }
        guard let error = item.errorSummary else { return "" }
        if error.contains("fidelity policy") {
            return "Open Settings › Defaults, choose the required policy, then rename the file again."
        }
        if error.contains("provider") {
            return "Review Formats in Settings. Install or repair the local provider before renaming the file again."
        }
        if error.contains("permission") {
            return "Reauthorize the watched folder in Settings before renaming the file again."
        }
        return "Keep the preserved original, resolve the reported issue, then rename the file again."
    }

    private var recoveryDetailText: String? {
        switch item.recoveryState {
        case .notApplicable: nil
        case .unresolved(artifact: .available): "Retained file available"
        case .unresolved(artifact: .unavailable): "Recovery data unavailable"
        case let .resolvedByRestore(filename, date):
            "Recovered as \(filename) · \(date.formatted(date: .abbreviated, time: .shortened))"
        case let .resolvedManually(date):
            "Resolved manually · \(date.formatted(date: .abbreviated, time: .shortened))"
        }
    }

    private var providerText: String {
        [item.providerName, item.providerVersion].compactMap { $0 }.joined(separator: " · ").nonempty ?? "Not recorded"
    }

    private var availabilityText: String {
        switch item.availability {
        case .available: "Available"
        case .unavailable: "Unavailable"
        case .undoConflict: "Changed after conversion"
        }
    }
}

private struct UndoConflictView: View {
    @Environment(FileConvertViewModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let item: HistoryItemState

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.large) {
            Label(item.conversionBehavior == .keepOriginal ? "A Visible File Has Changed" : "The Current File Has Changed", systemImage: "exclamationmark.triangle.fill")
                .font(.title2.bold()).foregroundStyle(AppColor.warning)
            Text(item.conversionBehavior == .keepOriginal
                 ? "File-Flip will not remove the converted copy because one or both visible files no longer match the completed conversion. Review both files manually."
                 : "File-Flip will not overwrite the changed file. Restore the retained original under a new name to keep both versions.")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(item.conversionBehavior == .keepOriginal ? "Close" : "Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if item.conversionBehavior == .replaceWithBackup {
                    Button("Restore Original as New File…") { model.restoreConflictToNewFile(item) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier(AccessibilityID.historyKeepBoth)
                }
            }
        }
        .padding(AppSpacing.xLarge)
        .frame(width: AppLayout.dialogWidth)
    }
}

private extension String {
    var nonempty: String? { isEmpty ? nil : self }
}
