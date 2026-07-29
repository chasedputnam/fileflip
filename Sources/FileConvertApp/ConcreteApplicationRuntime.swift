import FileConvertCore
import FileConvertProviders
import Foundation

@MainActor
enum ApplicationBootstrap {
    static func makeRuntime() throws -> any ApplicationRuntime {
        let environment = ProcessInfo.processInfo.environment
        let uiTestScenario = environment["FILECONVERT_UI_TESTING"] == "1"
            ? environment["FILECONVERT_UI_TEST_SCENARIO"]
            : nil
        if uiTestScenario == "transparency-choice" || uiTestScenario == "track-choice" {
            UserDefaults.standard.removeObject(forKey: "futureJobDefaults")
        }
        let storage = try uiTestStorage(from: environment)
            ?? ApplicationStorage.prepare(bundleIdentifier: "app.fileconvert.FileConvert")
        let journal = try JournalStore(url: storage.appending(path: "journal.sqlite"))
        let backupRoot = storage.appending(path: "jobs", directoryHint: .isDirectory)
        let retentionDays = min(max(UserDefaults.standard.integer(forKey: "retentionDays").nonzero ?? 30, 1), 365)
        let backupByteLimit = ConcreteApplicationRuntime.storedByteLimit(UserDefaults.standard)
        let transaction = try TransactionCoordinator(
            journal: journal,
            storageRoot: backupRoot,
            retentionDays: retentionDays,
            backupByteLimit: backupByteLimit,
            failpoint: { point in
                if uiTestScenario == "live-failure", point == .afterConversion {
                    throw FileConvertError.validationFailed("UI test conversion failure")
                }
            }
        )
        let authorization = RootAuthorizationService(journal: journal)
        let mediaBundle: Bundle
        #if SWIFT_PACKAGE
        mediaBundle = Bundle.module
        #else
        mediaBundle = Bundle.main
        #endif
        let bundledMediaToolsDirectory = try? BundledMediaToolsLocator().locate(in: mediaBundle)
        let engine = ConversionEngine(
            journal: journal,
            transaction: transaction,
            authorization: authorization,
            mediaToolsDirectory: uiTestScenario == "provider-unavailable"
                ? nil
                : bundledMediaToolsDirectory
        )
        let pipeline = RenamePipeline(roots: [], cursorStore: journal) { stable in
            _ = await engine.handle(stable)
        }
        let monitoring = RootMonitoringController(
            authorization: authorization,
            pipeline: pipeline,
            source: FSEventEventSource()
        )
        return ConcreteApplicationRuntime(
            storage: storage,
            journal: journal,
            authorization: authorization,
            monitoring: monitoring,
            pipeline: pipeline,
            engine: engine,
            undo: UndoCoordinator(journal: journal, storageRoot: backupRoot),
            recovery: RecoveryCoordinator(journal: journal, storageRoot: backupRoot),
            transaction: transaction,
            uiTestScenario: uiTestScenario
        )
    }

    private static func uiTestStorage(from environment: [String: String]) throws -> URL? {
        guard environment["FILECONVERT_UI_TESTING"] == "1",
              let path = environment["FILECONVERT_UI_TEST_STORAGE"],
              !path.isEmpty else {
            return nil
        }
        let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
        return url
    }
}

