import CryptoKit
import FileConvertCore
import Foundation
import Testing

private struct InjectedFailure: Error, Equatable {}

private struct TransactionHarness {
    let base: URL
    let root: URL
    let storage: URL
    let database: URL
    let rootID = UUID()

    init() throws {
        base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        root = base.appending(path: "watched", directoryHint: .isDirectory)
        storage = base.appending(path: "storage", directoryHint: .isDirectory)
        database = base.appending(path: "journal.sqlite")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: base) }

    func target(source: Data = Data("source bytes".utf8)) throws -> URL {
        let url = root.appending(path: "document.html")
        try source.write(to: url, options: .atomic)
        return url
    }

    func request(id: UUID = UUID(), behavior: ConversionBehavior = .replaceWithBackup) -> TransactionRequest {
        TransactionRequest(id: id, rootID: rootID, rootURL: root, oldRelativePath: "document.txt", newRelativePath: "document.html", sourceFormat: .document(.text), targetFormat: .document(.html), targetExtension: "html", providerID: ProviderID(rawValue: "test"), providerVersion: "1", policy: .document(acceptsFidelityLoss: true), conversionBehavior: behavior)
    }
}

private func producer(output: Data) -> ArtifactProducer {
    { _, directory in
        let url = directory.appending(path: "converted.html")
        try output.write(to: url, options: .atomic)
        return ProducedArtifact(url: url, providerID: ProviderID(rawValue: "test"))
    }
}

private let testValidator: ArtifactValidator = { artifact, expected in
    (try TransactionCoordinator.sha256(artifact.url), expected)
}

