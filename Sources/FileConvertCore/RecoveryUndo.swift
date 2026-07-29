import Darwin
import Foundation

public enum UndoResult: Equatable, Sendable {
    case restored(URL)
    case conflict(currentURL: URL)
}

public enum RecoveryActionError: Error, Equatable, Sendable {
    case invalidRecovery
    case destinationExists
    case artifactUnavailable
    case integrityFailure
    case permissionDenied
    case publicationFailed
    case restoredButResolutionWriteFailed(filename: String)
    case resolutionWriteFailed
}

public enum RecoveryFailpoint: String, CaseIterable, Sendable {
    case afterStaging
    case beforeResolutionWrite
}

public typealias RecoveryFailpointHandler = @Sendable (RecoveryFailpoint) throws -> Void

public actor RecoveryCoordinator {
    private let journal: JournalStore
    private let storageRoot: URL
    private let fileManager: FileManager
    private let failpoint: RecoveryFailpointHandler

    public init(
        journal: JournalStore,
        storageRoot: URL,
        fileManager: FileManager = .default,
        failpoint: @escaping RecoveryFailpointHandler = { _ in }
    ) {
        self.journal = journal
        self.storageRoot = storageRoot
        self.fileManager = fileManager
        self.failpoint = failpoint
    }

    public func restoreRetainedFile(jobID: UUID, destination: URL) async throws -> URL {
        guard let job = try await journal.job(id: jobID),
              job.state == .needsRecovery,
              job.conversionBehavior == .replaceWithBackup,
              try await journal.recoveryResolution(jobID: jobID) == nil else {
            throw RecoveryActionError.invalidRecovery
        }
        guard let backup = try await journal.backup(jobID: jobID),
              let artifact = safeLeaf(root: storageRoot, relativePath: backup.relativeStoragePath) else {
            throw RecoveryActionError.artifactUnavailable
        }
        try validateArtifact(artifact, expectedHash: backup.sha256)
        try validateDestination(destination)
        try validateArtifact(artifact, expectedHash: backup.sha256)

        let temporary = destination.deletingLastPathComponent().appending(
            path: ".fileflip-recovery-\(jobID.uuidString)-\(UUID().uuidString).tmp"
        )
        var published = false
        defer {
            if !published {
                try? fileManager.removeItem(at: temporary)
            }
        }

        do {
            try TransactionCoordinator.cloneOrCopy(from: artifact, to: temporary)
            guard try TransactionCoordinator.sha256(temporary) == backup.sha256 else {
                throw RecoveryActionError.integrityFailure
            }
            let metadata = (try? JSONDecoder().decode(FileMetadata.self, from: backup.metadata))
                ?? FileMetadata(permissions: 0o600, creationDate: nil, modificationDate: nil)
            try apply(metadata, to: temporary)
            try flushFile(temporary)
            try failpoint(.afterStaging)
            try renameExclusively(from: temporary, to: destination)
            published = true
            try flushDirectory(destination.deletingLastPathComponent())
        } catch let error as RecoveryActionError {
            throw error
        } catch FileConvertError.destinationExists {
            throw RecoveryActionError.destinationExists
        } catch let error as POSIXError where Self.isPermissionError(error) {
            throw RecoveryActionError.permissionDenied
        } catch {
            throw RecoveryActionError.publicationFailed
        }

        do {
            try failpoint(.beforeResolutionWrite)
            try await journal.resolveRecovery(
                RecoveryResolutionRecord(
                    jobID: jobID,
                    method: .restored,
                    destinationFilename: destination.lastPathComponent,
                    resolvedAt: Date()
                )
            )
        } catch {
            throw RecoveryActionError.restoredButResolutionWriteFailed(filename: destination.lastPathComponent)
        }
        return destination
    }

    public func acknowledgeRecovery(jobID: UUID) async throws {
        guard let job = try await journal.job(id: jobID),
              job.state == .needsRecovery,
              job.conversionBehavior == .replaceWithBackup,
              try await journal.recoveryResolution(jobID: jobID) == nil else {
            throw RecoveryActionError.invalidRecovery
        }
        do {
            try await journal.resolveRecovery(
                RecoveryResolutionRecord(
                    jobID: jobID,
                    method: .acknowledged,
                    destinationFilename: nil,
                    resolvedAt: Date()
                )
            )
        } catch {
            throw RecoveryActionError.resolutionWriteFailed
        }
    }

    public func retainedArtifactIsAvailable(jobID: UUID) async -> Bool {
        do {
            guard let job = try await journal.job(id: jobID),
                  job.state == .needsRecovery,
                  job.conversionBehavior == .replaceWithBackup,
                  try await journal.recoveryResolution(jobID: jobID) == nil,
                  let backup = try await journal.backup(jobID: jobID),
                  let artifact = safeLeaf(root: storageRoot, relativePath: backup.relativeStoragePath) else {
                return false
            }
            try validateArtifact(artifact, expectedHash: backup.sha256)
            return true
        } catch {
            return false
        }
    }

    public func reconcile(roots: [UUID: URL]) async throws {
        for job in try await journal.nonterminalJobs() {
            guard let root = roots[job.rootID] else { continue }
            if job.conversionBehavior == .keepOriginal {
                try await reconcileCopy(job, root: root)
            } else {
                try await reconcileReplacement(job, root: root)
            }
        }
    }

    private func reconcileReplacement(_ job: JournalJob, root: URL) async throws {
        let live = root.appending(path: job.newRelativePath)
        let sibling = live.deletingLastPathComponent().appending(path: ".fileconvert-\(job.id.uuidString).tmp")
        switch job.state {
        case .committing:
            let liveHash = try? TransactionCoordinator.sha256(live)
            if liveHash == job.outputHash {
                try await journal.transition(jobID: job.id, from: [.committing], to: .succeeded)
            } else if liveHash == job.sourceHash {
                try? fileManager.removeItem(at: sibling)
                try await journal.transition(jobID: job.id, from: [.committing], to: .failed, errorCode: "recoveredBeforeReplace", errorDetail: "Original bytes remain at the user-visible path")
            } else {
                try await markNeedsRecovery(job, code: "ambiguousCommit")
            }
        case .needsRecovery:
            return
        default:
            let directory = storageRoot.appending(path: job.id.uuidString)
            try? fileManager.removeItem(at: directory.appending(path: "staging"))
            try? fileManager.removeItem(at: directory.appending(path: "output"))
            try? fileManager.removeItem(at: sibling)
            try await journal.transition(jobID: job.id, from: [job.state], to: .failed, errorCode: "interrupted", errorDetail: "Interrupted before atomic replacement")
        }
    }

    private func reconcileCopy(_ job: JournalJob, root: URL) async throws {
        guard job.state != .needsRecovery else { return }
        if ![.publishingOriginal, .publishingConverted].contains(job.state),
           job.sourceHash == nil || job.outputHash == nil {
            let directory = storageRoot.appending(path: job.id.uuidString)
            try? fileManager.removeItem(at: directory.appending(path: "staging"))
            try? fileManager.removeItem(at: directory.appending(path: "output"))
            try await journal.transition(
                jobID: job.id,
                from: [job.state],
                to: .failed,
                errorCode: "interrupted",
                errorDetail: "Interrupted before copy publication"
            )
            return
        }
        guard let sourceHash = job.sourceHash,
              let outputHash = job.outputHash,
              let target = safeLeaf(root: root, relativePath: job.newRelativePath),
              let original = safeLeaf(root: root, relativePath: job.oldRelativePath) else {
            try await markNeedsRecovery(job, code: "unsafeRecoveryPath")
            return
        }
        let originalSibling = original.deletingLastPathComponent().appending(path: ".fileconvert-\(job.id.uuidString)-original.tmp")
        let outputSibling = target.deletingLastPathComponent().appending(path: ".fileconvert-\(job.id.uuidString)-output.tmp")

        switch job.state {
        case .publishingOriginal, .publishingConverted:
            let originalHash = regularFileHash(original)
            let targetHash = regularFileHash(target)
            let preparedOriginalHash = regularFileHash(originalSibling)
            let preparedOutputHash = regularFileHash(outputSibling)

            if originalHash == sourceHash, targetHash == outputHash {
                removeIfMatching(originalSibling, hash: sourceHash)
                removeIfMatching(outputSibling, hash: outputHash)
                try await journal.transition(jobID: job.id, from: [job.state], to: .succeeded)
                return
            }

            if job.state == .publishingOriginal,
               originalHash == nil,
               targetHash == sourceHash,
               preparedOriginalHash == sourceHash,
               preparedOutputHash == outputHash {
                do {
                    try renameExclusively(from: originalSibling, to: original)
                    try flushDirectory(original.deletingLastPathComponent())
                    try await journal.transition(jobID: job.id, from: [.publishingOriginal], to: .publishingConverted)
                } catch FileConvertError.destinationExists {
                    try await markNeedsRecovery(job, code: "destinationExists")
                    return
                }
                try await publishRecoveredOutput(job, original: original, target: target, outputSibling: outputSibling, sourceHash: sourceHash, outputHash: outputHash)
                return
            }

            if job.state == .publishingOriginal,
               originalHash == sourceHash,
               targetHash == sourceHash,
               preparedOutputHash == outputHash {
                try await journal.transition(jobID: job.id, from: [.publishingOriginal], to: .publishingConverted)
                try await publishRecoveredOutput(job, original: original, target: target, outputSibling: outputSibling, sourceHash: sourceHash, outputHash: outputHash)
                return
            }

            if job.state == .publishingConverted,
               originalHash == sourceHash,
               targetHash == sourceHash,
               preparedOutputHash == outputHash {
                try await publishRecoveredOutput(job, original: original, target: target, outputSibling: outputSibling, sourceHash: sourceHash, outputHash: outputHash)
                return
            }

            try await markNeedsRecovery(job, code: "ambiguousCopyPublication")
        default:
            let originalSiblingHash = regularFileHash(originalSibling)
            let outputSiblingHash = regularFileHash(outputSibling)
            guard (originalSiblingHash == nil || originalSiblingHash == sourceHash),
                  (outputSiblingHash == nil || outputSiblingHash == outputHash) else {
                try await markNeedsRecovery(job, code: "ambiguousCopyArtifact")
                return
            }
            removeIfMatching(originalSibling, hash: sourceHash)
            removeIfMatching(outputSibling, hash: outputHash)
            let directory = storageRoot.appending(path: job.id.uuidString)
            try? fileManager.removeItem(at: directory.appending(path: "staging"))
            try? fileManager.removeItem(at: directory.appending(path: "output"))
            try await journal.transition(jobID: job.id, from: [job.state], to: .failed, errorCode: "interrupted", errorDetail: "Interrupted before copy publication")
        }
    }

    private func publishRecoveredOutput(
        _ job: JournalJob,
        original: URL,
        target: URL,
        outputSibling: URL,
        sourceHash: Data,
        outputHash: Data
    ) async throws {
        guard regularFileHash(original) == sourceHash,
              regularFileHash(target) == sourceHash,
              regularFileHash(outputSibling) == outputHash else {
            try await markNeedsRecovery(job, code: "ambiguousCopyPublication")
            return
        }
        guard rename(outputSibling.path, target.path) == 0 else {
            try await markNeedsRecovery(job, code: "copyPublicationFailed")
            return
        }
        try flushDirectory(target.deletingLastPathComponent())
        guard regularFileHash(original) == sourceHash, regularFileHash(target) == outputHash else {
            try await markNeedsRecovery(job, code: "ambiguousCopyPublication")
            return
        }
        try await journal.transition(jobID: job.id, from: [.publishingConverted], to: .succeeded)
    }

    private func markNeedsRecovery(_ job: JournalJob, code: String) async throws {
        try await journal.transition(jobID: job.id, from: [job.state, .publishingConverted], to: .needsRecovery, errorCode: code, errorDetail: "Copy publication artifacts require manual recovery")
    }

    private func regularFileHash(_ url: URL) -> Data? {
        var status = stat()
        guard lstat(url.path, &status) == 0, status.st_mode & S_IFMT == S_IFREG else { return nil }
        return try? TransactionCoordinator.sha256(url)
    }

    private func removeIfMatching(_ url: URL, hash: Data) {
        guard regularFileHash(url) == hash else { return }
        try? fileManager.removeItem(at: url)
    }

    private func safeLeaf(root: URL, relativePath: String) -> URL? {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.split(separator: "/").contains(where: { $0 == "." || $0 == ".." || $0.isEmpty }),
              let rootPointer = realpath(root.path, nil) else { return nil }
        defer { free(rootPointer) }
        let canonicalRoot = URL(fileURLWithPath: String(cString: rootPointer), isDirectory: true)
        let candidate = canonicalRoot.appending(path: relativePath)
        let lexicalParent = candidate.deletingLastPathComponent()
        guard let parentPointer = realpath(lexicalParent.path, nil) else { return nil }
        defer { free(parentPointer) }
        let parent = URL(fileURLWithPath: String(cString: parentPointer), isDirectory: true)
        let rootComponents = canonicalRoot.standardizedFileURL.pathComponents
        let parentComponents = parent.standardizedFileURL.pathComponents
        guard parentComponents.count >= rootComponents.count,
              parentComponents.prefix(rootComponents.count).elementsEqual(rootComponents),
              lexicalParent.standardizedFileURL.path == parent.standardizedFileURL.path else { return nil }
        return parent.appendingPathComponent(candidate.lastPathComponent)
    }

    private func validateArtifact(_ url: URL, expectedHash: Data) throws {
        var status = stat()
        guard lstat(url.path, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              access(url.path, R_OK) == 0 else {
            throw RecoveryActionError.artifactUnavailable
        }
        do {
            guard try TransactionCoordinator.sha256(url) == expectedHash else {
                throw RecoveryActionError.integrityFailure
            }
        } catch let error as RecoveryActionError {
            throw error
        } catch {
            throw RecoveryActionError.artifactUnavailable
        }
    }

    private func validateDestination(_ destination: URL) throws {
        guard !destination.lastPathComponent.isEmpty else {
            throw RecoveryActionError.publicationFailed
        }
        var destinationStatus = stat()
        if lstat(destination.path, &destinationStatus) == 0 {
            throw RecoveryActionError.destinationExists
        }
        if errno != ENOENT {
            if errno == EACCES || errno == EPERM { throw RecoveryActionError.permissionDenied }
            throw RecoveryActionError.publicationFailed
        }
        let parent = destination.deletingLastPathComponent()
        var parentStatus = stat()
        guard stat(parent.path, &parentStatus) == 0,
              parentStatus.st_mode & S_IFMT == S_IFDIR else {
            if errno == EACCES || errno == EPERM { throw RecoveryActionError.permissionDenied }
            throw RecoveryActionError.publicationFailed
        }
        guard access(parent.path, W_OK) == 0 else {
            throw RecoveryActionError.permissionDenied
        }
    }

    private func apply(_ metadata: FileMetadata, to url: URL) throws {
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: NSNumber(value: metadata.permissions)]
        if let date = metadata.creationDate { attributes[.creationDate] = date }
        if let date = metadata.modificationDate { attributes[.modificationDate] = date }
        try fileManager.setAttributes(attributes, ofItemAtPath: url.path)
    }

    private func flushFile(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private static func isPermissionError(_ error: POSIXError) -> Bool {
        error.code == .EACCES || error.code == .EPERM || error.code == .EROFS
    }

    private func renameExclusively(from source: URL, to destination: URL) throws {
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

    private func flushDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}

public actor UndoCoordinator {
    private let journal: JournalStore
    private let storageRoot: URL
    private let fileManager: FileManager

    public init(journal: JournalStore, storageRoot: URL, fileManager: FileManager = .default) {
        self.journal = journal; self.storageRoot = storageRoot; self.fileManager = fileManager
    }

    public func undo(jobID: UUID, rootURL: URL) async throws -> UndoResult {
        guard let job = try await journal.job(id: jobID),
              job.state == .succeeded,
              let sourceHash = job.sourceHash,
              let outputHash = job.outputHash else {
            throw FileConvertError.validationFailed("Undo is unavailable")
        }
        let reportedCurrent = rootURL.appending(path: job.newRelativePath)
        if job.conversionBehavior == .keepOriginal {
            guard let current = try? BoundaryGuards.canonicalRegularFile(
                root: rootURL,
                relativePath: job.newRelativePath
            ),
            try TransactionCoordinator.sha256(current) == outputHash,
            let original = try? BoundaryGuards.canonicalRegularFile(
                root: rootURL,
                relativePath: job.oldRelativePath
            ),
            try TransactionCoordinator.sha256(original) == sourceHash else {
                return .conflict(currentURL: reportedCurrent)
            }
            let outputIdentity = try FileFacts.read(current).identity
            let quarantine = current.deletingLastPathComponent().appending(path: ".fileconvert-undo-\(jobID.uuidString).tmp")
            guard !fileManager.fileExists(atPath: quarantine.path) else {
                return .conflict(currentURL: reportedCurrent)
            }
            try renameExclusively(from: current, to: quarantine)
            do {
                guard try FileFacts.read(quarantine).identity == outputIdentity,
                      try TransactionCoordinator.sha256(quarantine) == outputHash,
                      try TransactionCoordinator.sha256(original) == sourceHash else {
                    try renameExclusively(from: quarantine, to: current)
                    return .conflict(currentURL: reportedCurrent)
                }
                try fileManager.removeItem(at: quarantine)
                try flushDirectory(current.deletingLastPathComponent())
                return .restored(rootURL.appending(path: job.oldRelativePath))
            } catch {
                if fileManager.fileExists(atPath: quarantine.path),
                   !fileManager.fileExists(atPath: current.path) {
                    try? renameExclusively(from: quarantine, to: current)
                }
                throw error
            }
        }

        let current = try BoundaryGuards.canonicalRegularFile(root: rootURL, relativePath: job.newRelativePath)
        guard try TransactionCoordinator.sha256(current) == outputHash else {
            return .conflict(currentURL: reportedCurrent)
        }

        guard let backup = try await journal.backup(jobID: jobID) else {
            throw FileConvertError.validationFailed("Undo is unavailable")
        }
        let destination = rootURL.appending(path: job.oldRelativePath)
        if destination != current && fileManager.fileExists(atPath: destination.path) { return .conflict(currentURL: current) }
        let backupURL = storageRoot.appending(path: backup.relativeStoragePath)
        guard try TransactionCoordinator.sha256(backupURL) == backup.sha256 else { throw FileConvertError.validationFailed("Backup hash mismatch") }
        let temporary = destination.deletingLastPathComponent().appending(path: ".fileconvert-undo-\(jobID.uuidString).tmp")
        try? fileManager.removeItem(at: temporary)
        try TransactionCoordinator.cloneOrCopy(from: backupURL, to: temporary)
        let metadata = try JSONDecoder().decode(FileMetadata.self, from: backup.metadata)
        try apply(metadata, to: temporary)
        try flush(temporary)
        guard rename(temporary.path, destination.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        try flushDirectory(destination.deletingLastPathComponent())
        if destination != current { try fileManager.removeItem(at: current) }
        return .restored(destination)
    }

    public func restoreToNewFile(jobID: UUID, destination: URL) async throws -> URL {
        guard !fileManager.fileExists(atPath: destination.path), let backup = try await journal.backup(jobID: jobID) else { throw FileConvertError.validationFailed("Restore destination is unavailable") }
        let backupURL = storageRoot.appending(path: backup.relativeStoragePath)
        guard try TransactionCoordinator.sha256(backupURL) == backup.sha256 else { throw FileConvertError.validationFailed("Backup hash mismatch") }
        let temporary = destination.deletingLastPathComponent().appending(path: ".fileconvert-restore-\(jobID.uuidString).tmp")
        try? fileManager.removeItem(at: temporary)
        try TransactionCoordinator.cloneOrCopy(from: backupURL, to: temporary)
        try flush(temporary)
        guard rename(temporary.path, destination.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        try flushDirectory(destination.deletingLastPathComponent())
        return destination
    }

    public func prune(now: Date = Date(), byteLimit: UInt64 = 10 << 30) async throws {
        for backup in try await journal.prunableBackups(now: now, byteLimit: byteLimit) {
            let url = storageRoot.appending(path: backup.relativeStoragePath)
            try? fileManager.removeItem(at: url)
            try await journal.removeBackup(jobID: backup.jobID)
        }
    }

    private func apply(_ metadata: FileMetadata, to url: URL) throws {
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: NSNumber(value: metadata.permissions)]
        if let date = metadata.creationDate { attributes[.creationDate] = date }
        if let date = metadata.modificationDate { attributes[.modificationDate] = date }
        try fileManager.setAttributes(attributes, ofItemAtPath: url.path)
    }

    private func flush(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        try flushDirectory(url.deletingLastPathComponent())
    }

    private func renameExclusively(from source: URL, to destination: URL) throws {
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

    private func flushDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