private actor ConversionEngine {
    private let journal: JournalStore
    private let transaction: TransactionCoordinator
    private let authorization: RootAuthorizationService
    private let registry = ProviderRegistry()
    private let detector = ContentDetector()
    private var initialized = false
    private var defaults = FutureJobDefaults()
    private let mediaToolsDirectory: URL?
    private var knownProviders: [any ConversionProvider] = []
    private var unavailableProviders: [String: String] = [:]
    private var mediaProvider: FFmpegMediaProvider?

    init(journal: JournalStore, transaction: TransactionCoordinator, authorization: RootAuthorizationService, mediaToolsDirectory: URL?) {
        self.journal = journal
        self.transaction = transaction
        self.authorization = authorization
        self.mediaToolsDirectory = mediaToolsDirectory
    }

    func initialize(defaults: FutureJobDefaults) async {
        self.defaults = defaults
        guard !initialized else { return }
        initialized = true

        let image = NativeImageProvider()
        let pdf = NativePDFProvider()
        let markdown = MarkdownHTMLProvider()
        let office = LibreOfficeProvider()
        var providers: [any ConversionProvider] = [image, pdf, markdown, office]

        let imageValidator = NativeImageValidator().certificationValidator()
        let pdfValidator = PDFValidator().certificationValidator()
        let textValidator = TextValidator().certificationValidator()
        let htmlValidator = HTMLValidator().certificationValidator()
        let markdownValidator = MarkdownValidator().certificationValidator()
        let pdfImageValidator = PDFPageImageValidator().certificationValidator()
        let officeValidator = OfficeArtifactValidator().validator()
        var validators = [imageValidator, pdfValidator, textValidator, htmlValidator, markdownValidator, pdfImageValidator, officeValidator]
        if let mediaToolsDirectory {
            do {
                let media = try await PackagedMediaBootstrap().load(from: mediaToolsDirectory)
                mediaProvider = media.provider
                providers.append(media.provider)
                validators.append(media.validator)
            } catch {
                unavailableProviders["ffmpeg"] = "Required local provider failed verification"
            }
        } else {
            unavailableProviders["ffmpeg"] = "Required local provider is not bundled"
        }
        knownProviders = providers
        for validator in validators {
            await registry.register(validator)
        }

        for provider in providers {
            await registry.register(provider)
            for capability in await provider.capabilities() {
                guard let validatorID = Self.validatorID(for: capability, providerID: provider.id) else { continue }
                await registry.certify(CapabilityCertification(
                    source: capability.source,
                    targetExtension: capability.targetExtension,
                    providerID: provider.id,
                    validatorID: validatorID,
                    fixtureIDs: ["bundled-runtime-certification"]
                ))
            }
        }
    }

    func setDefaults(_ defaults: FutureJobDefaults) { self.defaults = defaults }

    func capabilities() async -> Set<ConversionCapability> { await registry.capabilities() }

    func providerSnapshots() async -> [(String, ProviderHealth, [String])] {
        let capabilities = await registry.capabilities()
        let grouped = Dictionary(grouping: capabilities, by: { $0.providerID.rawValue })
        var values: [(String, ProviderHealth, [String])] = []
        for provider in knownProviders {
            let id = provider.id.rawValue
            let health = await provider.health()
            let pairs = grouped[id, default: []].map(Self.pairDescription).sorted()
            values.append((id, health, pairs))
        }
        for (id, reason) in unavailableProviders where !values.contains(where: { $0.0 == id }) {
            values.append((id, .unavailable(reason: reason), []))
        }
        return values.sorted { $0.0 < $1.0 }
    }

    private static func pairDescription(_ capability: ConversionCapability) -> String {
        let source: String
        switch capability.source {
        case let .image(format): source = format.rawValue.uppercased()
        case let .audio(format): source = format.rawValue.uppercased()
        case let .video(format): source = format.rawValue.uppercased()
        case let .document(format): source = format.rawValue.uppercased()
        case let .spreadsheet(format): source = format.rawValue.uppercased()
        }
        let limitation = switch capability.lossProfile {
        case .lossless: "preserves supported content"
        case .potentiallyLossy: "may reduce fidelity"
        case .requiresChoice: "requires a policy choice"
        }
        return "\(source) → \(capability.targetExtension.uppercased()) · \(limitation)"
    }

    @discardableResult
    func handle(_ stable: StableRename, policyOverride: ConversionPolicy? = nil) async -> Bool {
        do {
            try await perform(stable, policyOverride: policyOverride)
            return true
        } catch {
            // TransactionCoordinator records failures once a job exists. Preflight mismatches are intentionally ignored.
            return false
        }
    }

    func handleResuming(_ stable: StableRename, policyOverride: ConversionPolicy? = nil) async throws {
        try await perform(stable, policyOverride: policyOverride)
    }

    private func perform(_ stable: StableRename, policyOverride: ConversionPolicy?) async throws {
        let requestDefaults = FutureJobDefaultsSnapshot(defaults)
        guard let sourceFormat = try await detector.detect(stable.url) else {
            throw FileConvertError.unsupportedPair
        }
        let targetExtension = stable.url.pathExtension.lowercased()
        guard let capability = await registry.capability(source: sourceFormat, targetExtension: targetExtension),
              let provider = await registry.provider(for: capability),
              let validator = await registry.validator(for: capability),
              let targetFormat = Self.targetFormat(for: targetExtension) else {
            throw FileConvertError.unsupportedPair
        }
        guard let root = await authorization.allRoots().first(where: { $0.id == stable.candidate.rootID }) else {
            throw FileConvertError.permissionDenied
        }
        let health = await provider.health()
        guard case let .available(version) = health else {
            if case let .unavailable(reason) = health {
                throw FileConvertError.providerUnavailable(reason)
            }
            throw FileConvertError.providerUnavailable("Provider health is unknown")
        }
        let policy = policyOverride ?? Self.policy(for: targetFormat, defaults: requestDefaults)
        let request = TransactionRequest(
            rootID: root.id,
            rootURL: root.url,
            oldRelativePath: stable.candidate.oldRelativePath,
            newRelativePath: stable.candidate.newRelativePath,
            sourceFormat: sourceFormat,
            targetFormat: targetFormat,
            targetExtension: targetExtension,
            providerID: provider.id,
            providerVersion: version,
            policy: policy,
            conversionBehavior: requestDefaults.conversionBehavior
        )
        let choiceMediaProvider = policyOverride == nil && provider.id == mediaProvider?.id ? mediaProvider : nil
        _ = try await transaction.execute(request, produce: { staged, outputDirectory in
            let attributes = try FileManager.default.attributesOfItem(atPath: staged.path)
            let snapshot = Snapshot(
                url: staged,
                fileKey: stable.candidate.fileKey,
                byteCount: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
                modificationDate: attributes[.modificationDate] as? Date ?? .distantPast
            )
            if let mediaProvider = choiceMediaProvider {
                let required = try await mediaProvider.requiredTrackChoices(
                    for: staged,
                    targetExtension: targetExtension,
                    policy: policy
                )
                guard required.isEmpty else { throw FileConvertError.requiresChoice }
            }
            return try await provider.convert(ConversionRequest(
                jobID: request.id,
                source: snapshot,
                targetExtension: targetExtension,
                policy: policy,
                outputDirectory: outputDirectory,
                deadline: Date().addingTimeInterval(15 * 60),
                maximumOutputBytes: max(1 << 30, snapshot.byteCount * 2)
            ))
        }, validate: validator.validate)
    }

    func requiredTrackChoices(
        for job: JournalJob,
        root: AuthorizedRoot
    ) async -> MediaTrackChoicesRequired? {
        guard job.errorCode == "requiresChoice",
              job.providerID == InstalledMediaContract.providerID.rawValue,
              let mediaProvider,
              let policyJSON = job.policyJSON,
              let policy = try? BoundaryGuards.decodePolicy(policyJSON) else {
            return nil
        }
        let source = root.url.appending(path: job.oldRelativePath)
        guard FileManager.default.fileExists(atPath: source.path) else { return nil }
        return try? await mediaProvider.requiredTrackChoices(
            for: source,
            targetExtension: URL(fileURLWithPath: job.newRelativePath).pathExtension,
            policy: policy
        )
    }

    private static func policy(for target: DetectedFormat, defaults: FutureJobDefaultsSnapshot) -> ConversionPolicy {
        switch target {
        case .image: defaults.image.policy
        case .audio: defaults.audio.policy
        case .video: defaults.video.policy
        case .document: defaults.document.policy
        case .spreadsheet: defaults.spreadsheet.policy
        }
    }

    private static func validatorID(for capability: ConversionCapability, providerID: ProviderID) -> ValidatorID? {
        if providerID == NativeImageProvider().id { return NativeImageValidator.id }
        if providerID == NativePDFProvider().id {
            switch capability.targetExtension {
            case "png", "jpg", "jpeg": return PDFPageImageValidator.id
            case "txt": return TextValidator.id
            default: return nil
            }
        }
        if providerID == MarkdownHTMLProvider().id {
            switch capability.targetExtension {
            case "pdf": return PDFValidator.id
            case "html": return HTMLValidator.id
            case "md", "markdown": return MarkdownValidator.id
            default: return nil
            }
        }
        if providerID.rawValue == "ffmpeg" { return FFprobeMediaValidator.id }
        if providerID == LibreOfficeProvider().id { return OfficeArtifactValidator.id }
        return nil
    }

    private static func targetFormat(for ext: String) -> DetectedFormat? {
        if let mediaFormat = InstalledMediaContract.format(forExtension: ext) {
            return mediaFormat
        }
        return switch ext {
        case "jpg", "jpeg": .image(.jpeg)
        case "png": .image(.png)
        case "heic", "heif": .image(.heic)
        case "tif", "tiff": .image(.tiff)
        case "webp": .image(.webP)
        case "pdf": .document(.pdf)
        case "docx": .document(.docx)
        case "odt": .document(.odt)
        case "rtf": .document(.rtf)
        case "txt": .document(.text)
        case "md", "markdown": .document(.markdown)
        case "html", "htm": .document(.html)
        case "xlsx": .spreadsheet(.xlsx)
        case "ods": .spreadsheet(.ods)
        case "csv": .spreadsheet(.csv)
        default: nil
        }
    }
}