private func seedRecovery(
    harness: TransactionHarness,
    journal: JournalStore,
    bytes: Data = Data("retained original".utf8),
    relativeStoragePath suppliedRelativeStoragePath: String? = nil
) async throws -> (jobID: UUID, artifact: URL) {
    let jobID = UUID()
    let relativeStoragePath = suppliedRelativeStoragePath ?? "\(jobID.uuidString)/backup/source"
    let artifact = harness.storage.appending(path: relativeStoragePath)
    try FileManager.default.createDirectory(
        at: artifact.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try bytes.write(to: artifact)
    let hash = Data(SHA256.hash(data: bytes))
    let metadata = try JSONEncoder().encode(
        FileMetadata(permissions: 0o640, creationDate: nil, modificationDate: nil)
    )
    let now = Date()
    try await journal.insert(
        JournalJob(
            id: jobID,
            rootID: harness.rootID,
            fileKey: "recovery-\(jobID.uuidString)",
            oldRelativePath: "document.txt",
            newRelativePath: "document.html",
            sourceFormat: "text",
            targetFormat: "html",
            providerID: "test",
            providerVersion: "1",
            policyJSON: Data("{}".utf8),
            sourceHash: hash,
            outputHash: nil,
            state: .needsRecovery,
            conversionBehavior: .replaceWithBackup,
            createdAt: now,
            updatedAt: now,
            errorCode: "ambiguousCommit",
            errorDetail: "Recovery required"
        )
    )
    try await journal.insertBackup(
        BackupRecord(
            jobID: jobID,
            relativeStoragePath: relativeStoragePath,
            byteCount: UInt64(bytes.count),
            sha256: hash,
            metadata: metadata,
            expiresAt: now.addingTimeInterval(86_400)
        )
    )
    return (jobID, artifact)
}
private let replaceFailpoints: [TransactionFailpoint] = [
    .afterJournalDiscovery, .afterStage, .afterStageJournal, .afterBackup, .afterBackupJournal,
    .afterConversion, .afterValidation, .afterValidationJournal, .afterSiblingCopy, .afterSiblingFlush,
    .beforeReplace, .afterReplace, .afterCommitJournal
]
private let copyPrepublicationFailpoints: [TransactionFailpoint] = [
    .afterJournalDiscovery, .afterStage, .afterStageJournal,
    .afterConversion, .afterValidation, .afterValidationJournal,
    .beforeCopyPublication, .afterOriginalSiblingCopy, .afterOriginalSiblingHash,
    .afterOriginalSiblingFlush, .afterOutputSiblingCopy, .afterOutputSiblingHash,
    .afterOutputSiblingFlush
]
private let copyPublicationFailpoints: [TransactionFailpoint] = [
    .afterPublishingOriginalJournal, .afterOriginalPublish, .afterOriginalParentFlush,
    .afterPublishingConvertedJournal, .beforeCopyOutputPublish, .afterCopyOutputPublish,
    .afterCopyOutputParentFlush, .afterCopyCommitJournal
]



@Test
func successfulTransactionReplacesOnlyAfterBackupAndCanUndo() async throws {
    let harness = try TransactionHarness()
    defer { harness.remove() }
    let source = Data("source bytes".utf8)
    let output = Data("converted bytes".utf8)
    let target = try harness.target(source: source)
    let journal = try JournalStore(url: harness.database)
    let transaction = try TransactionCoordinator(journal: journal, storageRoot: harness.storage)
    let request = harness.request()

    let committed = try await transaction.execute(request, produce: producer(output: output), validate: testValidator)
    #expect(try Data(contentsOf: target) == output)
    #expect(committed.sourceHash == Data(SHA256.hash(data: source)))
    let backup = try #require(await journal.backup(jobID: request.id))
    #expect(try Data(contentsOf: harness.storage.appending(path: backup.relativeStoragePath)) == source)

    let undo = UndoCoordinator(journal: journal, storageRoot: harness.storage)
    #expect(try await undo.undo(jobID: request.id, rootURL: harness.root) == .restored(harness.root.appending(path: "document.txt")))
    #expect(try Data(contentsOf: harness.root.appending(path: "document.txt")) == source)
    #expect(!FileManager.default.fileExists(atPath: target.path))
}

@Test(arguments: replaceFailpoints)
func everyFailpointPreservesExactSourceOrValidatedOutput(failpoint: TransactionFailpoint) async throws {
    let harness = try TransactionHarness()
    defer { harness.remove() }
    let source = Data("source bytes".utf8)
    let output = Data("validated output".utf8)
    let target = try harness.target(source: source)
    let journal = try JournalStore(url: harness.database)
    let transaction = try TransactionCoordinator(journal: journal, storageRoot: harness.storage) { point in
        if point == failpoint { throw InjectedFailure() }
    }
    let request = harness.request()

    await #expect(throws: InjectedFailure.self) {
        try await transaction.execute(request, produce: producer(output: output), validate: testValidator)
    }
    let original = harness.root.appending(path: request.oldRelativePath)
    let sourceURL = failpoint == .afterJournalDiscovery ? target : original
    if [.afterReplace, .afterCommitJournal].contains(failpoint) {
        #expect(try Data(contentsOf: target) == output)
    } else {
        #expect(try Data(contentsOf: sourceURL) == source)
    }
    if let backup = try await journal.backup(jobID: request.id) {
        #expect(try Data(contentsOf: harness.storage.appending(path: backup.relativeStoragePath)) == source)
    } else {
        #expect([.afterJournalDiscovery, .afterStage, .afterStageJournal, .afterBackup].contains(failpoint))
    }

    let recovery = RecoveryCoordinator(journal: journal, storageRoot: harness.storage)
    try await recovery.reconcile(roots: [harness.rootID: harness.root])
    let recovered = try #require(await journal.job(id: request.id))
    if [.afterReplace, .afterCommitJournal].contains(failpoint) {
        #expect(recovered.state == .succeeded)
        #expect(try Data(contentsOf: target) == output)
    } else {
        #expect(recovered.state == .failed)
        #expect(try Data(contentsOf: sourceURL) == source)
    }
    try await recovery.reconcile(roots: [harness.rootID: harness.root])
    #expect(try await journal.job(id: request.id)?.state == recovered.state)
}

@Test
func undoRefusesChangedOutputAndRestoresToNewFile() async throws {
    let harness = try TransactionHarness()
    defer { harness.remove() }
    let source = Data("source bytes".utf8)
    let target = try harness.target(source: source)
    let journal = try JournalStore(url: harness.database)
    let transaction = try TransactionCoordinator(journal: journal, storageRoot: harness.storage)
    let request = harness.request()
    _ = try await transaction.execute(request, produce: producer(output: Data("converted".utf8)), validate: testValidator)
    try Data("user edit".utf8).write(to: target)

    let undo = UndoCoordinator(journal: journal, storageRoot: harness.storage)
    let undoResult = try await undo.undo(jobID: request.id, rootURL: harness.root)
    #expect(undoResult == .conflict(currentURL: target))
    #expect(try Data(contentsOf: target) == Data("user edit".utf8))
    let restored = harness.root.appending(path: "document restored.txt")
    #expect(try await undo.restoreToNewFile(jobID: request.id, destination: restored) == restored)
    #expect(try Data(contentsOf: restored) == source)
    #expect(try Data(contentsOf: target) == Data("user edit".utf8))
}

