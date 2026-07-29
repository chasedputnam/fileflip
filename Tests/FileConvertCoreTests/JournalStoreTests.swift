import FileConvertCore
import Foundation
import SQLite3
import Testing

private func journalJob(id: UUID = UUID(), state: PersistentJobState, hash: Data? = Data([1]), conversionBehavior: ConversionBehavior = .replaceWithBackup) -> JournalJob {
    let now = Date()
    return JournalJob(id: id, rootID: UUID(), fileKey: "1:2", oldRelativePath: "a.txt", newRelativePath: "a.html", sourceFormat: "text", targetFormat: "html", providerID: "test", providerVersion: "1", policyJSON: Data("{}".utf8), sourceHash: hash, outputHash: nil, state: state, conversionBehavior: conversionBehavior, createdAt: now, updatedAt: now, errorCode: nil, errorDetail: nil)
}

private func executeSQLite(at url: URL, sql: String) throws {
    var database: OpaquePointer?
    guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let database else {
        if let database { sqlite3_close(database) }
        throw JournalError.openFailed
    }
    defer { sqlite3_close(database) }
    var error: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
        let message = error.map { String(cString: $0) } ?? "Unknown SQLite error"
        sqlite3_free(error)
        throw JournalError.sql(message: message)
    }
}

private func sqliteUserVersion(at url: URL) throws -> Int {
    var database: OpaquePointer?
    guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let database else {
        if let database { sqlite3_close(database) }
        throw JournalError.openFailed
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "PRAGMA user_version;", -1, &statement, nil) == SQLITE_OK, let statement else {
        throw JournalError.sql(message: String(cString: sqlite3_errmsg(database)))
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { throw JournalError.corruptRow }
    return Int(sqlite3_column_int64(statement, 0))
}

private func createVersionOneJournal(at url: URL, id: UUID, rootID: UUID, version: Int = 1, conversionBehavior: String? = nil, state: String = "succeeded") throws {
    try executeSQLite(at: url, sql: """
    CREATE TABLE conversion_job (
      id TEXT PRIMARY KEY, root_id TEXT NOT NULL, file_key TEXT NOT NULL,
      old_relative_path TEXT NOT NULL, new_relative_path TEXT NOT NULL,
      source_format TEXT, target_format TEXT NOT NULL, provider_id TEXT, provider_version TEXT,
      policy_json BLOB, source_hash BLOB, output_hash BLOB, state TEXT NOT NULL,
      created_at REAL NOT NULL, updated_at REAL NOT NULL, error_code TEXT, error_detail TEXT
    );
    \(version == 2 ? "ALTER TABLE conversion_job ADD COLUMN conversion_behavior TEXT;" : "")
    INSERT INTO conversion_job
    (id, root_id, file_key, old_relative_path, new_relative_path, source_format, target_format,
     provider_id, provider_version, policy_json, source_hash, output_hash, state, created_at,
     updated_at, error_code, error_detail)
    VALUES ('\(id.uuidString)', '\(rootID.uuidString)', 'legacy:1', 'legacy.txt', 'legacy.html',
            'text', 'html', 'test', '1', X'7B7D', X'01', NULL, '\(state)', 1, 1, NULL, NULL);
    \(conversionBehavior.map { "UPDATE conversion_job SET conversion_behavior='\($0)';" } ?? "")
    PRAGMA user_version=\(version);
    """)
}

@Test
func journalUsesWALAndRejectsDuplicateTerminalJobs() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try JournalStore(url: directory.appending(path: "journal.sqlite"))

    try await store.insert(journalJob(state: .succeeded))
    await #expect(throws: JournalError.self) {
        try await store.insert(journalJob(state: .succeeded))
    }
}

@Test
func transitionRequiresExpectedCurrentState() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try JournalStore(url: directory.appending(path: "journal.sqlite"))
    let job = journalJob(state: .discovered, hash: nil)
    try await store.insert(job)

    await #expect(throws: JournalError.invalidTransition) {
        try await store.transition(jobID: job.id, from: [.backedUp], to: .converting)
    }
    try await store.transition(jobID: job.id, from: [.discovered], to: .stabilizing)
    #expect(try await store.job(id: job.id)?.state == .stabilizing)
}

