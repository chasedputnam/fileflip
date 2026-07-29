import Foundation

public enum JobTerminalState: String, Codable, Sendable { case skipped, failed, cancelled, succeeded }

public struct DiscoveredJob: Sendable {
    public let id: UUID
    public let fileKey: FileKey
    public let sourceURL: URL
    public let targetExtension: String
    public let conversionBehavior: ConversionBehavior

    public init(id: UUID = UUID(), fileKey: FileKey, sourceURL: URL, targetExtension: String, conversionBehavior: ConversionBehavior) {
        self.id = id
        self.fileKey = fileKey
        self.sourceURL = sourceURL
        self.targetExtension = targetExtension.lowercased()
        self.conversionBehavior = conversionBehavior
    }

    public func stabilizing() -> StabilizingJob { StabilizingJob(self) }
}

public struct StabilizingJob: Sendable {
    fileprivate let discovered: DiscoveredJob
    fileprivate init(_ discovered: DiscoveredJob) { self.discovered = discovered }
    public var conversionBehavior: ConversionBehavior { discovered.conversionBehavior }
    public func staged(snapshot: Snapshot) -> StagedJob { StagedJob(discovered: discovered, snapshot: snapshot) }
}

public struct StagedJob: Sendable {
    fileprivate let discovered: DiscoveredJob
    public let snapshot: Snapshot
    fileprivate init(discovered: DiscoveredJob, snapshot: Snapshot) { self.discovered = discovered; self.snapshot = snapshot }
    public var conversionBehavior: ConversionBehavior { discovered.conversionBehavior }
    public func backedUp(_ backup: BackupArtifact) -> BackedUpJob { BackedUpJob(discovered: discovered, snapshot: snapshot, backup: backup) }
}

public struct BackupArtifact: Sendable {
    public let url: URL
    public let sha256: Data
    public init(url: URL, sha256: Data) { self.url = url; self.sha256 = sha256 }
}

public struct BackedUpJob: Sendable {
    fileprivate let discovered: DiscoveredJob
    public let snapshot: Snapshot
    public let backup: BackupArtifact
    fileprivate init(discovered: DiscoveredJob, snapshot: Snapshot, backup: BackupArtifact) { self.discovered = discovered; self.snapshot = snapshot; self.backup = backup }
    public var conversionBehavior: ConversionBehavior { discovered.conversionBehavior }
    public func converting() -> ConvertingJob { ConvertingJob(discovered: discovered, snapshot: snapshot, backup: backup) }
}

public struct ConvertingJob: Sendable {
    fileprivate let discovered: DiscoveredJob
    public let snapshot: Snapshot
    public let backup: BackupArtifact
    fileprivate init(discovered: DiscoveredJob, snapshot: Snapshot, backup: BackupArtifact) { self.discovered = discovered; self.snapshot = snapshot; self.backup = backup }
    public var conversionBehavior: ConversionBehavior { discovered.conversionBehavior }
    public func validating(_ artifact: ProducedArtifact) -> ValidatingJob { ValidatingJob(discovered: discovered, snapshot: snapshot, backup: backup, artifact: artifact) }
}

public struct ValidatingJob: Sendable {
    fileprivate let discovered: DiscoveredJob
    public let snapshot: Snapshot
    public let backup: BackupArtifact
    public let artifact: ProducedArtifact
    fileprivate init(discovered: DiscoveredJob, snapshot: Snapshot, backup: BackupArtifact, artifact: ProducedArtifact) { self.discovered = discovered; self.snapshot = snapshot; self.backup = backup; self.artifact = artifact }
    public var conversionBehavior: ConversionBehavior { discovered.conversionBehavior }

    public func validated(outputHash: Data, format: DetectedFormat) -> ReadyToCommitJob {
        ReadyToCommitJob(discovered: discovered, snapshot: snapshot, backup: backup, artifact: ValidatedArtifact(url: artifact.url, sha256: outputHash, format: format))
    }
}

public struct ValidatedArtifact: Sendable {
    public let url: URL
    public let sha256: Data
    public let format: DetectedFormat
    fileprivate init(url: URL, sha256: Data, format: DetectedFormat) { self.url = url; self.sha256 = sha256; self.format = format }
}

public struct ReadyToCommitJob: Sendable {
    fileprivate let discovered: DiscoveredJob
    public let snapshot: Snapshot
    public let backup: BackupArtifact
    public let artifact: ValidatedArtifact
    fileprivate init(discovered: DiscoveredJob, snapshot: Snapshot, backup: BackupArtifact, artifact: ValidatedArtifact) { self.discovered = discovered; self.snapshot = snapshot; self.backup = backup; self.artifact = artifact }
    public var conversionBehavior: ConversionBehavior { discovered.conversionBehavior }

    public var id: UUID { discovered.id }
    public var sourceURL: URL { discovered.sourceURL }
    public var targetExtension: String { discovered.targetExtension }
}
