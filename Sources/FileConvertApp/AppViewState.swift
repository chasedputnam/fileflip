import FileConvertCore
import Foundation
import SwiftUI

enum MenuBarState: String, CaseIterable, Sendable {
    case idle
    case monitoring
    case converting
    case paused
    case needsChoice
    case conversionFailed
    case degraded
    case blocked
    case needsRecovery

    var title: String {
        switch self {
        case .idle: "Ready"
        case .monitoring: "Monitoring"
        case .converting: "Converting"
        case .paused: "Paused"
        case .conversionFailed: "Conversion Failed"
        case .needsChoice: "Choice Required"
        case .degraded: "Limited Monitoring"
        case .blocked: "Monitoring Blocked"
        case .needsRecovery: "Recovery Required"
        }
    }

    var accessibilityDescription: String {
        switch self {
        case .idle: "idle, no folders currently monitored"
        case .monitoring: "monitoring authorized folders"
        case .converting: "conversion in progress"
        case .paused: "monitoring paused"
        case .needsChoice: "a conversion needs a policy choice"
        case .conversionFailed: "the last conversion failed"
        case .degraded: "some folders or providers are unavailable"
        case .blocked: "monitoring is blocked"
        case .needsRecovery: "a file needs safe recovery"
        }
    }

    var systemImage: String {
        switch self {
        case .idle, .monitoring: "checkmark.seal.text.page"
        case .converting: "arrow.triangle.2.circlepath.circle.fill"
        case .paused: "pause.circle.fill"
        case .conversionFailed, .degraded: "exclamationmark.triangle.text.page"
        case .needsChoice: "questionmark.text.page"
        case .blocked: "xmark.octagon.fill"
        case .needsRecovery: "waveform.path.ecg.text.page"
        }
    }
}

struct WatchedFolderState: Identifiable, Sendable {
    let id: UUID
    let name: String
    let path: String
    var isEnabled: Bool
    let status: AuthorizedRootStatus

    init(root: AuthorizedRoot) {
        id = root.id
        name = root.url.lastPathComponent
        path = root.url.path
        isEnabled = root.enabled
        status = root.status
    }

    var statusText: String {
        switch status {
        case .active: "Authorized"
        case .disabled: "Disabled"
        case .permissionLost: "Permission lost"
        case .staleBookmark: "Authorization expired"
        case .degraded: "Monitoring interrupted"
        }
    }

    var needsReauthorization: Bool { status == .permissionLost || status == .staleBookmark }
}

struct ProviderState: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let health: ProviderHealth
    let pairs: [String]

    var isAvailable: Bool {
        if case .available = health { true } else { false }
    }

    var detail: String {
        switch health {
        case let .available(version): "Available · \(version)"
        case let .unavailable(reason): "Unavailable · \(reason)"
        }
    }
}

func formattedConversionDuration(_ duration: TimeInterval) -> String {
    let nonnegativeDuration = max(0, duration)
    if nonnegativeDuration < 1 {
        let milliseconds = min(999, Int((nonnegativeDuration * 1_000).rounded()))
        return "\(milliseconds)ms"
    }
    let totalSeconds = Int(nonnegativeDuration.rounded())
    if totalSeconds < 60 {
        return "\(totalSeconds)s"
    }
    if totalSeconds < 3_600 {
        return "\(totalSeconds / 60)m \(totalSeconds % 60)s"
    }
    return "\(totalSeconds / 3_600)h \((totalSeconds % 3_600) / 60)m"
}

struct HistoryItemState: Identifiable, Sendable {
    enum Availability: Hashable, Sendable {
        case available
        case unavailable
        case undoConflict(currentURL: URL)
    }

    enum RecoveryArtifactAvailability: Hashable, Sendable {
        case available
        case unavailable
    }

    enum RecoveryState: Hashable, Sendable {
        case notApplicable
        case unresolved(artifact: RecoveryArtifactAvailability)
        case resolvedByRestore(filename: String, date: Date)
        case resolvedManually(date: Date)
    }
    struct TrackChoiceOption: Equatable, Sendable {
        let index: Int
        let label: String
    }