@Test
func transactionPersistsStableRequiresChoiceErrorCode() async throws {
    let harness = try TransactionHarness()
    defer { harness.remove() }
    _ = try harness.target()
    let journal = try JournalStore(url: harness.database)
    let transaction = try TransactionCoordinator(journal: journal, storageRoot: harness.storage)
    let request = harness.request()

    await #expect(throws: FileConvertError.self) {
        try await transaction.execute(request, produce: { _, _ in
            throw FileConvertError.requiresChoice
        }, validate: testValidator)
    }

    let job = try #require(await journal.job(id: request.id))
    #expect(job.state == .failed)
    #expect(job.errorCode == "requiresChoice")
    let original = harness.root.appending(path: request.oldRelativePath)
    let failedTarget = harness.root.appending(path: request.newRelativePath)
    #expect(try Data(contentsOf: original) == Data("source bytes".utf8))
    #expect(!FileManager.default.fileExists(atPath: failedTarget.path))
}

@Test
func transactionAppliesConfiguredRetentionToNewBackup() async throws {
    let harness = try TransactionHarness()
    defer { harness.remove() }
    _ = try harness.target()
    let journal = try JournalStore(url: harness.database)
    let transaction = try TransactionCoordinator(
        journal: journal,
        storageRoot: harness.storage,
        retentionDays: 7
    )
    let request = harness.request()

    _ = try await transaction.execute(
        request,
        produce: producer(output: Data("converted bytes".utf8)),
        validate: testValidator
    )

    let job = try #require(await journal.job(id: request.id))
    let backup = try #require(await journal.backup(jobID: request.id))
    let retention = backup.expiresAt.timeIntervalSince(job.createdAt)
    #expect(retention > 6.9 * 24 * 60 * 60)
    #expect(retention < 7.1 * 24 * 60 * 60)
}

@Test
func successfulTransactionPrunesBackupsAboveByteLimit() async throws {
    let harness = try TransactionHarness()
    defer { harness.remove() }
    _ = try harness.target()
    let journal = try JournalStore(url: harness.database)
    let transaction = try TransactionCoordinator(
        journal: journal,
        storageRoot: harness.storage,
        backupByteLimit: 1
    )
    let request = harness.request()

    _ = try await transaction.execute(
        request,
        produce: producer(output: Data("converted bytes".utf8)),
        validate: testValidator
    )

    #expect(try await journal.backup(jobID: request.id) == nil)
}

@Test
func copyModePublishesVisibleOriginalAndOutputWithoutRetainedBackup() async throws {
    let harness = try TransactionHarness()
    defer { harness.remove() }
    let source = Data("exact original".utf8)
    let output = Data("validated output".utf8)
    let target = try harness.target(source: source)
    let modificationDate = Date(timeIntervalSince1970: 1_700_000_000)
    try FileManager.default.setAttributes([
        .posixPermissions: NSNumber(value: 0o640),
        .modificationDate: modificationDate
    ], ofItemAtPath: target.path)
    let journal = try JournalStore(url: harness.database)
    let transaction = try TransactionCoordinator(journal: journal, storageRoot: harness.storage, backupByteLimit: 1)
    let request = harness.request(behavior: .keepOriginal)

    let committed = try await transaction.execute(request, produce: producer(output: output), validate: testValidator)
    let original = harness.root.appending(path: "document.txt")
    #expect(try Data(contentsOf: original) == source)
    #expect(try Data(contentsOf: target) == output)
    #expect(try TransactionCoordinator.sha256(original) == committed.sourceHash)
    #expect(try TransactionCoordinator.sha256(target) == committed.outputHash)
    #expect(try await journal.backup(jobID: request.id) == nil)
    let originalAttributes = try FileManager.default.attributesOfItem(atPath: original.path)
    #expect(((originalAttributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777 == 0o640)
    #expect(try await journal.job(id: request.id)?.state == .succeeded)
    let undo = UndoCoordinator(journal: journal, storageRoot: harness.storage)
    #expect(try await undo.undo(jobID: request.id, rootURL: harness.root) == .restored(original))
    #expect(try Data(contentsOf: original) == source)
    #expect(!FileManager.default.fileExists(atPath: target.path))
}