func conversionDuration(createdAt: Date, updatedAt: Date) -> TimeInterval {
    max(0, updatedAt.timeIntervalSince(createdAt))
}

@MainActor
private final class ConcreteApplicationRuntime: ApplicationRuntime {
    private let storage: URL
    private let journal: JournalStore
    private let authorization: RootAuthorizationService
    private let monitoring: RootMonitoringController
    private let pipeline: RenamePipeline
    private let engine: ConversionEngine
    private let undoCoordinator: UndoCoordinator
    private let recoveryCoordinator: RecoveryCoordinator
    private let transaction: TransactionCoordinator
    private let launchAtLogin: any LaunchAtLoginControlling = SystemLaunchAtLoginController()
    private let defaultsStore = UserDefaults.standard
    private let uiTestScenario: String?
    private var cachedProviders: [ProviderState]?
    private var initialized = false
    private var paused = false

    init(
        storage: URL,
        journal: JournalStore,
        authorization: RootAuthorizationService,
        monitoring: RootMonitoringController,
        pipeline: RenamePipeline,
        engine: ConversionEngine,
        undo: UndoCoordinator,
        recovery: RecoveryCoordinator,
        transaction: TransactionCoordinator,
        uiTestScenario: String?
    ) {
        self.storage = storage
        self.journal = journal
        self.authorization = authorization
        self.monitoring = monitoring
        self.pipeline = pipeline
        self.engine = engine
        self.undoCoordinator = undo
        self.recoveryCoordinator = recovery
        self.transaction = transaction
        self.uiTestScenario = uiTestScenario
    }