    enum RequiredChoice: Equatable, Sendable {
        case transparencyBackground
        case mediaTracks(audio: [TrackChoiceOption], subtitles: [TrackChoiceOption])
    }

    let id: UUID
    let rootID: UUID
    let fileName: String
    let sourceFormat: String
    let targetFormat: String
    let outcome: PersistentJobState
    let conversionBehavior: ConversionBehavior
    let date: Date
    var conversionDuration: TimeInterval? = nil
    let providerName: String?
    let providerVersion: String?
    let fidelityWarning: String?
    let errorSummary: String?
    var requiredChoice: RequiredChoice? = nil
    var availability: Availability
    var recoveryState: RecoveryState = .notApplicable
    var recoverySuggestedDirectory: URL? = nil
    var recoveryOriginalFilename: String? = nil

    var conversionDurationText: String? {
        conversionDuration.map(formattedConversionDuration)
    }

    var outcomeText: String {
        switch recoveryState {
        case let .resolvedByRestore(filename, _):
            "Recovered as \(filename)"
        case .resolvedManually:
            "Resolved manually"
        case .unresolved(artifact: .unavailable):
            "Recovery data unavailable"
        case .unresolved(artifact: .available):
            "Recovery required"
        case .notApplicable:
            switch outcome {
            case .succeeded: "Converted"
            case .failed: "Failed"
            case .cancelled: "Cancelled"
            case .skipped: "Skipped"
            case .needsRecovery: "Recovery required"
            default: "In progress"
            }
        }
    }

    var canUndo: Bool { outcome == .succeeded && availability == .available }

    var behaviorText: String {
        switch conversionBehavior {
        case .keepOriginal: "Kept original and created copy"
        case .replaceWithBackup: "Replaced file with retained backup"
        }
    }

    var needsRecoveryAction: Bool {
        if case .unresolved = recoveryState { true } else { false }
    }

    var canRestoreRetainedFile: Bool {
        recoveryState == .unresolved(artifact: .available)
    }

    var showsSuccessMark: Bool {
        if outcome == .succeeded { return true }
        return switch recoveryState {
        case .resolvedByRestore, .resolvedManually: true
        default: false
        }
    }
}

struct BackupState: Hashable, Sendable {
    var usedBytes: UInt64 = 0
    var limitBytes: UInt64 = 10 << 30

    var retentionDays: Int = 30

    var usageText: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return "\(formatter.string(fromByteCount: Int64(usedBytes))) of \(formatter.string(fromByteCount: Int64(limitBytes)))"
    }
}

struct ImageDefaults: Codable, Hashable, Sendable {
    var quality = 0.9
    var frames: ImageFrameChoice = .ask
    var alphaBackgroundARGB: UInt32? = nil
    var metadata: MetadataMode = .preserve
    var orientation: ImageOrientationMode = .normalizePixels
    var colorProfile: ImageColorProfileMode = .preserve

    var policy: ConversionPolicy {
        .image(
            quality: quality,
            alphaBackgroundARGB: alphaBackgroundARGB,
            frames: frames.policy,
            metadata: metadata,
            orientation: orientation,
            colorProfile: colorProfile
        )
    }
}

enum ImageFrameChoice: String, CaseIterable, Codable, Sendable {
    case ask
    case first
    case all

    var policy: ImageFramePolicy {
        switch self {
        case .ask: .requireSingle
        case .first: .first
        case .all: .all
        }
    }
}

struct AudioDefaults: Codable, Hashable, Sendable {
    var bitrate: Int? = nil
    var sampleRate: Int? = nil
    var trackIndex: Int? = nil
    var policy: ConversionPolicy { .audio(bitrate: bitrate, sampleRate: sampleRate, trackIndex: trackIndex) }
}

