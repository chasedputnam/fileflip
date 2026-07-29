import CryptoKit
import Darwin
import Foundation

public enum TransactionFailpoint: String, CaseIterable, Sendable {
    // Replace-mode failpoints retain their established meanings.
    case afterJournalDiscovery, afterStage, afterStageJournal, afterBackup, afterBackupJournal
    case afterConversion, afterValidation, afterValidationJournal, afterSiblingCopy, afterSiblingFlush
    case beforeReplace, afterReplace, afterCommitJournal
    // Copy-mode failpoints name each preparation, durable-state, and publication boundary.
    case beforeCopyPublication, afterOriginalSiblingCopy, afterOriginalSiblingHash, afterOriginalSiblingFlush
    case afterOutputSiblingCopy, afterOutputSiblingHash, afterOutputSiblingFlush
    case afterPublishingOriginalJournal, afterOriginalPublish, afterOriginalParentFlush
    case afterPublishingConvertedJournal, beforeCopyOutputPublish, afterCopyOutputPublish
    case afterCopyOutputParentFlush, afterCopyCommitJournal
}

public struct FileMetadata: Codable, Hashable, Sendable {
    public let permissions: UInt16
    public let creationDate: Date?
    public let modificationDate: Date?

    public init(permissions: UInt16, creationDate: Date?, modificationDate: Date?) {
        self.permissions = permissions
        self.creationDate = creationDate
        self.modificationDate = modificationDate
    }
}

public struct TransactionRequest: Sendable {
    public let id: UUID
    public let rootID: UUID
    public let rootURL: URL
    public let oldRelativePath: String
    public let newRelativePath: String
    public let sourceFormat: DetectedFormat
    public let targetFormat: DetectedFormat
    public let targetExtension: String
    public let providerID: ProviderID
    public let providerVersion: String
    public let policy: ConversionPolicy
    public let conversionBehavior: ConversionBehavior

    public init(id: UUID = UUID(), rootID: UUID, rootURL: URL, oldRelativePath: String, newRelativePath: String, sourceFormat: DetectedFormat, targetFormat: DetectedFormat, targetExtension: String, providerID: ProviderID, providerVersion: String, policy: ConversionPolicy, conversionBehavior: ConversionBehavior) {
        self.id = id; self.rootID = rootID; self.rootURL = rootURL; self.oldRelativePath = oldRelativePath
        self.newRelativePath = newRelativePath; self.sourceFormat = sourceFormat; self.targetFormat = targetFormat
        self.targetExtension = targetExtension.lowercased(); self.providerID = providerID; self.providerVersion = providerVersion; self.policy = policy
        self.conversionBehavior = conversionBehavior
    }
}

public struct CommittedTransaction: Sendable {
    public let jobID: UUID
    public let targetURL: URL
    public let sourceHash: Data
    public let outputHash: Data
    public let conversionBehavior: ConversionBehavior
}

public typealias ArtifactProducer = @Sendable (_ stagedSource: URL, _ outputDirectory: URL) async throws -> ProducedArtifact
public typealias ArtifactValidator = @Sendable (_ produced: ProducedArtifact, _ expected: DetectedFormat) async throws -> (hash: Data, format: DetectedFormat)
public typealias FailpointHandler = @Sendable (TransactionFailpoint) throws -> Void