@Test(arguments: [true, false])
func copyModeUndoRefusesChangedVisibleFile(changeOriginal: Bool) async throws {
    let harness = try TransactionHarness()
    defer { harness.remove() }
    let source = Data("exact original".utf8)
    let output = Data("validated output".utf8)
    let target = try harness.target(source: source)
    let journal = try JournalStore(url: harness.database)
    let transaction = try TransactionCoordinator(journal: journal, storageRoot: harness.storage)
    let request = harness.request(behavior: .keepOriginal)
    _ = try await transaction.execute(
        request,
        produce: producer(output: output),
        validate: testValidator
    )
    let original = harness.root.appending(path: "document.txt")
    let changed = Data("changed after conversion".utf8)
    try changed.write(to: changeOriginal ? original : target, options: .atomic)

    let undo = UndoCoordinator(journal: journal, storageRoot: harness.storage)
    let result = try await undo.undo(jobID: request.id, rootURL: harness.root)

    #expect(result == .conflict(currentURL: target))
    #expect(try Data(contentsOf: changeOriginal ? original : target) == changed)
    #expect(try Data(contentsOf: changeOriginal ? target : original) == (changeOriginal ? output : source))
}

@Test(arguments: [true, false])
func copyModeUndoRefusesMissingVisibleFile(removeOriginal: Bool) async throws {
    let harness = try TransactionHarness()
    defer { harness.remove() }
    let source = Data("exact original".utf8)
    let output = Data("validated output".utf8)
    let target = try harness.target(source: source)
    let journal = try JournalStore(url: harness.database)
    let transaction = try TransactionCoordinator(journal: journal, storageRoot: harness.storage)
    let request = harness.request(behavior: .keepOriginal)
    _ = try await transaction.execute(
        request,
        produce: producer(output: output),
        validate: testValidator
    )
    let original = harness.root.appending(path: "document.txt")
    try FileManager.default.removeItem(at: removeOriginal ? original : target)

    let undo = UndoCoordinator(journal: journal, storageRoot: harness.storage)
    let result = try await undo.undo(jobID: request.id, rootURL: harness.root)

    #expect(result == .conflict(currentURL: target))
    #expect(try Data(contentsOf: removeOriginal ? target : original) == (removeOriginal ? output : source))
}

@Test
func copyModeUndoRefusesOccupiedQuarantineWithoutDeletingVisibleFiles() async throws {
    let harness = try TransactionHarness()
    defer { harness.remove() }
    let source = Data("exact original".utf8)
    let output = Data("validated output".utf8)
    let target = try harness.target(source: source)
    let journal = try JournalStore(url: harness.database)
    let transaction = try TransactionCoordinator(journal: journal, storageRoot: harness.storage)
    let request = harness.request(behavior: .keepOriginal)
    _ = try await transaction.execute(
        request,
        produce: producer(output: output),
        validate: testValidator
    )
    let original = harness.root.appending(path: "document.txt")
    let quarantine = harness.root.appending(path: ".fileconvert-undo-\(request.id.uuidString).tmp")
    let occupied = Data("pre-existing private-name file".utf8)
    try occupied.write(to: quarantine, options: .atomic)

    let undo = UndoCoordinator(journal: journal, storageRoot: harness.storage)
    let result = try await undo.undo(jobID: request.id, rootURL: harness.root)

    #expect(result == .conflict(currentURL: target))
    #expect(try Data(contentsOf: original) == source)
    #expect(try Data(contentsOf: target) == output)
    #expect(try Data(contentsOf: quarantine) == occupied)
}