@Test
func retentionSelectsExpiredThenOldestUntilUnderByteLimit() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try JournalStore(url: directory.appending(path: "journal.sqlite"))
    let now = Date()
    let expiredJob = journalJob(state: .succeeded, hash: Data([1]))
    let retainedJob = JournalJob(id: UUID(), rootID: UUID(), fileKey: "1:3", oldRelativePath: "b.txt", newRelativePath: "b.html", sourceFormat: "text", targetFormat: "html", providerID: "test", providerVersion: "1", policyJSON: nil, sourceHash: Data([2]), outputHash: nil, state: .succeeded, conversionBehavior: .replaceWithBackup, createdAt: now.addingTimeInterval(1), updatedAt: now, errorCode: nil, errorDetail: nil)
    try await store.insert(expiredJob)
    try await store.insert(retainedJob)
    try await store.insertBackup(BackupRecord(jobID: expiredJob.id, relativeStoragePath: "expired", byteCount: 10, sha256: Data([1]), metadata: Data(), expiresAt: now.addingTimeInterval(-1)))
    try await store.insertBackup(BackupRecord(jobID: retainedJob.id, relativeStoragePath: "retained", byteCount: 10, sha256: Data([2]), metadata: Data(), expiresAt: now.addingTimeInterval(60)))

    let expired = try await store.prunableBackups(now: now, byteLimit: 100)
    #expect(expired.map(\.jobID) == [expiredJob.id])
    let overLimit = try await store.prunableBackups(now: now.addingTimeInterval(-2), byteLimit: 10)
    #expect(overLimit.count == 1)
}

@Test
func eventCursorIsPersistedForAuthorizedRoot() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try JournalStore(url: directory.appending(path: "journal.sqlite"))
    let root = AuthorizedRootRecord(id: UUID(), bookmark: Data([1, 2]), displayPath: directory.path, volumeUUID: UUID(), enabled: true, eventCursor: 41, status: "available")

    try await store.upsertAuthorizedRoot(root)
    try await store.persistEventCursor(rootID: root.id, eventID: 99)

    let restored = try #require(try await store.authorizedRoots().first)
    #expect(restored.id == root.id)
    #expect(restored.bookmark == root.bookmark)
    #expect(restored.eventCursor == 99)
}

@Test
func journalMigratesVersionOneRowsToReplaceWithBackupIdempotently() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "journal.sqlite")
    let legacyID = UUID()
    try createVersionOneJournal(at: url, id: legacyID, rootID: UUID())

    let store = try JournalStore(url: url)
    let migrated = try #require(try await store.job(id: legacyID))
    #expect(migrated.conversionBehavior == .replaceWithBackup)
    #expect(try sqliteUserVersion(at: url) == 3)

    let reopenedStore = try JournalStore(url: url)
    let reopened = try #require(try await reopenedStore.job(id: legacyID))
    #expect(reopened.conversionBehavior == .replaceWithBackup)
    #expect(try sqliteUserVersion(at: url) == 3)
}

@Test
func journalPersistsExplicitConversionBehavior() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try JournalStore(url: directory.appending(path: "journal.sqlite"))
    let keepOriginal = journalJob(state: .succeeded, conversionBehavior: .keepOriginal)
    let replaceWithBackup = journalJob(state: .succeeded, hash: Data([2]), conversionBehavior: .replaceWithBackup)

    try await store.insert(keepOriginal)
    try await store.insert(replaceWithBackup)

    #expect(try await store.job(id: keepOriginal.id)?.conversionBehavior == .keepOriginal)
    #expect(try await store.job(id: replaceWithBackup.id)?.conversionBehavior == .replaceWithBackup)
}

@Test
func journalRejectsUnknownOrNullPersistedConversionBehavior() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let unknownURL = directory.appending(path: "unknown.sqlite")
    let unknownStore = try JournalStore(url: unknownURL)
    let unknownJob = journalJob(state: .succeeded)
    try await unknownStore.insert(unknownJob)
    try executeSQLite(at: unknownURL, sql: "UPDATE conversion_job SET conversion_behavior='unexpected' WHERE id='\(unknownJob.id.uuidString)';")
    await #expect(throws: JournalError.corruptRow) {
        try await unknownStore.job(id: unknownJob.id)
    }

    let nullURL = directory.appending(path: "null.sqlite")
    let nullJobID = UUID()
    try createVersionOneJournal(at: nullURL, id: nullJobID, rootID: UUID(), version: 2)
    let nullStore = try JournalStore(url: nullURL)
    await #expect(throws: JournalError.corruptRow) {
        try await nullStore.job(id: nullJobID)
    }
}

@Test
func journalMigratesVersionTwoRecoveryRowsWithoutResolvingThem() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "journal.sqlite")
    let jobID = UUID()
    try createVersionOneJournal(
        at: url,
        id: jobID,
        rootID: UUID(),
        version: 2,
        conversionBehavior: ConversionBehavior.replaceWithBackup.rawValue,
        state: PersistentJobState.needsRecovery.rawValue
    )

    let store = try JournalStore(url: url)

    #expect(try sqliteUserVersion(at: url) == 3)
    #expect(try await store.recoveryResolution(jobID: jobID) == nil)
    #expect(try await store.unresolvedRecoveryJobs().map(\.id) == [jobID])
}

