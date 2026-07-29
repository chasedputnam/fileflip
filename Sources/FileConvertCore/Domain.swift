import Foundation

public struct FileKey: Hashable, Codable, Sendable {
    public let volumeUUID: UUID
    public let fileID: UInt64

    public init(volumeUUID: UUID, fileID: UInt64) {
        self.volumeUUID = volumeUUID
        self.fileID = fileID
    }
}

public enum ImageFormat: String, CaseIterable, Codable, Sendable { case jpeg, png, heic, tiff, webP }
public enum AudioFormat: String, CaseIterable, Codable, Sendable { case mp3, m4a, aac, wav, aiff, flac, ogg, opus }
public enum VideoFormat: String, CaseIterable, Codable, Sendable { case mp4, m4v, mov, mkv, webM }
public enum DocumentFormat: String, CaseIterable, Codable, Sendable { case pdf, docx, odt, rtf, text, markdown, html }
public enum SpreadsheetFormat: String, CaseIterable, Codable, Sendable { case xlsx, ods, csv }
public enum ConversionBehavior: String, Codable, CaseIterable, Sendable {
    case keepOriginal
    case replaceWithBackup
}

public enum DetectedFormat: Hashable, Codable, Sendable {
    case image(ImageFormat)
    case audio(AudioFormat)
    case video(VideoFormat)
    case document(DocumentFormat)
    case spreadsheet(SpreadsheetFormat)
}

public struct ProviderID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public enum ProviderHealth: Hashable, Codable, Sendable {
    case available(version: String)
    case unavailable(reason: String)
}

public enum LossProfile: String, Codable, Sendable { case lossless, potentiallyLossy, requiresChoice }

public enum MetadataMode: String, Codable, Sendable { case preserve, strip }
public enum ImageOrientationMode: String, Codable, Sendable { case normalizePixels, preserveTag }
public enum ImageColorProfileMode: String, Codable, Sendable { case preserve, convertToSRGB, strip }
public enum ImageFramePolicy: Hashable, Codable, Sendable {
    case requireSingle
    case first
    case index(Int)
    case all
}

public enum ConversionPolicy: Hashable, Codable, Sendable {
    case image(
        version: UInt = 1,
        quality: Double = 0.9,
        alphaBackgroundARGB: UInt32? = nil,
        frames: ImageFramePolicy = .requireSingle,
        metadata: MetadataMode = .preserve,
        orientation: ImageOrientationMode = .normalizePixels,
        colorProfile: ImageColorProfileMode = .preserve
    )
    case audio(version: UInt = 1, bitrate: Int? = nil, sampleRate: Int? = nil, trackIndex: Int? = nil)
    case video(version: UInt = 1, quality: Int = 20, audioTrack: Int? = nil, subtitleTrack: Int? = nil)
    case document(version: UInt = 1, acceptsFidelityLoss: Bool = false, pageIndex: Int? = nil, imageQuality: Double = 0.92)
    case spreadsheet(version: UInt = 1, sheetIndex: Int? = nil, delimiter: String = ",", formulaValuesOnly: Bool = false)
}

public extension ConversionPolicy {
    var version: UInt {
        switch self {
        case let .image(version, _, _, _, _, _, _), let .audio(version, _, _, _),
             let .video(version, _, _, _), let .document(version, _, _, _),
             let .spreadsheet(version, _, _, _):
            version
        }
    }
}

public struct ConversionCapability: Hashable, Codable, Sendable {
    public let source: DetectedFormat
    public let targetExtension: String
    public let providerID: ProviderID
    public let defaultPolicy: ConversionPolicy
    public let lossProfile: LossProfile

    public init(source: DetectedFormat, targetExtension: String, providerID: ProviderID, defaultPolicy: ConversionPolicy, lossProfile: LossProfile) {
        self.source = source
        self.targetExtension = targetExtension.lowercased()
        self.providerID = providerID
        self.defaultPolicy = defaultPolicy
        self.lossProfile = lossProfile
    }
}

public struct Snapshot: Sendable {
    public let url: URL
    public let fileKey: FileKey
    public let byteCount: UInt64
    public let modificationDate: Date

    public init(url: URL, fileKey: FileKey, byteCount: UInt64, modificationDate: Date) {
        self.url = url
        self.fileKey = fileKey
        self.byteCount = byteCount
        self.modificationDate = modificationDate
    }
}

public struct ConversionRequest: Sendable {
    public let jobID: UUID
    public let source: Snapshot
    public let targetExtension: String
    public let policy: ConversionPolicy
    public let outputDirectory: URL
    public let deadline: Date
    public let maximumOutputBytes: UInt64

    public init(
        jobID: UUID,
        source: Snapshot,
        targetExtension: String,
        policy: ConversionPolicy,
        outputDirectory: URL,
        deadline: Date,
        maximumOutputBytes: UInt64
    ) {
        self.jobID = jobID
        self.source = source
        self.targetExtension = targetExtension
        self.policy = policy
        self.outputDirectory = outputDirectory
        self.deadline = deadline
        self.maximumOutputBytes = maximumOutputBytes
    }
}

public struct ProducedArtifact: Sendable {
    public let url: URL
    public let providerID: ProviderID
    public init(url: URL, providerID: ProviderID) { self.url = url; self.providerID = providerID }
}

public protocol ConversionProvider: Sendable {
    var id: ProviderID { get }
    func health() async -> ProviderHealth
    func capabilities() async -> Set<ConversionCapability>
    func convert(_ request: ConversionRequest) async throws -> ProducedArtifact
}

public enum FileConvertError: Error, Hashable, Sendable {
    case anotherInstanceIsRunning
    case unsupportedPair
    case providerUnavailable(String)
    case invalidStateTransition
    case validationFailed(String)
    case requiresChoice
    case sourceChanged
    case destinationExists
    case insufficientDiskSpace
    case permissionDenied
    case timedOut
    case cancelled
}