@Test
func copyModeRejectsOccupiedOriginalAndPreservesBothUserFiles() async throws {
    let harness = try TransactionHarness()
    defer { harness.remove() }
    let source = Data("exact original".utf8)
    let occupied = Data("occupied original".utf8)
    let target = try harness.target(source: source)
    let original = harness.root.appending(path: "document.txt")
    try occupied.write(to: original)
    let journal = try JournalStore(url: harness.database)
    let transaction = try TransactionCoordinator(journal: journal, storageRoot: harness.storage)
    let request = harness.request(behavior: .keepOriginal)

    await #expect(throws: FileConvertError.self) {
        try await transaction.execute(request, produce: producer(output: Data("output".utf8)), validate: testValidator)
    }
    #expect(try Data(contentsOf: original) == occupied)
    #expect(try Data(contentsOf: target) == source)
    #expect(try await journal.job(id: request.id)?.state == .needsRecovery)
    #expect(try await journal.job(id: request.id)?.errorCode == "filenameRollbackFailed")
}

@Test
func copyModeRejectsOriginalSymlinkWithoutFollowingIt() async throws {
    let harness = try TransactionHarness()
    defer { harness.remove() }
    let source = Data("exact original".utf8)
    let target = try harness.target(source: source)
    let original = harness.root.appending(path: "document.txt")
    let external = harness.base.appending(path: "external.txt")
    try Data("external".utf8).write(to: external)
    try FileManager.default.createSymbolicLink(at: original, withDestinationURL: external)
    let journal = try JournalStore(url: harness.database)
    let transaction = try TransactionCoordinator(journal: journal, storageRoot: harness.storage)
    let request = harness.request(behavior: .keepOriginal)

    await #expect(throws: FileConvertError.self) {
        try await transaction.execute(request, produce: producer(output: Data("output".utf8)), validate: testValidator)
    }
    #expect(try Data(contentsOf: external) == Data("external".utf8))
    #expect(try Data(contentsOf: target) == source)
    #expect(try await journal.job(id: request.id)?.state == .needsRecovery)
    #expect(try await journal.job(id: request.id)?.errorCode == "filenameRollbackFailed")
}
@Test
func copyModeRejectsTargetMutationBeforePublication() async throws {
    let harness = try TransactionHarness()
    defer { harness.remove() }
    let source = Data("exact original".utf8)
    let target = try harness.target(source: source)
    let journal = try JournalStore(url: harness.database)
    let transaction = try TransactionCoordinator(journal: journal, storageRoot: harness.storage) { point in
        if point == .beforeCopyPublication { try Data("concurrent edit".utf8).write(to: target) }
    }

    await #expect(throws: FileConvertError.self) {
        try await transaction.execute(harness.request(behavior: .keepOriginal), produce: producer(output: Data("output".utf8)), validate: testValidator)
    }
    #expect(try Data(contentsOf: target) == Data("concurrent edit".utf8))
    #expect(!FileManager.default.fileExists(atPath: harness.root.appending(path: "document.txt").path))
}

@Test(arguments: copyPrepublicationFailpoints)
func everyCopyPrepublicationFailpointPreservesSourceAndPublishesNothing(failpoint: TransactionFailpoint) async throws {
    let harness = try TransactionHarness()
    defer { harness.remove() }
    let source = Data("exact original".utf8)
    let target = try harness.target(source: source)
    let journal = try JournalStore(url: harness.database)
    let transaction = try TransactionCoordinator(journal: journal, storageRoot: harness.storage) { point in
        if point == failpoint { throw InjectedFailure() }
    }
    let request = harness.request(behavior: .keepOriginal)

    await #expect(throws: InjectedFailure.self) {
        try await transaction.execute(
            request,
            produce: producer(output: Data("validated output".utf8)),
            validate: testValidator
        )
    }

    let original = harness.root.appending(path: request.oldRelativePath)
    let sourceURL = failpoint == .afterJournalDiscovery ? target : original
    #expect(try Data(contentsOf: sourceURL) == source)
    #expect(try await journal.backup(jobID: request.id) == nil)
    #expect(try await journal.job(id: request.id)?.state == (failpoint == .afterJournalDiscovery ? .discovered : .failed))

    let recovery = RecoveryCoordinator(journal: journal, storageRoot: harness.storage)
    try await recovery.reconcile(roots: [harness.rootID: harness.root])
    #expect(try Data(contentsOf: sourceURL) == source)
    #expect(try await journal.job(id: request.id)?.state == .failed)
}