public actor TransactionCoordinator {
    private let journal: JournalStore
    private let storageRoot: URL
    private let fileManager: FileManager
    private let failpoint: FailpointHandler
    private let filesystemProbe: any FileSystemContractProbing
    private var retentionDays: Int
    private var backupByteLimit: UInt64

    public init(journal: JournalStore, storageRoot: URL, retentionDays: Int = 30, backupByteLimit: UInt64 = 10 << 30, fileManager: FileManager = .default, filesystemProbe: any FileSystemContractProbing = FileSystemContractProbe(), failpoint: @escaping FailpointHandler = { _ in }) throws {
        self.journal = journal
        self.storageRoot = storageRoot
        self.fileManager = fileManager
        self.filesystemProbe = filesystemProbe
        self.failpoint = failpoint
        self.retentionDays = min(max(retentionDays, 1), 365)
        self.backupByteLimit = max(backupByteLimit, 1)
        try fileManager.createDirectory(at: storageRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: storageRoot.path)
    }
    public func configureRetention(days: Int, byteLimit: UInt64) async throws {
        retentionDays = min(max(days, 1), 365)
        backupByteLimit = max(byteLimit, 1)
        try await journal.updateBackupExpirations(retentionDays: retentionDays)
        try await pruneBackups()
    }


    public func execute(_ request: TransactionRequest, produce: ArtifactProducer, validate: ArtifactValidator) async throws -> CommittedTransaction {
        let target = try BoundaryGuards.canonicalRegularFile(root: request.rootURL, relativePath: request.newRelativePath)
        try filesystemProbe.verify(directory: target.deletingLastPathComponent())
        let initial = try FileFacts.read(target)
        let policyJSON = try BoundaryGuards.strictPolicyData(request.policy)
        let now = Date()
        let job = JournalJob(
            id: request.id, rootID: request.rootID, fileKey: initial.fileKey,
            oldRelativePath: request.oldRelativePath, newRelativePath: request.newRelativePath,
            sourceFormat: String(describing: request.sourceFormat), targetFormat: String(describing: request.targetFormat),
            providerID: request.providerID.rawValue, providerVersion: request.providerVersion, policyJSON: policyJSON,
            sourceHash: nil, outputHash: nil, state: .discovered, conversionBehavior: request.conversionBehavior,
            createdAt: now, updatedAt: now, errorCode: nil, errorDetail: nil
        )
        try await journal.insert(job)
        try failpoint(.afterJournalDiscovery)

        do {
            try await journal.transition(jobID: request.id, from: [.discovered], to: .stabilizing)
            let stable = try await FileFacts.waitUntilStable(target, expected: initial)
            let jobDirectory = storageRoot.appending(path: request.id.uuidString, directoryHint: .isDirectory)
            let stagingDirectory = jobDirectory.appending(path: "staging", directoryHint: .isDirectory)
            let outputDirectory = jobDirectory.appending(path: "output", directoryHint: .isDirectory)
            var directories = [jobDirectory, stagingDirectory, outputDirectory]
            if request.conversionBehavior == .replaceWithBackup {
                directories.append(jobDirectory.appending(path: "backup", directoryHint: .isDirectory))
            }
            for directory in directories {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }

            try Self.preflightSpace(at: target, sourceBytes: stable.byteCount)
            let staged = stagingDirectory.appending(path: "source")
            try Self.cloneOrCopy(from: target, to: staged)
            let sourceHash = try Self.sha256(staged)
            guard try Self.sha256(target) == sourceHash, try FileFacts.read(target).identity == stable.identity else { throw FileConvertError.sourceChanged }
            try failpoint(.afterStage)
            try await journal.transition(jobID: request.id, from: [.stabilizing], to: .staged, sourceHash: sourceHash)
            try failpoint(.afterStageJournal)

            let metadata = try Self.metadata(target)
            let conversionStart: PersistentJobState
            if request.conversionBehavior == .replaceWithBackup {
                let backupURL = jobDirectory.appending(path: "backup/source")
                try Self.cloneOrCopy(from: staged, to: backupURL)
                try Self.flushFileAndParent(backupURL)
                guard try Self.sha256(backupURL) == sourceHash else { throw FileConvertError.validationFailed("Backup hash mismatch") }
                try failpoint(.afterBackup)
                let backup = BackupRecord(
                    jobID: request.id, relativeStoragePath: "\(request.id.uuidString)/backup/source",
                    byteCount: stable.byteCount, sha256: sourceHash, metadata: try JSONEncoder().encode(metadata),
                    expiresAt: Calendar(identifier: .gregorian).date(byAdding: .day, value: retentionDays, to: now)!
                )
                try await journal.insertBackup(backup)
                try await journal.transition(jobID: request.id, from: [.staged], to: .backedUp)
                try failpoint(.afterBackupJournal)
                conversionStart = .backedUp
            } else {
                conversionStart = .staged
            }

            try await journal.transition(jobID: request.id, from: [conversionStart], to: .converting)
            let rawProduced = try await produce(staged, outputDirectory)
            guard rawProduced.providerID == request.providerID else { throw FileConvertError.validationFailed("Provider identity mismatch") }
            let produced = ProducedArtifact(url: try BoundaryGuards.canonicalRegularFile(root: outputDirectory, candidate: rawProduced.url), providerID: rawProduced.providerID)
            try failpoint(.afterConversion)
            try await journal.transition(jobID: request.id, from: [.converting], to: .validating)
            let validation = try await validate(produced, request.targetFormat)
            guard validation.format == request.targetFormat else { throw FileConvertError.validationFailed("Target type mismatch") }
            try failpoint(.afterValidation)
            try await journal.transition(jobID: request.id, from: [.validating], to: .readyToCommit, outputHash: validation.hash)
            try failpoint(.afterValidationJournal)

            switch request.conversionBehavior {
            case .replaceWithBackup:
                try await publishReplacement(
                    request: request, target: target, stable: stable, sourceHash: sourceHash,
                    produced: produced, outputHash: validation.hash, metadata: metadata
                )
                try? await pruneBackups()
            case .keepOriginal:
                try await publishCopy(
                    request: request, target: target, stable: stable, staged: staged, sourceHash: sourceHash,
                    produced: produced, outputHash: validation.hash, metadata: metadata
                )
            }
            return CommittedTransaction(jobID: request.id, targetURL: target, sourceHash: sourceHash, outputHash: validation.hash, conversionBehavior: request.conversionBehavior)
        } catch {
            if let current = try? await journal.job(id: request.id),
               !current.state.isTerminal,
               ![.publishingOriginal, .publishingConverted].contains(current.state) {
                let sourceStillAtTarget = current.state != .committing || current.sourceHash.map {
                    (try? Self.sha256(target)) == $0
                } == true
                if sourceStillAtTarget {
                    let finalState: PersistentJobState = error is CancellationError ? .cancelled : .failed
                    do {
                        try Self.restoreOriginalName(request: request, target: target, job: current)
                        try await journal.transition(
                            jobID: request.id,
                            from: [current.state],
                            to: finalState,
                            errorCode: Self.stableErrorCode(error),
                            errorDetail: BoundaryGuards.redact(String(describing: error))
                        )
                    } catch {
                        try? await journal.transition(
                            jobID: request.id,
                            from: [current.state],
                            to: .needsRecovery,
                            errorCode: "filenameRollbackFailed",
                            errorDetail: "The original filename could not be restored safely"
                        )
                    }
                }
            }
            if request.conversionBehavior == .replaceWithBackup { try? await pruneBackups() }
            throw error
        }
    }
    private func publishReplacement(
        request: TransactionRequest,
        target: URL,
        stable: FileFacts,
        sourceHash: Data,
        produced: ProducedArtifact,
        outputHash: Data,
        metadata: FileMetadata
    ) async throws {
        let current = try FileFacts.read(target)
        guard current.identity == stable.identity, try Self.sha256(target) == sourceHash else { throw FileConvertError.sourceChanged }
        let sibling = target.deletingLastPathComponent().appending(path: ".fileconvert-\(request.id.uuidString).tmp")
        try? fileManager.removeItem(at: sibling)
        try fileManager.copyItem(at: produced.url, to: sibling)
        try Self.apply(metadata, to: sibling)
        guard try Self.sha256(sibling) == outputHash else { throw FileConvertError.validationFailed("Sibling hash mismatch") }
        try failpoint(.afterSiblingCopy)
        try Self.flushFileAndParent(sibling)
        try failpoint(.afterSiblingFlush)
        try await journal.transition(jobID: request.id, from: [.readyToCommit], to: .committing)
        try failpoint(.beforeReplace)
        guard rename(sibling.path, target.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        try Self.flushDirectory(target.deletingLastPathComponent())
        try failpoint(.afterReplace)
        try await journal.transition(jobID: request.id, from: [.committing], to: .succeeded)
        try failpoint(.afterCommitJournal)
    }

    private func publishCopy(
        request: TransactionRequest,
        target: URL,
        stable: FileFacts,
        staged: URL,
        sourceHash: Data,
        produced: ProducedArtifact,
        outputHash: Data,
        metadata: FileMetadata
    ) async throws {
        try failpoint(.beforeCopyPublication)
        let original = try Self.copyOriginalDestination(root: request.rootURL, relativePath: request.oldRelativePath, target: target)
        try Self.requireAbsent(original)
        let originalSibling = original.deletingLastPathComponent().appending(path: ".fileconvert-\(request.id.uuidString)-original.tmp")
        let outputSibling = target.deletingLastPathComponent().appending(path: ".fileconvert-\(request.id.uuidString)-output.tmp")
        try Self.requireAbsent(originalSibling)
        try Self.requireAbsent(outputSibling)
        try Self.requireSourceAtTarget(target, stable: stable, sourceHash: sourceHash)

        try Self.cloneOrCopy(from: staged, to: originalSibling)
        try Self.apply(metadata, to: originalSibling)
        try failpoint(.afterOriginalSiblingCopy)
        guard try Self.sha256(originalSibling) == sourceHash else { throw FileConvertError.validationFailed("Original sibling hash mismatch") }
        try failpoint(.afterOriginalSiblingHash)
        try Self.flushFileAndParent(originalSibling)
        try failpoint(.afterOriginalSiblingFlush)

        try fileManager.copyItem(at: produced.url, to: outputSibling)
        try Self.apply(metadata, to: outputSibling)
        try failpoint(.afterOutputSiblingCopy)
        guard try Self.sha256(outputSibling) == outputHash else { throw FileConvertError.validationFailed("Output sibling hash mismatch") }
        try failpoint(.afterOutputSiblingHash)
        try Self.flushFileAndParent(outputSibling)
        try failpoint(.afterOutputSiblingFlush)

        try Self.requireSourceAtTarget(target, stable: stable, sourceHash: sourceHash)
        try Self.requireAbsent(original)
        try await journal.transition(jobID: request.id, from: [.readyToCommit], to: .publishingOriginal)
        try failpoint(.afterPublishingOriginalJournal)
        do {
            try Self.renameExclusively(from: originalSibling, to: original)
        } catch FileConvertError.destinationExists {
            try await journal.transition(jobID: request.id, from: [.publishingOriginal], to: .failed, errorCode: "destinationExists", errorDetail: "Original destination became occupied")
            throw FileConvertError.destinationExists
        }
        try failpoint(.afterOriginalPublish)
        try Self.flushDirectory(original.deletingLastPathComponent())
        try failpoint(.afterOriginalParentFlush)

        try await journal.transition(jobID: request.id, from: [.publishingOriginal], to: .publishingConverted)
        try failpoint(.afterPublishingConvertedJournal)
        guard try Self.sha256(original) == sourceHash else { throw FileConvertError.validationFailed("Published original hash mismatch") }
        try Self.requireSourceAtTarget(target, stable: stable, sourceHash: sourceHash)
        try failpoint(.beforeCopyOutputPublish)
        guard rename(outputSibling.path, target.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        try failpoint(.afterCopyOutputPublish)
        try Self.flushDirectory(target.deletingLastPathComponent())
        try failpoint(.afterCopyOutputParentFlush)
        try await journal.transition(jobID: request.id, from: [.publishingConverted], to: .succeeded)
        try failpoint(.afterCopyCommitJournal)
    }

    private static func copyOriginalDestination(root: URL, relativePath: String, target: URL) throws -> URL {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.split(separator: "/").contains(where: { $0 == "." || $0 == ".." || $0.isEmpty }) else {
            throw FileConvertError.validationFailed("Invalid original path")
        }
        guard let rootPointer = realpath(root.path, nil) else { throw FileConvertError.permissionDenied }
        defer { free(rootPointer) }
        let canonicalRoot = URL(fileURLWithPath: String(cString: rootPointer), isDirectory: true)
        let lexicalOriginal = canonicalRoot.appending(path: relativePath)
        let lexicalParent = lexicalOriginal.deletingLastPathComponent()
        guard let parentPointer = realpath(lexicalParent.path, nil) else { throw FileConvertError.permissionDenied }
        defer { free(parentPointer) }
        let parent = URL(fileURLWithPath: String(cString: parentPointer), isDirectory: true)
        let rootParts = canonicalRoot.standardizedFileURL.pathComponents
        let parentParts = parent.standardizedFileURL.pathComponents
        guard parentParts.count >= rootParts.count,
              parentParts.prefix(rootParts.count).elementsEqual(rootParts),
              lexicalParent.standardizedFileURL.path == parent.standardizedFileURL.path else {
            throw FileConvertError.validationFailed("Original parent is unsafe")
        }
        guard try Self.device(of: parent) == FileFacts.read(target).device else {
            throw FileConvertError.validationFailed("Original destination changed volumes")
        }
        return parent.appendingPathComponent(lexicalOriginal.lastPathComponent)
    }

    private static func restoreOriginalName(request: TransactionRequest, target: URL, job: JournalJob) throws {
        let original = try copyOriginalDestination(root: request.rootURL, relativePath: request.oldRelativePath, target: target)
        guard original != target, try FileFacts.read(target).fileKey == job.fileKey else {
            throw FileConvertError.sourceChanged
        }
        if let sourceHash = job.sourceHash {
            guard try sha256(target) == sourceHash else { throw FileConvertError.sourceChanged }
        }
        try renameExclusively(from: target, to: original)
        try flushDirectory(original.deletingLastPathComponent())
    }

    private static func requireSourceAtTarget(_ target: URL, stable: FileFacts, sourceHash: Data) throws {
        guard try FileFacts.read(target).identity == stable.identity, try sha256(target) == sourceHash else {
            throw FileConvertError.sourceChanged
        }
    }

    private static func requireAbsent(_ url: URL) throws {
        var status = stat()
        if lstat(url.path, &status) == 0 { throw FileConvertError.destinationExists }
        guard errno == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private static func device(of url: URL) throws -> UInt64 {
        var status = stat()
        guard stat(url.path, &status) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return UInt64(status.st_dev)
    }

    private static func renameExclusively(from source: URL, to destination: URL) throws {
        let result = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                renameatx_np(AT_FDCWD, sourcePath, AT_FDCWD, destinationPath, UInt32(RENAME_EXCL))
            }
        }
        guard result == 0 else {
            if errno == EEXIST { throw FileConvertError.destinationExists }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
    private func pruneBackups(now: Date = Date()) async throws {
        for backup in try await journal.prunableBackups(now: now, byteLimit: backupByteLimit) {
            try? fileManager.removeItem(at: storageRoot.appending(path: backup.relativeStoragePath))
            try await journal.removeBackup(jobID: backup.jobID)
        }
    }

    private static func stableErrorCode(_ error: any Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let error = error as? FileConvertError {
            switch error {
            case .anotherInstanceIsRunning: return "anotherInstanceIsRunning"
            case .unsupportedPair: return "unsupportedPair"
            case .providerUnavailable: return "providerUnavailable"
            case .invalidStateTransition: return "invalidStateTransition"
            case .validationFailed: return "validationFailed"
            case .requiresChoice: return "requiresChoice"
            case .sourceChanged: return "sourceChanged"
            case .destinationExists: return "destinationExists"
            case .insufficientDiskSpace: return "insufficientDiskSpace"
            case .permissionDenied: return "permissionDenied"
            case .timedOut: return "timedOut"
            case .cancelled: return "cancelled"
            }
        }
        if let error = error as? POSIXError {
            switch error.code {
            case .EACCES, .EPERM: return "permissionDenied"
            case .ENOSPC, .EDQUOT: return "insufficientDiskSpace"
            default: break
            }
        }
        return "conversionFailed"
    }


    private static func preflightSpace(at target: URL, sourceBytes: UInt64) throws {
        let values = try target.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let outputCap = max(sourceBytes.multipliedReportingOverflow(by: 2).overflow ? UInt64.max : sourceBytes * 2, sourceBytes.addingReportingOverflow(1 << 30).overflow ? UInt64.max : sourceBytes + (1 << 30))
        let required = sourceBytes.addingReportingOverflow(outputCap).partialValue.addingReportingOverflow(256 << 20).partialValue
        guard let available = values.volumeAvailableCapacityForImportantUsage, available >= 0, UInt64(available) >= required else { throw FileConvertError.insufficientDiskSpace }
    }

    static func cloneOrCopy(from source: URL, to destination: URL) throws {
        let result = clonefile(source.path, destination.path, 0)
        if result != 0 {
            if errno != ENOTSUP && errno != EXDEV && errno != EINVAL { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            try FileManager.default.copyItem(at: source, to: destination)
        }
    }

    public static func sha256(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return Data(hasher.finalize())
    }

    private static func metadata(_ url: URL) throws -> FileMetadata {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return FileMetadata(permissions: UInt16((attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o600), creationDate: attributes[.creationDate] as? Date, modificationDate: attributes[.modificationDate] as? Date)
    }

    private static func apply(_ metadata: FileMetadata, to url: URL) throws {
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: NSNumber(value: metadata.permissions)]
        if let creationDate = metadata.creationDate { attributes[.creationDate] = creationDate }
        if let modificationDate = metadata.modificationDate { attributes[.modificationDate] = modificationDate }
        try FileManager.default.setAttributes(attributes, ofItemAtPath: url.path)
    }

    private static func flushFileAndParent(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        try flushDirectory(url.deletingLastPathComponent())
    }

    private static func flushDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}

struct FileFacts: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let byteCount: UInt64
    let modificationDate: Date

    var identity: String { "\(device):\(inode):\(byteCount):\(modificationDate.timeIntervalSince1970)" }
    var fileKey: String { "\(device):\(inode)" }

    static func read(_ url: URL) throws -> FileFacts {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.type] as? FileAttributeType) == .typeRegular else { throw FileConvertError.validationFailed("Not a regular file") }
        return FileFacts(device: (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0, inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0, byteCount: (attributes[.size] as? NSNumber)?.uint64Value ?? 0, modificationDate: attributes[.modificationDate] as? Date ?? .distantPast)
    }

    static func waitUntilStable(_ url: URL, expected: FileFacts, interval: Duration = .milliseconds(500), timeout: Duration = .seconds(30)) async throws -> FileFacts {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var prior = expected
        while clock.now < deadline {
            try await clock.sleep(for: interval)
            let current = try read(url)
            if current == prior { return current }
            prior = current
        }
        throw FileConvertError.timedOut
    }
}