@Test
func recoveryResolutionIsAppendOnlyAndRestrictedToEligibleJobs() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try JournalStore(url: directory.appending(path: "journal.sqlite"))
    let eligible = journalJob(state: .needsRecovery, hash: Data([11]))
    let successful = journalJob(state: .succeeded, hash: Data([12]))
    let keepOriginal = journalJob(state: .needsRecovery, hash: Data([13]), conversionBehavior: .keepOriginal)
    try await store.insert(eligible)
    try await store.insert(successful)
    try await store.insert(keepOriginal)
    let resolution = RecoveryResolutionRecord(
        jobID: eligible.id,
        method: .restored,
        destinationFilename: "a — Recovered.txt",
        resolvedAt: Date(timeIntervalSince1970: 100)
    )

    try await store.resolveRecovery(resolution)

    #expect(try await store.recoveryResolution(jobID: eligible.id) == resolution)
    #expect(try await store.unresolvedRecoveryJobs().isEmpty)
    await #expect(throws: JournalError.invalidTransition) {
        try await store.resolveRecovery(resolution)
    }
    await #expect(throws: JournalError.invalidTransition) {
        try await store.resolveRecovery(
            RecoveryResolutionRecord(jobID: successful.id, method: .acknowledged, destinationFilename: nil, resolvedAt: Date())
        )
    }
    await #expect(throws: JournalError.invalidTransition) {
        try await store.resolveRecovery(
            RecoveryResolutionRecord(jobID: keepOriginal.id, method: .acknowledged, destinationFilename: nil, resolvedAt: Date())
        )
    }
}

@Test
func recoveryResolutionEnforcesMethodFilenameContract() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try JournalStore(url: directory.appending(path: "journal.sqlite"))
    let first = journalJob(state: .needsRecovery, hash: Data([21]))
    let second = journalJob(state: .needsRecovery, hash: Data([22]))
    try await store.insert(first)
    try await store.insert(second)

    await #expect(throws: JournalError.invalidTransition) {
        try await store.resolveRecovery(
            RecoveryResolutionRecord(jobID: first.id, method: .restored, destinationFilename: nil, resolvedAt: Date())
        )
    }
    await #expect(throws: JournalError.invalidTransition) {
        try await store.resolveRecovery(
            RecoveryResolutionRecord(jobID: second.id, method: .acknowledged, destinationFilename: "should-not-persist.txt", resolvedAt: Date())
        )
    }
}

@Test
func unresolvedRecoveryBackupsAreProtectedUntilResolution() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try JournalStore(url: directory.appending(path: "journal.sqlite"))
    let now = Date()
    let unresolved = journalJob(state: .needsRecovery, hash: Data([31]))
    let resolved = journalJob(state: .needsRecovery, hash: Data([32]))
    try await store.insert(unresolved)
    try await store.insert(resolved)
    try await store.insertBackup(
        BackupRecord(jobID: unresolved.id, relativeStoragePath: "unresolved", byteCount: 10, sha256: Data([31]), metadata: Data(), expiresAt: now.addingTimeInterval(-60))
    )
    try await store.insertBackup(
        BackupRecord(jobID: resolved.id, relativeStoragePath: "resolved", byteCount: 10, sha256: Data([32]), metadata: Data(), expiresAt: now.addingTimeInterval(-60))
    )
    try await store.resolveRecovery(
        RecoveryResolutionRecord(jobID: resolved.id, method: .acknowledged, destinationFilename: nil, resolvedAt: now)
    )

    let prunable = try await store.prunableBackups(now: now, byteLimit: 0)

    #expect(prunable.map(\.jobID) == [resolved.id])
}

@Test
func clearHistoryPreservesOnlyUnresolvedRecoveryJobs() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try JournalStore(url: directory.appending(path: "journal.sqlite"))
    let unresolved = journalJob(state: .needsRecovery, hash: Data([41]))
    let resolved = journalJob(state: .needsRecovery, hash: Data([42]))
    let succeeded = journalJob(state: .succeeded, hash: Data([43]))
    try await store.insert(unresolved)
    try await store.insert(resolved)
    try await store.insert(succeeded)
    for job in [unresolved, resolved, succeeded] {
        try await store.insertBackup(
            BackupRecord(jobID: job.id, relativeStoragePath: job.id.uuidString, byteCount: 1, sha256: job.sourceHash!, metadata: Data(), expiresAt: Date())
        )
    }
    try await store.resolveRecovery(
        RecoveryResolutionRecord(jobID: resolved.id, method: .restored, destinationFilename: "restored.txt", resolvedAt: Date())
    )

    #expect(Set(try await store.clearableHistoryJobIDs()) == Set([resolved.id, succeeded.id]))
    try await store.clearHistory()

    #expect(try await store.job(id: unresolved.id) != nil)
    #expect(try await store.backup(jobID: unresolved.id) != nil)
    #expect(try await store.job(id: resolved.id) == nil)
    #expect(try await store.backup(jobID: resolved.id) == nil)
    #expect(try await store.job(id: succeeded.id) == nil)
}