@Test(arguments: copyPublicationFailpoints)
func recoveryCompletesEveryInterruptedCopyPublication(failpoint: TransactionFailpoint) async throws {
    let harness = try TransactionHarness()
    defer { harness.remove() }
    let source = Data("exact original".utf8)
    let output = Data("validated output".utf8)
    let target = try harness.target(source: source)
    let journal = try JournalStore(url: harness.database)
    let transaction = try TransactionCoordinator(journal: journal, storageRoot: harness.storage) { point in
        if point == failpoint { throw InjectedFailure() }
    }
    let request = harness.request(behavior: .keepOriginal)

    await #expect(throws: InjectedFailure.self) {
        try await transaction.execute(request, produce: producer(output: output), validate: testValidator)
    }
    let recovery = RecoveryCoordinator(journal: journal, storageRoot: harness.storage)
    try await recovery.reconcile(roots: [harness.rootID: harness.root])

    let original = harness.root.appending(path: "document.txt")
    #expect(try Data(contentsOf: original) == source)
    #expect(try Data(contentsOf: target) == output)
    #expect(try await journal.job(id: request.id)?.state == .succeeded)
    try await recovery.reconcile(roots: [harness.rootID: harness.root])
    #expect(try await journal.job(id: request.id)?.state == .succeeded)
}

@Test
func recoveryPreservesAmbiguousCopyArtifactsAndUserFiles() async throws {
    let harness = try TransactionHarness()
    defer { harness.remove() }
    let source = Data("exact original".utf8)
    let occupied = Data("unrelated user file".utf8)
    let target = try harness.target(source: source)
    let journal = try JournalStore(url: harness.database)
    let transaction = try TransactionCoordinator(journal: journal, storageRoot: harness.storage) { point in
        if point == .afterPublishingOriginalJournal { throw InjectedFailure() }
    }
    let request = harness.request(behavior: .keepOriginal)

    await #expect(throws: InjectedFailure.self) {
        try await transaction.execute(request, produce: producer(output: Data("validated output".utf8)), validate: testValidator)
    }
    let original = harness.root.appending(path: "document.txt")
    try occupied.write(to: original)
    let originalSibling = harness.root.appending(path: ".fileconvert-\(request.id.uuidString)-original.tmp")
    let outputSibling = harness.root.appending(path: ".fileconvert-\(request.id.uuidString)-output.tmp")
    let recovery = RecoveryCoordinator(journal: journal, storageRoot: harness.storage)
    try await recovery.reconcile(roots: [harness.rootID: harness.root])

    #expect(try await journal.job(id: request.id)?.state == .needsRecovery)
    #expect(try Data(contentsOf: original) == occupied)
    #expect(try Data(contentsOf: target) == source)
    #expect(FileManager.default.fileExists(atPath: originalSibling.path))
    #expect(FileManager.default.fileExists(atPath: outputSibling.path))
}

@Test
func retainedRecoveryPublishesExactSeparateFileAndPersistsResolution() async throws {
    let harness = try TransactionHarness()
    defer { harness.remove() }
    let visible = try harness.target(source: Data("current visible bytes".utf8))
    let journal = try JournalStore(url: harness.database)
    let retained = Data("verified retained bytes".utf8)
    let seeded = try await seedRecovery(harness: harness, journal: journal, bytes: retained)
    let destination = harness.root.appending(path: "document — Recovered.txt")
    let recovery = RecoveryCoordinator(journal: journal, storageRoot: harness.storage)

    #expect(try await recovery.restoreRetainedFile(jobID: seeded.jobID, destination: destination) == destination)
    #expect(try Data(contentsOf: destination) == retained)
    #expect(try Data(contentsOf: visible) == Data("current visible bytes".utf8))
    #expect(try Data(contentsOf: seeded.artifact) == retained)
    let resolution = try #require(await journal.recoveryResolution(jobID: seeded.jobID))
    #expect(resolution.method == .restored)
    #expect(resolution.destinationFilename == "document — Recovered.txt")
}

