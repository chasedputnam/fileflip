import Foundation
import SQLite3

public enum PersistentJobState: String, Codable, CaseIterable, Sendable {
    case discovered, stabilizing, staged, backedUp, converting, validating, readyToCommit, committing
    case publishingOriginal, publishingConverted
    case succeeded, skipped, failed, cancelled, needsRecovery

    public var isTerminal: Bool {
        switch self {
        case .succeeded, .skipped, .failed, .cancelled: true
        default: false
        }
    }
}

public struct AuthorizedRootRecord: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let bookmark: Data
    public let displayPath: String
    public let volumeUUID: UUID
    public let enabled: Bool
    public let eventCursor: UInt64
    public let status: String

    public init(id: UUID, bookmark: Data, displayPath: String, volumeUUID: UUID, enabled: Bool, eventCursor: UInt64, status: String) {
        self.id = id; self.bookmark = bookmark; self.displayPath = displayPath; self.volumeUUID = volumeUUID
        self.enabled = enabled; self.eventCursor = eventCursor; self.status = status
    }
}

public struct JournalJob: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let rootID: UUID
    public let fileKey: String
    public let oldRelativePath: String
    public let newRelativePath: String
    public let sourceFormat: String?
    public let targetFormat: String
    public let providerID: String?
    public let providerVersion: String?
    public let policyJSON: Data?
    public let sourceHash: Data?
    public let outputHash: Data?
    public let state: PersistentJobState
    public let conversionBehavior: ConversionBehavior
    public let createdAt: Date
    public let updatedAt: Date
    public let errorCode: String?
    public let errorDetail: String?

    public init(id: UUID, rootID: UUID, fileKey: String, oldRelativePath: String, newRelativePath: String, sourceFormat: String?, targetFormat: String, providerID: String?, providerVersion: String?, policyJSON: Data?, sourceHash: Data?, outputHash: Data?, state: PersistentJobState, conversionBehavior: ConversionBehavior, createdAt: Date, updatedAt: Date, errorCode: String?, errorDetail: String?) {
        self.id = id; self.rootID = rootID; self.fileKey = fileKey
        self.oldRelativePath = oldRelativePath; self.newRelativePath = newRelativePath
        self.sourceFormat = sourceFormat; self.targetFormat = targetFormat
        self.providerID = providerID; self.providerVersion = providerVersion
        self.policyJSON = policyJSON; self.sourceHash = sourceHash; self.outputHash = outputHash
        self.state = state; self.conversionBehavior = conversionBehavior
        self.createdAt = createdAt; self.updatedAt = updatedAt
        self.errorCode = errorCode; self.errorDetail = errorDetail
    }
}

public struct BackupRecord: Hashable, Codable, Sendable {
    public let jobID: UUID
    public let relativeStoragePath: String
    public let byteCount: UInt64
    public let sha256: Data
    public let metadata: Data
    public let expiresAt: Date

    public init(jobID: UUID, relativeStoragePath: String, byteCount: UInt64, sha256: Data, metadata: Data, expiresAt: Date) {
        self.jobID = jobID; self.relativeStoragePath = relativeStoragePath; self.byteCount = byteCount
        self.sha256 = sha256; self.metadata = metadata; self.expiresAt = expiresAt
    }
}

public enum RecoveryResolutionMethod: String, Codable, Sendable {
    case restored
    case acknowledged
}

public struct RecoveryResolutionRecord: Hashable, Codable, Sendable {
    public let jobID: UUID
    public let method: RecoveryResolutionMethod
    public let destinationFilename: String?
    public let resolvedAt: Date

    public init(jobID: UUID, method: RecoveryResolutionMethod, destinationFilename: String?, resolvedAt: Date) {
        self.jobID = jobID
        self.method = method
        self.destinationFilename = destinationFilename
        self.resolvedAt = resolvedAt
    }
}