    func snapshot() async throws -> ApplicationSnapshot {
        try await ensureInitialized()
        var roots = await authorization.allRoots()
        if uiTestScenario == "permission-blocked" {
            roots = roots.map {
                AuthorizedRoot(
                    id: $0.id,
                    url: $0.url,
                    volumeUUID: $0.volumeUUID,
                    enabled: true,
                    eventCursor: $0.eventCursor,
                    status: .permissionLost
                )
            }
        }
        let jobs = try await journal.recentHistory(limit: 100)
        let backups = try await journal.backupsForHistory()
        let providerStates = cachedProviders ?? []
        let launchStatus = launchAtLogin.status()
        let backupJobIDs = Set(backups.map(\.jobID))
        let rootsByID = Dictionary(uniqueKeysWithValues: roots.map { ($0.id, $0) })
        var history: [HistoryItemState] = []
        history.reserveCapacity(jobs.count)
        for job in jobs {
            let requiredChoice: HistoryItemState.RequiredChoice?
            if job.errorCode == "requiresChoice",
               job.providerID == NativeImageProvider().id.rawValue,
               job.targetFormat.lowercased().contains("jpeg") {
                requiredChoice = .transparencyBackground
            } else if let root = rootsByID[job.rootID],
                      let choices = await engine.requiredTrackChoices(for: job, root: root),
                      !choices.isEmpty {
                requiredChoice = .mediaTracks(
                    audio: choices.audio.map { .init(index: $0.index, label: $0.label) },
                    subtitles: choices.subtitles.map { .init(index: $0.index, label: $0.label) }
                )
            } else {
                requiredChoice = nil
            }
            let recoveryState: HistoryItemState.RecoveryState
            if job.state == .needsRecovery, job.conversionBehavior == .replaceWithBackup {
                if let resolution = try await journal.recoveryResolution(jobID: job.id) {
                    switch resolution.method {
                    case .restored:
                        recoveryState = .resolvedByRestore(
                            filename: resolution.destinationFilename ?? "restored file",
                            date: resolution.resolvedAt
                        )
                    case .acknowledged:
                        recoveryState = .resolvedManually(date: resolution.resolvedAt)
                    }
                } else {
                    recoveryState = .unresolved(
                        artifact: await recoveryCoordinator.retainedArtifactIsAvailable(jobID: job.id)
                            ? .available
                            : .unavailable
                    )
                }
            } else {
                recoveryState = .notApplicable
            }
            let recoverySuggestedDirectory: URL?
            if case .unresolved = recoveryState, let root = rootsByID[job.rootID] {
                let canonicalRoot = root.url.standardizedFileURL
                let directory = canonicalRoot
                    .appending(path: job.oldRelativePath)
                    .deletingLastPathComponent()
                    .standardizedFileURL
                var isDirectory: ObjCBool = false
                let isContained = directory.path == canonicalRoot.path
                    || directory.path.hasPrefix(canonicalRoot.path + "/")
                recoverySuggestedDirectory = isContained
                    && FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory)
                    && isDirectory.boolValue
                    ? directory
                    : nil
            } else {
                recoverySuggestedDirectory = nil
            }
            history.append(HistoryItemState(
                id: job.id,
                rootID: job.rootID,
                fileName: URL(fileURLWithPath: job.newRelativePath).lastPathComponent,
                sourceFormat: job.sourceFormat ?? "Unknown",
                targetFormat: job.targetFormat,
                outcome: job.state,
                conversionBehavior: job.conversionBehavior,
                date: job.updatedAt,
                conversionDuration: conversionDuration(createdAt: job.createdAt, updatedAt: job.updatedAt),
                providerName: job.providerID.map(Self.providerName),
                providerVersion: job.providerVersion,
                fidelityWarning: Self.fidelityWarning(for: job),
                errorSummary: Self.redactedError(code: job.errorCode),
                requiredChoice: requiredChoice,
                availability: Self.historyAvailability(
                    job: job,
                    root: rootsByID[job.rootID],
                    hasBackup: backupJobIDs.contains(job.id)
                ),
                recoveryState: recoveryState,
                recoverySuggestedDirectory: recoverySuggestedDirectory,
                recoveryOriginalFilename: job.state == .needsRecovery
                    ? URL(filePath: job.oldRelativePath).lastPathComponent
                    : nil
            ))
        }
        return ApplicationSnapshot(
            monitoringStatus: paused ? .paused : await pipeline.status,
            convertingCount: try await journal.nonterminalJobs().filter { $0.state == .converting || $0.state == .validating }.count,
            roots: roots,
            providers: providerStates,
            history: history,
            backupUsage: try await journal.backupUsage(),
            backupLimit: Self.storedByteLimit(defaultsStore),
            retentionDays: defaultsStore.integer(forKey: "retentionDays").nonzero ?? 30,
            launchAtLoginStatus: launchStatus,
            defaults: loadDefaults()
        )
    }

    func authorizeFolders(_ urls: [URL]) async throws { try await ensureInitialized(); try await monitoring.authorize(urls) }
    func setFolderEnabled(id: UUID, enabled: Bool) async throws { try await ensureInitialized(); try await monitoring.setEnabled(id: id, enabled: enabled) }
    func removeFolder(id: UUID) async throws { try await ensureInitialized(); try await monitoring.remove(id: id) }
    func reauthorizeFolder(id: UUID, url: URL) async throws { try await ensureInitialized(); try await monitoring.reAuthorize(id: id, with: url) }

    func setMonitoringPaused(_ paused: Bool) async throws {
        try await ensureInitialized()
        self.paused = paused
        if paused { await monitoring.stop() } else { try await monitoring.restoreAndStart() }
    }

    func setLaunchAtLogin(_ enabled: Bool) async throws { try launchAtLogin.setEnabled(enabled) }

    func saveDefaults(_ defaults: FutureJobDefaults) async throws {
        defaultsStore.set(try JSONEncoder().encode(defaults), forKey: "futureJobDefaults")
        await engine.setDefaults(defaults)
    }

    func resolveTransparencyChoice(for item: HistoryItemState, backgroundARGB: UInt32) async throws {
        try await ensureInitialized()
        guard backgroundARGB == 0xFFFF_FFFF || backgroundARGB == 0xFF00_0000,
              let job = try await journal.job(id: item.id),
              job.state == .failed,
              job.errorCode == "requiresChoice",
              job.providerID == NativeImageProvider().id.rawValue,
              job.targetFormat.lowercased().contains("jpeg"),
              let sourceHash = job.sourceHash,
              let root = await authorization.allRoots().first(where: {
                  $0.id == job.rootID && $0.enabled && $0.status == .active
              }) else {
            throw FileConvertError.requiresChoice
        }

        let oldParent = (job.oldRelativePath as NSString).deletingLastPathComponent
        let newParent = (job.newRelativePath as NSString).deletingLastPathComponent
        let newName = (job.newRelativePath as NSString).lastPathComponent
        guard oldParent == newParent,
              !newName.isEmpty,
              newName != ".",
              newName != ".." else {
            throw FileConvertError.validationFailed("Invalid retry path")
        }

        let original = try BoundaryGuards.canonicalRegularFile(
            root: root.url,
            relativePath: job.oldRelativePath
        )
        guard try TransactionCoordinator.sha256(original) == sourceHash else {
            throw FileConvertError.sourceChanged
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: original.path)
        let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0
        let fileID = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        guard job.fileKey == "\(device):\(fileID)" else {
            throw FileConvertError.sourceChanged
        }

        var defaults = loadDefaults()
        defaults.image.alphaBackgroundARGB = backgroundARGB
        try await saveDefaults(defaults)

        let target = original.deletingLastPathComponent().appending(path: newName)
        guard !FileManager.default.fileExists(atPath: target.path) else {
            throw FileConvertError.destinationExists
        }

        let candidate = RenameCandidate(
            eventID: root.eventCursor,
            rootID: root.id,
            fileKey: FileKey(volumeUUID: root.volumeUUID, fileID: fileID),
            oldRelativePath: job.oldRelativePath,
            newRelativePath: job.newRelativePath,
            observedAt: Date()
        )
        let stable = StableRename(candidate: candidate, url: target, sourceHash: sourceHash)
        await pipeline.reserveRetry(stable)
        try FileManager.default.moveItem(at: original, to: target)
        do {
            try await engine.handleResuming(stable)
        } catch {
            if FileManager.default.fileExists(atPath: target.path),
               !FileManager.default.fileExists(atPath: original.path) {
                try FileManager.default.moveItem(at: target, to: original)
            }
            throw error
        }
        if (try? await journal.removeFailedChoiceJob(jobID: job.id)) == true {
            try? FileManager.default.removeItem(
                at: storage.appending(path: "jobs/\(job.id.uuidString)", directoryHint: .isDirectory)
            )
        }
    }

    func resolveMediaTrackChoice(
        for item: HistoryItemState,
        audioTrack: Int?,
        subtitleTrack: Int?
    ) async throws {
        try await ensureInitialized()
        guard let job = try await journal.job(id: item.id),
              job.state == .failed,
              job.errorCode == "requiresChoice",
              job.providerID == InstalledMediaContract.providerID.rawValue,
              let sourceHash = job.sourceHash,
              let policyJSON = job.policyJSON,
              let root = await authorization.allRoots().first(where: {
                  $0.id == job.rootID && $0.enabled && $0.status == .active
              }),
              let required = await engine.requiredTrackChoices(for: job, root: root) else {
            throw FileConvertError.requiresChoice
        }
        guard (required.audio.isEmpty && audioTrack == nil)
                || required.audio.contains(where: { $0.index == audioTrack }),
              (subtitleTrack == nil
                || required.subtitles.isEmpty
                || required.subtitles.contains(where: { $0.index == subtitleTrack })) else {
            throw FileConvertError.requiresChoice
        }

        let existingPolicy = try BoundaryGuards.decodePolicy(policyJSON)
        let selectedPolicy: ConversionPolicy
        switch existingPolicy {
        case let .audio(version, bitrate, sampleRate, existingTrack):
            selectedPolicy = .audio(
                version: version,
                bitrate: bitrate,
                sampleRate: sampleRate,
                trackIndex: required.audio.isEmpty ? existingTrack : audioTrack
            )
        case let .video(version, quality, existingAudio, existingSubtitle):
            selectedPolicy = .video(
                version: version,
                quality: quality,
                audioTrack: required.audio.isEmpty ? existingAudio : audioTrack,
                subtitleTrack: required.subtitles.isEmpty ? existingSubtitle : subtitleTrack
            )
        default:
            throw FileConvertError.requiresChoice
        }

        let original = try BoundaryGuards.canonicalRegularFile(
            root: root.url,
            relativePath: job.oldRelativePath
        )
        guard try TransactionCoordinator.sha256(original) == sourceHash else {
            throw FileConvertError.sourceChanged
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: original.path)
        let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0
        let fileID = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        guard job.fileKey == "\(device):\(fileID)" else {
            throw FileConvertError.sourceChanged
        }

        let newName = (job.newRelativePath as NSString).lastPathComponent
        let target = original.deletingLastPathComponent().appending(path: newName)
        guard !FileManager.default.fileExists(atPath: target.path) else {
            throw FileConvertError.destinationExists
        }

        let candidate = RenameCandidate(
            eventID: root.eventCursor,
            rootID: root.id,
            fileKey: FileKey(volumeUUID: root.volumeUUID, fileID: fileID),
            oldRelativePath: job.oldRelativePath,
            newRelativePath: job.newRelativePath,
            observedAt: Date()
        )
        let stable = StableRename(candidate: candidate, url: target, sourceHash: sourceHash)
        guard await pipeline.reserve(stable) else { return }
        try FileManager.default.moveItem(at: original, to: target)
        do {
            try await engine.handleResuming(stable, policyOverride: selectedPolicy)
        } catch {
            if FileManager.default.fileExists(atPath: target.path),
               !FileManager.default.fileExists(atPath: original.path) {
                try FileManager.default.moveItem(at: target, to: original)
            }
            throw error
        }
    }

    func saveRetention(days: Int, byteLimit: UInt64) async throws {
        let boundedDays = min(max(days, 1), 365)
        let boundedByteLimit = max(byteLimit, 1)
        try await transaction.configureRetention(days: boundedDays, byteLimit: boundedByteLimit)
        defaultsStore.set(boundedDays, forKey: "retentionDays")
        defaultsStore.set(boundedByteLimit, forKey: "backupByteLimit")
    }

    func undo(_ item: HistoryItemState) async throws -> UndoResult {
        guard let root = await authorization.allRoots().first(where: { $0.id == item.rootID }) else { throw RootAuthorizationError.missingRoot }
        return try await undoCoordinator.undo(jobID: item.id, rootURL: root.url)
    }

    func restoreToNewFile(_ item: HistoryItemState, destination: URL) async throws -> URL {
        try await undoCoordinator.restoreToNewFile(jobID: item.id, destination: destination)
    }

    func restoreRecovery(_ item: HistoryItemState, destination: URL) async throws -> URL {
        try await ensureInitialized()
        let restored = try await recoveryCoordinator.restoreRetainedFile(
            jobID: item.id,
            destination: destination
        )
        try? await undoCoordinator.prune(byteLimit: Self.storedByteLimit(defaultsStore))
        return restored
    }

    func acknowledgeRecovery(_ item: HistoryItemState) async throws {
        try await ensureInitialized()
        try await recoveryCoordinator.acknowledgeRecovery(jobID: item.id)
        try? await undoCoordinator.prune(byteLimit: Self.storedByteLimit(defaultsStore))
    }

    func clearHistory() async throws {
        let jobIDs = try await journal.clearableHistoryJobIDs()
        let fileManager = FileManager.default
        let jobsDirectory = storage.appending(path: "jobs", directoryHint: .isDirectory)
        let quarantine = storage.appending(
            path: ".history-clear-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try fileManager.createDirectory(
            at: quarantine,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        var movedDirectories: [(original: URL, staged: URL)] = []
        do {
            for jobID in jobIDs {
                let original = jobsDirectory.appending(
                    path: jobID.uuidString,
                    directoryHint: .isDirectory
                )
                guard fileManager.fileExists(atPath: original.path) else { continue }
                let staged = quarantine.appending(
                    path: jobID.uuidString,
                    directoryHint: .isDirectory
                )
                try fileManager.moveItem(at: original, to: staged)
                movedDirectories.append((original, staged))
            }
            try await journal.clearHistory()
        } catch {
            for item in movedDirectories.reversed() {
                try? fileManager.moveItem(at: item.staged, to: item.original)
            }
            try? fileManager.removeItem(at: quarantine)
            throw error
        }
        try fileManager.removeItem(at: quarantine)
    }

    private func ensureInitialized() async throws {
        guard !initialized else { return }
        initialized = true
        do {
            let defaults = loadDefaults()
            await engine.initialize(defaults: defaults)
            cachedProviders = await engine.providerSnapshots().map {
                ProviderState(id: $0.0, name: Self.providerName($0.0), health: $0.1, pairs: $0.2)
            }
            try await seedUITestScenarioIfNeeded()
            try await monitoring.restoreAndStart()
        } catch {
            initialized = false
            throw error
        }
    }

    private func seedUITestScenarioIfNeeded() async throws {
        guard let scenario = uiTestScenario, scenario != "first-launch" else { return }
        guard try await journal.authorizedRoots().isEmpty else { return }

        let fileManager = FileManager.default
        let rootURL = storage.appending(path: "Watched", directoryHint: .isDirectory)
        try fileManager.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        _ = try await authorization.authorize([rootURL])
        guard let root = await authorization.allRoots().first else {
            throw RootAuthorizationError.missingRoot
        }
        if scenario == "permission-blocked" {
            return
        }

        let fixture: (
            oldName: String,
            newName: String,
            source: String,
            target: String,
            state: PersistentJobState,
            errorCode: String?,
            providerID: String,
            behavior: ConversionBehavior
        )
        switch scenario {
        case "successful":
            fixture = ("photo.jpg", "photo.png", "JPEG", "PNG", .succeeded, nil, "native-imageio", .replaceWithBackup)
        case "copy-success":
            fixture = ("photo.jpg", "photo.png", "JPEG", "PNG", .succeeded, nil, "native-imageio", .keepOriginal)
        case "recovery-required", "recovery-unavailable", "recovery-resolved", "recovery-manual", "recovery-conflict":
            fixture = ("draft.docx", "draft.pdf", "DOCX", "PDF", .needsRecovery, "ambiguousCommit", "installed-libreoffice", .replaceWithBackup)
        case "unavailable-file":
            fixture = ("missing.jpg", "missing.png", "JPEG", "PNG", .succeeded, nil, "native-imageio", .replaceWithBackup)
        case "needs-choice":
            fixture = ("workbook.xlsx", "workbook.csv", "XLSX", "CSV", .failed, "needsChoice", "installed-libreoffice", .replaceWithBackup)
        case "transparency-choice":
            fixture = ("transparent.webp", "transparent.jpg", "WEBP", "JPEG", .failed, "requiresChoice", "native-imageio", .replaceWithBackup)
        case "track-choice":
            fixture = ("recording.mov", "recording.mkv", "MOV", "MKV", .failed, "requiresChoice", "ffmpeg", .replaceWithBackup)
        case "provider-unavailable":
            fixture = ("clip.mov", "clip.webm", "MOV", "WEBM", .failed, "providerUnavailable", "ffmpeg", .replaceWithBackup)
        case "failure":
            fixture = ("broken.mp4", "broken.mov", "MP4", "MOV", .failed, "conversionFailed", "ffmpeg", .replaceWithBackup)
        case "undo-conflict":
            fixture = ("report.docx", "report.pdf", "DOCX", "PDF", .succeeded, nil, "installed-libreoffice", .replaceWithBackup)
        case "converting":
            fixture = ("recording.mov", "recording.mp4", "MOV", "MP4", .converting, nil, "ffmpeg", .replaceWithBackup)
        default:
            return
        }

        let jobID = UUID()
        let targetURL = rootURL.appending(path: fixture.newName)
        let isResumableChoice = scenario == "transparency-choice" || scenario == "track-choice"
        let visibleData: Data
        let expectedOutputData: Data
        if scenario == "undo-conflict" {
            visibleData = Data("changed after conversion".utf8)
            expectedOutputData = Data("expected converted output".utf8)
        } else if scenario == "transparency-choice" {
            visibleData = Data(base64Encoded: "UklGRhwAAABXRUJQVlA4TA8AAAAvAAAAEAcQ/Y8CBSKi/wEA")!
            expectedOutputData = visibleData
        } else {
            visibleData = Data("converted output".utf8)
            expectedOutputData = visibleData
        }
        if isResumableChoice {
            let originalURL = rootURL.appending(path: fixture.oldName)
            if !fileManager.fileExists(atPath: originalURL.path) {
                try visibleData.write(to: originalURL, options: .atomic)
            }
        } else if scenario != "unavailable-file" {
            try visibleData.write(to: targetURL, options: .atomic)
        }

        if scenario == "recovery-conflict" {
            try Data("user-owned recovery destination".utf8).write(
                to: rootURL.appending(path: "draft — Recovered.docx")
            )
        }
        let now = Date()
        let backupData = isResumableChoice ? visibleData : Data("exact original bytes".utf8)
        let backupURL = storage
            .appending(path: "jobs", directoryHint: .isDirectory)
            .appending(path: jobID.uuidString, directoryHint: .isDirectory)
            .appending(path: "backup", directoryHint: .isDirectory)
            .appending(path: "source")
        let sourceHash: Data?
        if fixture.state == .converting {
            sourceHash = nil
        } else if isResumableChoice {
            let originalURL = rootURL.appending(path: fixture.oldName)
            sourceHash = try TransactionCoordinator.sha256(originalURL)
        } else if fixture.behavior == .keepOriginal {
            let originalURL = rootURL.appending(path: fixture.oldName)
            try backupData.write(to: originalURL, options: .atomic)
            sourceHash = try TransactionCoordinator.sha256(originalURL)
        } else {
            try fileManager.createDirectory(
                at: backupURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try backupData.write(to: backupURL)
            sourceHash = try TransactionCoordinator.sha256(backupURL)
            if scenario == "recovery-unavailable" {
                try fileManager.removeItem(at: backupURL)
            }
        }

        let expectedURL = storage.appending(path: ".expected-\(jobID.uuidString)")
        try expectedOutputData.write(to: expectedURL)
        defer { try? fileManager.removeItem(at: expectedURL) }
        let outputHash = try TransactionCoordinator.sha256(expectedURL)
        let fileKey: String
        if isResumableChoice {
            let attributes = try fileManager.attributesOfItem(
                atPath: rootURL.appending(path: fixture.oldName).path
            )
            let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0
            let fileID = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            fileKey = "\(device):\(fileID)"
        } else {
            fileKey = "ui-test-\(jobID.uuidString)"
        }

        let policyJSON = scenario == "track-choice"
            ? try BoundaryGuards.strictPolicyData(.video())
            : nil


        try await journal.insert(
            JournalJob(
                id: jobID,
                rootID: root.id,
                fileKey: fileKey,
                oldRelativePath: fixture.oldName,
                newRelativePath: fixture.newName,
                sourceFormat: fixture.source,
                targetFormat: fixture.target,
                providerID: fixture.providerID,
                providerVersion: "UI Test Fixture",
                policyJSON: policyJSON,
                sourceHash: sourceHash,
                outputHash: fixture.state == .succeeded ? outputHash : nil,
                state: fixture.state,
                conversionBehavior: fixture.behavior,
                createdAt: now,
                updatedAt: now,
                errorCode: fixture.errorCode,
                errorDetail: scenario == "failure"
                    ? "private fixture detail /Users/example/Secret/project.mov"
                    : nil
            )
        )
        if scenario == "transparency-choice", let sourceHash {
            let originalURL = rootURL.appending(path: fixture.oldName)
            let attributes = try fileManager.attributesOfItem(atPath: originalURL.path)
            let fileID = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            let candidate = RenameCandidate(
                eventID: root.eventCursor,
                rootID: root.id,
                fileKey: FileKey(volumeUUID: root.volumeUUID, fileID: fileID),
                oldRelativePath: fixture.oldName,
                newRelativePath: fixture.newName,
                observedAt: now
            )
            _ = await pipeline.reserve(StableRename(candidate: candidate, url: targetURL, sourceHash: sourceHash))
        }
        if fixture.behavior == .replaceWithBackup, let sourceHash {
            try await journal.insertBackup(
                BackupRecord(
                    jobID: jobID,
                    relativeStoragePath: "\(jobID.uuidString)/backup/source",
                    byteCount: UInt64(backupData.count),
                    sha256: sourceHash,
                    metadata: try JSONEncoder().encode(
                        FileMetadata(
                            permissions: 0o600,
                            creationDate: now,
                            modificationDate: now
                        )
                    ),
                    expiresAt: Calendar(identifier: .gregorian).date(
                        byAdding: .day,
                        value: 30,
                        to: now
                    )!
                )
            )
        }
        if scenario == "recovery-resolved" || scenario == "recovery-manual" {
            try await journal.resolveRecovery(
                RecoveryResolutionRecord(
                    jobID: jobID,
                    method: scenario == "recovery-resolved" ? .restored : .acknowledged,
                    destinationFilename: scenario == "recovery-resolved" ? "draft — Recovered.docx" : nil,
                    resolvedAt: now
                )
            )
        }
    }

    private func loadDefaults() -> FutureJobDefaults {
        guard let data = defaultsStore.data(forKey: "futureJobDefaults"), let value = try? JSONDecoder().decode(FutureJobDefaults.self, from: data) else { return FutureJobDefaults() }
        return value
    }

    fileprivate static func storedByteLimit(_ store: UserDefaults) -> UInt64 {
        let value = store.object(forKey: "backupByteLimit") as? NSNumber
        return value?.uint64Value ?? 10 << 30
    }

    private static func historyAvailability(
        job: JournalJob,
        root: AuthorizedRoot?,
        hasBackup: Bool
    ) -> HistoryItemState.Availability {
        guard job.state == .succeeded,
              let root,
              root.enabled,
              root.status == .active,
              let sourceHash = job.sourceHash,
              let outputHash = job.outputHash,
              let live = try? BoundaryGuards.canonicalRegularFile(root: root.url, relativePath: job.newRelativePath) else {
            return .unavailable
        }
        if job.conversionBehavior == .keepOriginal {
            guard (try? TransactionCoordinator.sha256(live)) == outputHash,
                  let original = try? BoundaryGuards.canonicalRegularFile(root: root.url, relativePath: job.oldRelativePath),
                  (try? TransactionCoordinator.sha256(original)) == sourceHash else {
                return .unavailable
            }
            return .available
        }
        return hasBackup ? .available : .unavailable
    }

    private static func redactedError(code: String?) -> String? {
        switch code {
        case nil:
            nil
        case "providerUnavailable":
            "The required local provider is unavailable. The file was not changed."
        case "unsupportedPair":
            "This conversion pair is not available on this Mac. The file was not changed."
        case "requiresChoice", "needsChoice":
            "Choose a fidelity policy before trying this conversion again."
        case "sourceChanged":
            "The file changed during conversion, so FileFlip did not replace it."
        case "permissionDenied":
            "Folder permission was lost. Reauthorize the folder to continue."
        case "insufficientDiskSpace":
            "There is not enough space for a safe backup and output."
        case "ambiguousCommit":
            "The file needs recovery. No version was overwritten automatically."
        default:
            "Conversion could not be completed safely. The original file was preserved."
        }
    }

    private static func fidelityWarning(for job: JournalJob) -> String? {
        guard job.state == .succeeded else { return nil }
        let target = job.targetFormat.lowercased()
        guard ["pdf", "txt", "text", "html", "csv"].contains(where: target.contains) else {
            return nil
        }
        return "The target format may not preserve every layout, formula, or interactive feature."
    }

    private static func providerName(_ id: String) -> String {
        switch id {
        case "native-imageio": "Images"
        case "native-pdfkit": "PDF"
        case "native-markdown-html": "Markdown and HTML"
        case "installed-libreoffice": "LibreOffice"
        case "ffmpeg": "Audio and Video"
        default: id
        }
    }
}

private extension Int {
    var nonzero: Int? { self == 0 ? nil : self }
}