@Test
func retainedRecoveryRefusesOccupiedDestinationWithoutChangingFiles() async throws {
    let harness = try TransactionHarness()
    defer { harness.remove() }
    let journal = try JournalStore(url: harness.database)
    let seeded = try await seedRecovery(harness: harness, journal: journal)
    let destination = harness.root.appending(path: "occupied.txt")
    let occupied = Data("user-owned bytes".utf8)
    try occupied.write(to: destination)
    let recovery = RecoveryCoordinator(journal: journal, storageRoot: harness.storage)

    await #expect(throws: RecoveryActionError.destinationExists) {
        try await recovery.restoreRetainedFile(jobID: seeded.jobID, destination: destination)
    }
    #expect(try Data(contentsOf: destination) == occupied)
    #expect(try Data(contentsOf: seeded.artifact) == Data("retained original".utf8))
    #expect(try await journal.recoveryResolution(jobID: seeded.jobID) == nil)

    try FileManager.default.removeItem(at: destination)
    #expect(try await recovery.restoreRetainedFile(jobID: seeded.jobID, destination: destination) == destination)
    #expect(try Data(contentsOf: destination) == Data("retained original".utf8))
    #expect(try await journal.recoveryResolution(jobID: seeded.jobID)?.method == .restored)
}

@Test
func retainedRecoveryRejectsDirectoryAndSymbolicLinkDestinations() async throws {
    let harness = try TransactionHarness()
    defer { harness.remove() }
    let journal = try JournalStore(url: harness.database)
    let seeded = try await seedRecovery(harness: harness, journal: journal)
    let recovery = RecoveryCoordinator(journal: journal, storageRoot: harness.storage)
    let directory = harness.root.appending(path: "occupied-directory", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let external = harness.base.appending(path: "external-destination.txt")
    let externalBytes = Data("external destination".utf8)
    try externalBytes.write(to: external)
    let link = harness.root.appending(path: "occupied-link.txt")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)

    for destination in [directory, link] {
        await #expect(throws: RecoveryActionError.destinationExists) {
            try await recovery.restoreRetainedFile(jobID: seeded.jobID, destination: destination)
        }
    }
    #expect(try Data(contentsOf: external) == externalBytes)
    #expect(try Data(contentsOf: seeded.artifact) == Data("retained original".utf8))
    #expect(try await journal.recoveryResolution(jobID: seeded.jobID) == nil)
}

@Test
func retainedRecoveryExclusivePublicationRejectsDestinationRace() async throws {
    let harness = try TransactionHarness()
    defer { harness.remove() }
    let journal = try JournalStore(url: harness.database)
    let seeded = try await seedRecovery(harness: harness, journal: journal)
    let destination = harness.root.appending(path: "raced.txt")
    let racedBytes = Data("racing user file".utf8)
    let recovery = RecoveryCoordinator(
        journal: journal,
        storageRoot: harness.storage,
        failpoint: { point in
            if point == .afterStaging {
                try racedBytes.write(to: destination)
            }
        }
    )

    await #expect(throws: RecoveryActionError.destinationExists) {
        try await recovery.restoreRetainedFile(jobID: seeded.jobID, destination: destination)
    }
    #expect(try Data(contentsOf: destination) == racedBytes)
    #expect(try await journal.recoveryResolution(jobID: seeded.jobID) == nil)
    let residue = try FileManager.default.contentsOfDirectory(
        at: harness.root,
        includingPropertiesForKeys: nil
    ).filter { $0.lastPathComponent.hasPrefix(".fileflip-recovery-") }
    #expect(residue.isEmpty)
}

@Test(arguments: RecoveryFailpoint.allCases)
func retainedRecoveryFailpointsRemainRetryable(point: RecoveryFailpoint) async throws {
    let harness = try TransactionHarness()
    defer { harness.remove() }
    let journal = try JournalStore(url: harness.database)
    let retained = Data("failpoint retained bytes".utf8)
    let seeded = try await seedRecovery(harness: harness, journal: journal, bytes: retained)
    let destination = harness.root.appending(path: "\(point.rawValue).txt")
    let recovery = RecoveryCoordinator(
        journal: journal,
        storageRoot: harness.storage,
        failpoint: { observed in
            if observed == point { throw FileConvertError.cancelled }
        }
    )

    switch point {
    case .afterStaging:
        await #expect(throws: RecoveryActionError.publicationFailed) {
            try await recovery.restoreRetainedFile(jobID: seeded.jobID, destination: destination)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    case .beforeResolutionWrite:
        await #expect(
            throws: RecoveryActionError.restoredButResolutionWriteFailed(
                filename: destination.lastPathComponent
            )
        ) {
            try await recovery.restoreRetainedFile(jobID: seeded.jobID, destination: destination)
        }
        #expect(try Data(contentsOf: destination) == retained)
    }
    #expect(try await journal.recoveryResolution(jobID: seeded.jobID) == nil)
    #expect(try Data(contentsOf: seeded.artifact) == retained)

    let retryDestination = harness.root.appending(path: "\(point.rawValue)-retry.txt")
    let retry = RecoveryCoordinator(journal: journal, storageRoot: harness.storage)
    #expect(try await retry.restoreRetainedFile(jobID: seeded.jobID, destination: retryDestination) == retryDestination)
    #expect(try Data(contentsOf: retryDestination) == retained)
    #expect(try await journal.recoveryResolution(jobID: seeded.jobID)?.destinationFilename == retryDestination.lastPathComponent)
}