public actor JournalStore {
    nonisolated(unsafe) private var database: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static let jobProjection = """
    id, root_id, file_key, old_relative_path, new_relative_path, source_format, target_format,
    provider_id, provider_version, policy_json, source_hash, output_hash, state, created_at,
    updated_at, error_code, error_detail, conversion_behavior
    """

    public init(url: URL) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw JournalError.openFailed
        }
        database = handle
        try Self.execute(handle, sql: "PRAGMA journal_mode=WAL;")
        try Self.execute(handle, sql: "PRAGMA synchronous=FULL;")
        try Self.execute(handle, sql: "PRAGMA foreign_keys=ON;")
        try Self.migrate(handle)
    }

    deinit { sqlite3_close(database) }

    public func upsertAuthorizedRoot(_ root: AuthorizedRootRecord) throws {
        let sql = """
        INSERT INTO authorized_root (id, bookmark, display_path, volume_uuid, enabled, event_cursor, status)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET bookmark=excluded.bookmark, display_path=excluded.display_path,
          volume_uuid=excluded.volume_uuid, enabled=excluded.enabled, event_cursor=excluded.event_cursor, status=excluded.status;
        """
        try withStatement(sql) { statement in
            bind(root.id.uuidString, 1, statement); bind(root.bookmark, 2, statement); bind(root.displayPath, 3, statement)
            bind(root.volumeUUID.uuidString, 4, statement); bind(root.enabled ? Int64(1) : Int64(0), 5, statement)
            bind(Int64(bitPattern: root.eventCursor), 6, statement); bind(root.status, 7, statement)
            try stepDone(statement)
        }
    }

    public func persistEventCursor(rootID: UUID, eventID: UInt64) throws {
        try withStatement("UPDATE authorized_root SET event_cursor=? WHERE id=?;") { statement in
            bind(Int64(bitPattern: eventID), 1, statement); bind(rootID.uuidString, 2, statement)
            try stepDone(statement)
            guard sqlite3_changes(database) == 1 else { throw JournalError.missingAuthorizedRoot }
        }
    }

    public func authorizedRoots() throws -> [AuthorizedRootRecord] {
        try withStatement("SELECT id, bookmark, display_path, volume_uuid, enabled, event_cursor, status FROM authorized_root ORDER BY display_path;") { statement in
            var roots: [AuthorizedRootRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let id = UUID(uuidString: text(statement, 0) ?? ""), let bookmark = blob(statement, 1),
                      let displayPath = text(statement, 2), let volumeUUID = UUID(uuidString: text(statement, 3) ?? ""),
                      let status = text(statement, 6) else { throw JournalError.corruptRow }
                roots.append(AuthorizedRootRecord(id: id, bookmark: bookmark, displayPath: displayPath, volumeUUID: volumeUUID, enabled: sqlite3_column_int64(statement, 4) != 0, eventCursor: UInt64(bitPattern: sqlite3_column_int64(statement, 5)), status: status))
            }
            return roots
        }
    }

    public func removeAuthorizedRoot(id: UUID) throws {
        try withStatement("DELETE FROM authorized_root WHERE id=?;") { statement in
            bind(id.uuidString, 1, statement)
            try stepDone(statement)
            guard sqlite3_changes(database) == 1 else { throw JournalError.missingAuthorizedRoot }
        }
    }

    public func insert(_ job: JournalJob) throws {
        let sql = """
        INSERT INTO conversion_job
        (id, root_id, file_key, old_relative_path, new_relative_path, source_format, target_format,
         provider_id, provider_version, policy_json, source_hash, output_hash, state, created_at,
         updated_at, error_code, error_detail, conversion_behavior)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        try withStatement(sql) { statement in
            bind(job.id.uuidString, 1, statement); bind(job.rootID.uuidString, 2, statement)
            bind(job.fileKey, 3, statement); bind(job.oldRelativePath, 4, statement); bind(job.newRelativePath, 5, statement)
            bind(job.sourceFormat, 6, statement); bind(job.targetFormat, 7, statement); bind(job.providerID, 8, statement)
            bind(job.providerVersion, 9, statement); bind(job.policyJSON, 10, statement); bind(job.sourceHash, 11, statement)
            bind(job.outputHash, 12, statement); bind(job.state.rawValue, 13, statement)
            bind(job.createdAt.timeIntervalSince1970, 14, statement); bind(job.updatedAt.timeIntervalSince1970, 15, statement)
            bind(job.errorCode, 16, statement); bind(job.errorDetail.map { String($0.prefix(1024)) }, 17, statement)
            bind(job.conversionBehavior.rawValue, 18, statement)
            try stepDone(statement)
        }
    }

    public func transition(jobID: UUID, from expected: Set<PersistentJobState>, to next: PersistentJobState, sourceHash: Data? = nil, outputHash: Data? = nil, errorCode: String? = nil, errorDetail: String? = nil) throws {
        guard !expected.isEmpty else { throw JournalError.invalidTransition }
        let placeholders = expected.map { _ in "?" }.joined(separator: ",")
        let sql = "UPDATE conversion_job SET state=?, source_hash=COALESCE(?, source_hash), output_hash=COALESCE(?, output_hash), error_code=?, error_detail=?, updated_at=? WHERE id=? AND state IN (\(placeholders));"
        try withStatement(sql) { statement in
            bind(next.rawValue, 1, statement); bind(sourceHash, 2, statement); bind(outputHash, 3, statement)
            bind(errorCode, 4, statement); bind(errorDetail.map { String($0.prefix(1024)) }, 5, statement)
            bind(Date().timeIntervalSince1970, 6, statement); bind(jobID.uuidString, 7, statement)
            for (offset, state) in expected.sorted(by: { $0.rawValue < $1.rawValue }).enumerated() { bind(state.rawValue, Int32(offset + 8), statement) }
            try stepDone(statement)
            guard sqlite3_changes(database) == 1 else { throw JournalError.invalidTransition }
        }
    }

    public func insertBackup(_ backup: BackupRecord) throws {
        let sql = "INSERT INTO backup(job_id, relative_storage_path, byte_count, sha256, metadata, expires_at) VALUES (?, ?, ?, ?, ?, ?);"
        try withStatement(sql) { statement in
            bind(backup.jobID.uuidString, 1, statement); bind(backup.relativeStoragePath, 2, statement)
            sqlite3_bind_int64(statement, 3, sqlite3_int64(backup.byteCount)); bind(backup.sha256, 4, statement)
            bind(backup.metadata, 5, statement); bind(backup.expiresAt.timeIntervalSince1970, 6, statement)
            try stepDone(statement)
        }
    }

    public func nonterminalJobs() throws -> [JournalJob] {
        try queryJobs("SELECT \(Self.jobProjection) FROM conversion_job WHERE state NOT IN ('succeeded','skipped','failed','cancelled') ORDER BY created_at;")
    }

    public func job(id: UUID) throws -> JournalJob? {
        try queryJobs("SELECT \(Self.jobProjection) FROM conversion_job WHERE id=? LIMIT 1;", values: [id.uuidString]).first
    }

    public func backup(jobID: UUID) throws -> BackupRecord? {
        let sql = "SELECT job_id, relative_storage_path, byte_count, sha256, metadata, expires_at FROM backup WHERE job_id=?;"
        return try withStatement(sql) { statement in
            bind(jobID.uuidString, 1, statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return BackupRecord(jobID: jobID, relativeStoragePath: text(statement, 1)!, byteCount: UInt64(sqlite3_column_int64(statement, 2)), sha256: blob(statement, 3)!, metadata: blob(statement, 4)!, expiresAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)))
        }
    }

    public func recoveryResolution(jobID: UUID) throws -> RecoveryResolutionRecord? {
        try withStatement(
            "SELECT method, destination_filename, resolved_at FROM recovery_resolution WHERE job_id=?;"
        ) { statement in
            bind(jobID.uuidString, 1, statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            guard let method = RecoveryResolutionMethod(rawValue: text(statement, 0) ?? "") else {
                throw JournalError.corruptRow
            }
            return RecoveryResolutionRecord(
                jobID: jobID,
                method: method,
                destinationFilename: text(statement, 1),
                resolvedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
            )
        }
    }

    public func resolveRecovery(_ resolution: RecoveryResolutionRecord) throws {
        switch resolution.method {
        case .restored:
            guard let filename = resolution.destinationFilename, !filename.isEmpty else {
                throw JournalError.invalidTransition
            }
        case .acknowledged:
            guard resolution.destinationFilename == nil else {
                throw JournalError.invalidTransition
            }
        }
        let sql = """
        INSERT INTO recovery_resolution (job_id, method, destination_filename, resolved_at)
        SELECT id, ?, ?, ?
        FROM conversion_job
        WHERE id=? AND state='needsRecovery' AND conversion_behavior='replaceWithBackup'
          AND NOT EXISTS (SELECT 1 FROM recovery_resolution WHERE job_id=?);
        """
        try withStatement(sql) { statement in
            bind(resolution.method.rawValue, 1, statement)
            bind(resolution.destinationFilename, 2, statement)
            bind(resolution.resolvedAt.timeIntervalSince1970, 3, statement)
            bind(resolution.jobID.uuidString, 4, statement)
            bind(resolution.jobID.uuidString, 5, statement)
            try stepDone(statement)
            guard sqlite3_changes(database) == 1 else { throw JournalError.invalidTransition }
        }
    }

    public func unresolvedRecoveryJobs() throws -> [JournalJob] {
        try queryJobs(
            """
            SELECT \(Self.jobProjection)
            FROM conversion_job j
            WHERE j.state='needsRecovery'
              AND j.conversion_behavior='replaceWithBackup'
              AND NOT EXISTS (SELECT 1 FROM recovery_resolution r WHERE r.job_id=j.id)
            ORDER BY j.updated_at DESC;
            """
        )
    }

    public func recentHistory(limit: Int = 100) throws -> [JournalJob] {
        let boundedLimit = min(max(limit, 1), 500)
        return try queryJobs(
            """
            SELECT \(Self.jobProjection) FROM conversion_job
            WHERE state IN ('succeeded','skipped','failed','cancelled','needsRecovery')
            ORDER BY updated_at DESC
            LIMIT ?;
            """,
            integerValues: [Int64(boundedLimit)]
        )
    }

    public func backupUsage() throws -> UInt64 {
        try withStatement("SELECT COALESCE(SUM(byte_count), 0) FROM backup;") { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { throw JournalError.corruptRow }
            let value = sqlite3_column_int64(statement, 0)
            guard value >= 0 else { throw JournalError.corruptRow }
            return UInt64(value)
        }
    }

    public func backupsForHistory() throws -> [BackupRecord] {
        let sql = """
        SELECT b.job_id, b.relative_storage_path, b.byte_count, b.sha256, b.metadata, b.expires_at
        FROM backup b JOIN conversion_job j ON j.id=b.job_id
        WHERE j.state IN ('succeeded','skipped','failed','cancelled');
        """
        return try withStatement(sql) { statement in
            var result: [BackupRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let id = UUID(uuidString: text(statement, 0) ?? ""),
                      let path = text(statement, 1),
                      let hash = blob(statement, 3),
                      let metadata = blob(statement, 4) else {
                    throw JournalError.corruptRow
                }
                result.append(
                    BackupRecord(
                        jobID: id,
                        relativeStoragePath: path,
                        byteCount: UInt64(sqlite3_column_int64(statement, 2)),
                        sha256: hash,
                        metadata: metadata,
                        expiresAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
                    )
                )
            }
            return result
        }
    }

    public func clearableHistoryJobIDs() throws -> [UUID] {
        try withStatement(
            """
            SELECT id FROM conversion_job
            WHERE state IN ('succeeded','skipped','failed','cancelled')
               OR (state='needsRecovery' AND EXISTS (
                    SELECT 1 FROM recovery_resolution WHERE job_id=conversion_job.id
               ));
            """
        ) { statement in
            var values: [UUID] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let raw = text(statement, 0), let id = UUID(uuidString: raw) else {
                    throw JournalError.corruptRow
                }
                values.append(id)
            }
            return values
        }
    }

    public func clearHistory() throws {
        try withStatement(
            """
            DELETE FROM conversion_job
            WHERE state IN ('succeeded','skipped','failed','cancelled')
               OR (state='needsRecovery' AND EXISTS (
                    SELECT 1 FROM recovery_resolution WHERE job_id=conversion_job.id
               ));
            """
        ) { statement in
            try stepDone(statement)
        }
    }

    public func removeFailedChoiceJob(jobID: UUID) throws -> Bool {
        try withStatement(
            "DELETE FROM conversion_job WHERE id=? AND state='failed' AND error_code='requiresChoice';"
        ) { statement in
            bind(jobID.uuidString, 1, statement)
            try stepDone(statement)
            return sqlite3_changes(database) == 1
        }
    }

    public func updateBackupExpirations(retentionDays: Int) throws {
        let seconds = TimeInterval(min(max(retentionDays, 1), 365) * 24 * 60 * 60)
        try withStatement(
            "UPDATE backup SET expires_at=(SELECT created_at FROM conversion_job WHERE conversion_job.id=backup.job_id)+?;"
        ) { statement in
            bind(seconds, 1, statement)
            try stepDone(statement)
        }
    }

    public func prunableBackups(now: Date, byteLimit: UInt64) throws -> [BackupRecord] {
        let sql = """
        SELECT b.job_id, b.relative_storage_path, b.byte_count, b.sha256, b.metadata, b.expires_at
        FROM backup b JOIN conversion_job j ON j.id=b.job_id
        WHERE j.state IN ('succeeded','failed','cancelled','skipped')
           OR (j.state='needsRecovery' AND EXISTS (
                SELECT 1 FROM recovery_resolution r WHERE r.job_id=j.id
           ))
        ORDER BY b.expires_at, j.created_at;
        """
        let rows: [BackupRecord] = try withStatement(sql) { statement in
            var result: [BackupRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let id = UUID(uuidString: text(statement, 0) ?? ""), let path = text(statement, 1), let hash = blob(statement, 3), let metadata = blob(statement, 4) else { throw JournalError.corruptRow }
                result.append(BackupRecord(jobID: id, relativeStoragePath: path, byteCount: UInt64(sqlite3_column_int64(statement, 2)), sha256: hash, metadata: metadata, expiresAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))))
            }
            return result
        }
        var retained = rows.reduce(UInt64(0)) { $0 + $1.byteCount }
        var prune: [BackupRecord] = []
        for row in rows where row.expiresAt <= now || retained > byteLimit {
            prune.append(row)
            retained -= row.byteCount
        }
        return prune
    }

    public func removeBackup(jobID: UUID) throws {
        try withStatement("DELETE FROM backup WHERE job_id=?;") { statement in bind(jobID.uuidString, 1, statement); try stepDone(statement) }
    }

    private func queryJobs(_ sql: String, values: [String] = []) throws -> [JournalJob] {
        try withStatement(sql) { statement in
            for (index, value) in values.enumerated() { bind(value, Int32(index + 1), statement) }
            var jobs: [JournalJob] = []
            while sqlite3_step(statement) == SQLITE_ROW { jobs.append(try decodeJob(statement)) }
            return jobs
        }
    }

    private func queryJobs(_ sql: String, integerValues: [Int64]) throws -> [JournalJob] {
        try withStatement(sql) { statement in
            for (index, value) in integerValues.enumerated() {
                bind(value, Int32(index + 1), statement)
            }
            var jobs: [JournalJob] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                jobs.append(try decodeJob(statement))
            }
            return jobs
        }
    }

    private func decodeJob(_ statement: OpaquePointer) throws -> JournalJob {
        guard let id = UUID(uuidString: text(statement, 0) ?? ""),
              let rootID = UUID(uuidString: text(statement, 1) ?? ""),
              let state = PersistentJobState(rawValue: text(statement, 12) ?? ""),
              let conversionBehavior = ConversionBehavior(rawValue: text(statement, 17) ?? ""),
              let fileKey = text(statement, 2),
              let oldRelativePath = text(statement, 3),
              let newRelativePath = text(statement, 4),
              let targetFormat = text(statement, 6) else {
            throw JournalError.corruptRow
        }
        return JournalJob(id: id, rootID: rootID, fileKey: fileKey, oldRelativePath: oldRelativePath, newRelativePath: newRelativePath, sourceFormat: text(statement, 5), targetFormat: targetFormat, providerID: text(statement, 7), providerVersion: text(statement, 8), policyJSON: blob(statement, 9), sourceHash: blob(statement, 10), outputHash: blob(statement, 11), state: state, conversionBehavior: conversionBehavior, createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 13)), updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 14)), errorCode: text(statement, 15), errorDetail: text(statement, 16))
    }

    private func withStatement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        guard let database else { throw JournalError.closed }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw JournalError.sql(message: String(cString: sqlite3_errmsg(database))) }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw JournalError.sql(message: String(cString: sqlite3_errmsg(database))) }
    }

    private func bind(_ value: String?, _ index: Int32, _ statement: OpaquePointer) {
        if let value { _ = sqlite3_bind_text(statement, index, value, -1, transient) }
        else { _ = sqlite3_bind_null(statement, index) }
    }
    private func bind(_ value: Data?, _ index: Int32, _ statement: OpaquePointer) {
        guard let value else { _ = sqlite3_bind_null(statement, index); return }
        if value.isEmpty { _ = sqlite3_bind_zeroblob(statement, index, 0) }
        else { _ = value.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient) } }
    }
    private func bind(_ value: Double, _ index: Int32, _ statement: OpaquePointer) { _ = sqlite3_bind_double(statement, index, value) }
    private func bind(_ value: Int64, _ index: Int32, _ statement: OpaquePointer) { _ = sqlite3_bind_int64(statement, index, value) }
    private func text(_ statement: OpaquePointer, _ index: Int32) -> String? { sqlite3_column_text(statement, index).map { String(cString: $0) } }
    private func blob(_ statement: OpaquePointer, _ index: Int32) -> Data? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0, let bytes = sqlite3_column_blob(statement, index) else { return Data() }
        return Data(bytes: bytes, count: count)
    }

    private static func execute(_ database: OpaquePointer, sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "Unknown SQLite error"
            sqlite3_free(error)
            throw JournalError.sql(message: message)
        }
    }

    private static func migrate(_ database: OpaquePointer) throws {
        var version = try userVersion(database)
        guard version <= 3 else {
            throw JournalError.sql(message: "Unsupported journal schema version \(version)")
        }

        if version == 0 {
            try migrateToVersion1(database)
            version = 1
        }
        if version == 1 {
            try migrateToVersion2(database)
            version = 2
        }
        if version == 2 {
            try migrateToVersion3(database)
            version = 3
        }
        guard version == 3 else {
            throw JournalError.sql(message: "Unsupported journal schema version \(version)")
        }
    }

    private static func userVersion(_ database: OpaquePointer) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA user_version;", -1, &statement, nil) == SQLITE_OK, let statement else {
            throw JournalError.sql(message: String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw JournalError.sql(message: "Missing journal schema version")
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private static func migrateToVersion1(_ database: OpaquePointer) throws {
        try execute(database, sql: "BEGIN IMMEDIATE;")
        do {
            try execute(database, sql: """
            CREATE TABLE IF NOT EXISTS authorized_root (
              id TEXT PRIMARY KEY, bookmark BLOB NOT NULL, display_path TEXT NOT NULL, volume_uuid TEXT NOT NULL,
              enabled INTEGER NOT NULL, event_cursor INTEGER NOT NULL DEFAULT 0, status TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS conversion_job (
              id TEXT PRIMARY KEY, root_id TEXT NOT NULL, file_key TEXT NOT NULL,
              old_relative_path TEXT NOT NULL, new_relative_path TEXT NOT NULL,
              source_format TEXT, target_format TEXT NOT NULL, provider_id TEXT, provider_version TEXT,
              policy_json BLOB, source_hash BLOB, output_hash BLOB, state TEXT NOT NULL,
              created_at REAL NOT NULL, updated_at REAL NOT NULL, error_code TEXT, error_detail TEXT
            );
            CREATE TABLE IF NOT EXISTS backup (
              job_id TEXT PRIMARY KEY REFERENCES conversion_job(id) ON DELETE CASCADE,
              relative_storage_path TEXT NOT NULL, byte_count INTEGER NOT NULL, sha256 BLOB NOT NULL,
              metadata BLOB NOT NULL, expires_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS provider_installation (
              provider_id TEXT PRIMARY KEY, executable_identity TEXT NOT NULL, version TEXT NOT NULL,
              signature_result TEXT NOT NULL, build_configuration_hash BLOB NOT NULL,
              capability_set_hash BLOB NOT NULL, self_test_outcome TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS preference (key TEXT PRIMARY KEY, version INTEGER NOT NULL, value BLOB NOT NULL);
            CREATE UNIQUE INDEX IF NOT EXISTS terminal_job_dedup
              ON conversion_job(file_key, target_format, source_hash)
              WHERE source_hash IS NOT NULL AND state IN ('succeeded','skipped','failed','cancelled');
            PRAGMA user_version=1;
            """)
            try execute(database, sql: "COMMIT;")
        } catch {
            try? execute(database, sql: "ROLLBACK;")
            throw error
        }
    }

    private static func migrateToVersion2(_ database: OpaquePointer) throws {
        try execute(database, sql: "BEGIN IMMEDIATE;")
        do {
            try execute(database, sql: """
            ALTER TABLE conversion_job
            ADD COLUMN conversion_behavior TEXT NOT NULL DEFAULT 'replaceWithBackup';
            UPDATE conversion_job
            SET conversion_behavior='replaceWithBackup'
            WHERE conversion_behavior IS NULL;
            PRAGMA user_version=2;
            """)
            try execute(database, sql: "COMMIT;")
        } catch {
            try? execute(database, sql: "ROLLBACK;")
            throw error
        }
    }

    private static func migrateToVersion3(_ database: OpaquePointer) throws {
        try execute(database, sql: "BEGIN IMMEDIATE;")
        do {
            try execute(database, sql: """
            CREATE TABLE recovery_resolution (
              job_id TEXT PRIMARY KEY REFERENCES conversion_job(id) ON DELETE CASCADE,
              method TEXT NOT NULL CHECK (method IN ('restored', 'acknowledged')),
              destination_filename TEXT,
              resolved_at REAL NOT NULL,
              CHECK (
                (method = 'restored' AND destination_filename IS NOT NULL)
                OR (method = 'acknowledged' AND destination_filename IS NULL)
              )
            );
            PRAGMA user_version=3;
            """)
            try execute(database, sql: "COMMIT;")
        } catch {
            try? execute(database, sql: "ROLLBACK;")
            throw error
        }
    }
}

public enum JournalError: Error, Equatable, Sendable {
    case openFailed, closed, corruptRow, invalidTransition
    case missingAuthorizedRoot, cursorOverflow
    case sql(message: String)
}