struct VideoDefaults: Codable, Hashable, Sendable {
    var quality = 20
    var audioTrack: Int? = nil
    var subtitleTrack: Int? = nil
    var policy: ConversionPolicy { .video(quality: quality, audioTrack: audioTrack, subtitleTrack: subtitleTrack) }
}

struct DocumentDefaults: Codable, Hashable, Sendable {
    var acceptsFidelityLoss = false
    var pageIndex: Int? = nil
    var imageQuality = 0.92
    var policy: ConversionPolicy { .document(acceptsFidelityLoss: acceptsFidelityLoss, pageIndex: pageIndex, imageQuality: imageQuality) }
}

struct SpreadsheetDefaults: Codable, Hashable, Sendable {
    var sheetIndex: Int? = nil
    var delimiter = ","
    var formulaValuesOnly = false
    var policy: ConversionPolicy { .spreadsheet(sheetIndex: sheetIndex, delimiter: delimiter, formulaValuesOnly: formulaValuesOnly) }
}

struct FutureJobDefaults: Codable, Hashable, Sendable {
    var image = ImageDefaults()
    var audio = AudioDefaults()
    var video = VideoDefaults()
    var document = DocumentDefaults()
    var spreadsheet = SpreadsheetDefaults()
    var conversionBehavior: ConversionBehavior = .keepOriginal

    private enum CodingKeys: String, CodingKey {
        case image
        case audio
        case video
        case document
        case spreadsheet
        case conversionBehavior
    }
    init(
        image: ImageDefaults = ImageDefaults(),
        audio: AudioDefaults = AudioDefaults(),
        video: VideoDefaults = VideoDefaults(),
        document: DocumentDefaults = DocumentDefaults(),
        spreadsheet: SpreadsheetDefaults = SpreadsheetDefaults(),
        conversionBehavior: ConversionBehavior = .keepOriginal
    ) {
        self.image = image
        self.audio = audio
        self.video = video
        self.document = document
        self.spreadsheet = spreadsheet
        self.conversionBehavior = conversionBehavior
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        image = try container.decode(ImageDefaults.self, forKey: .image)
        audio = try container.decode(AudioDefaults.self, forKey: .audio)
        video = try container.decode(VideoDefaults.self, forKey: .video)
        document = try container.decode(DocumentDefaults.self, forKey: .document)
        spreadsheet = try container.decode(SpreadsheetDefaults.self, forKey: .spreadsheet)
        let rawBehavior = try? container.decodeIfPresent(String.self, forKey: .conversionBehavior)
        conversionBehavior = rawBehavior.flatMap(ConversionBehavior.init(rawValue:)) ?? .keepOriginal
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(image, forKey: .image)
        try container.encode(audio, forKey: .audio)
        try container.encode(video, forKey: .video)
        try container.encode(document, forKey: .document)
        try container.encode(spreadsheet, forKey: .spreadsheet)
        try container.encode(conversionBehavior.rawValue, forKey: .conversionBehavior)
    }
}

struct FutureJobDefaultsSnapshot: Sendable {
    let image: ImageDefaults
    let audio: AudioDefaults
    let video: VideoDefaults
    let document: DocumentDefaults
    let spreadsheet: SpreadsheetDefaults
    let conversionBehavior: ConversionBehavior

    init(_ defaults: FutureJobDefaults) {
        image = defaults.image
        audio = defaults.audio
        video = defaults.video
        document = defaults.document
        spreadsheet = defaults.spreadsheet
        conversionBehavior = defaults.conversionBehavior
    }
}

struct AppViewState: Sendable {
    var status: MenuBarState = .idle
    var statusDetail = "Authorize a folder to begin monitoring."
    var isMonitoringPaused = false
    var folders: [WatchedFolderState] = []
    var providers: [ProviderState] = []
    var history: [HistoryItemState] = []
    var selectedHistoryID: UUID?
    var backup = BackupState()
    var launchAtLogin = false
    var launchAtLoginRequiresApproval = false
    var defaults = FutureJobDefaults()
    var isLoading = true

    var recentActivity: [HistoryItemState] { Array(history.prefix(5)) }
}