@Test
func retainedRecoveryRejectsMissingNonregularEscapingAndCorruptArtifacts() async throws {
    let harness = try TransactionHarness()
    defer { harness.remove() }
    let journal = try JournalStore(url: harness.database)
    let recovery = RecoveryCoordinator(journal: journal, storageRoot: harness.storage)

    let corrupt = try await seedRecovery(harness: harness, journal: journal)
    try Data("tampered".utf8).write(to: corrupt.artifact)
    await #expect(throws: RecoveryActionError.integrityFailure) {
        try await recovery.restoreRetainedFile(
            jobID: corrupt.jobID,
            destination: harness.root.appending(path: "corrupt.txt")
        )
    }

    let missing = try await seedRecovery(harness: harness, journal: journal)
    try FileManager.default.removeItem(at: missing.artifact)
    await #expect(throws: RecoveryActionError.artifactUnavailable) {
        try await recovery.restoreRetainedFile(
            jobID: missing.jobID,
            destination: harness.root.appending(path: "missing.txt")
        )
    }

    let directory = try await seedRecovery(harness: harness, journal: journal)
    try FileManager.default.removeItem(at: directory.artifact)
    try FileManager.default.createDirectory(at: directory.artifact, withIntermediateDirectories: false)
    await #expect(throws: RecoveryActionError.artifactUnavailable) {
        try await recovery.restoreRetainedFile(
            jobID: directory.jobID,
            destination: harness.root.appending(path: "directory.txt")
        )
    }

    let linked = try await seedRecovery(harness: harness, journal: journal)
    let external = harness.base.appending(path: "external.txt")
    try Data("retained original".utf8).write(to: external)
    try FileManager.default.removeItem(at: linked.artifact)
    try FileManager.default.createSymbolicLink(at: linked.artifact, withDestinationURL: external)
    await #expect(throws: RecoveryActionError.artifactUnavailable) {
        try await recovery.restoreRetainedFile(
            jobID: linked.jobID,
            destination: harness.root.appending(path: "linked.txt")
        )
    }

    let escaping = try await seedRecovery(
        harness: harness,
        journal: journal,
        relativeStoragePath: "../outside-recovery-root.txt"
    )
    await #expect(throws: RecoveryActionError.artifactUnavailable) {
        try await recovery.restoreRetainedFile(
            jobID: escaping.jobID,
            destination: harness.root.appending(path: "escaping.txt")
        )
    }

    for (jobID, name) in [
        (corrupt.jobID, "corrupt.txt"),
        (missing.jobID, "missing.txt"),
        (directory.jobID, "directory.txt"),
        (linked.jobID, "linked.txt"),
        (escaping.jobID, "escaping.txt"),
    ] {
        #expect(!FileManager.default.fileExists(atPath: harness.root.appending(path: name).path))
        #expect(try await journal.recoveryResolution(jobID: jobID) == nil)
    }
}

@Test
func manualRecoveryAcknowledgementIsPersistedWithoutPublishingAFile() async throws {
    let harness = try TransactionHarness()
    defer { harness.remove() }
    let journal = try JournalStore(url: harness.database)
    let seeded = try await seedRecovery(harness: harness, journal: journal)
    let recovery = RecoveryCoordinator(journal: journal, storageRoot: harness.storage)

    try await recovery.acknowledgeRecovery(jobID: seeded.jobID)

    let resolution = try #require(await journal.recoveryResolution(jobID: seeded.jobID))
    #expect(resolution.method == .acknowledged)
    #expect(resolution.destinationFilename == nil)
    #expect(try Data(contentsOf: seeded.artifact) == Data("retained original".utf8))
}
