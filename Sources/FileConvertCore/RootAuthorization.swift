import CoreServices
import Foundation
import ServiceManagement

public enum RootAuthorizationError: Error, Sendable, Equatable {
    case notDirectory
    case unavailable
    case staleBookmark
    case permissionDenied
    case volumeChanged
    case missingRoot
}

public struct BookmarkResolution: Sendable {
    public let url: URL
    public let isStale: Bool

    public init(url: URL, isStale: Bool) {
        self.url = url
        self.isStale = isStale
    }
}

public protocol SecurityScopedBookmarking: Sendable {
    func makeBookmark(for url: URL) throws -> Data
    func resolveBookmark(_ bookmark: Data) throws -> BookmarkResolution
    func startAccessing(_ url: URL) -> Bool
    func stopAccessing(_ url: URL)
    func canonicalURL(for url: URL) throws -> URL
    func volumeUUID(for url: URL) throws -> UUID
    func isDirectory(_ url: URL) -> Bool
}

public struct SystemSecurityScopedBookmarking: SecurityScopedBookmarking, @unchecked Sendable {
    public init() {}

    public func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    public func resolveBookmark(_ bookmark: Data) throws -> BookmarkResolution {
        var stale = false
        let url = try URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        return BookmarkResolution(url: url, isStale: stale)
    }

    public func startAccessing(_ url: URL) -> Bool { url.startAccessingSecurityScopedResource() }
    public func stopAccessing(_ url: URL) { url.stopAccessingSecurityScopedResource() }
    public func canonicalURL(for url: URL) throws -> URL {
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        guard FileManager.default.fileExists(atPath: canonical.path) else { throw RootAuthorizationError.unavailable }
        return canonical
    }

    public func volumeUUID(for url: URL) throws -> UUID {
        guard let raw = try url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString,
              let volumeUUID = UUID(uuidString: raw) else {
            throw RootAuthorizationError.unavailable
        }
        return volumeUUID
    }

    public func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}

public actor RootAuthorizationService {
    private let journal: JournalStore
    private let bookmarks: any SecurityScopedBookmarking
    private var roots: [UUID: AuthorizedRoot] = [:]
    private var retainedAccess: [UUID: URL] = [:]

    public init(journal: JournalStore, bookmarks: any SecurityScopedBookmarking = SystemSecurityScopedBookmarking()) {
        self.journal = journal
        self.bookmarks = bookmarks
    }

    deinit {
        for url in retainedAccess.values { bookmarks.stopAccessing(url) }
    }

    @discardableResult
    public func restore() async throws -> [AuthorizedRoot] {
        releaseAllAccess()
        roots.removeAll()
        for record in try await journal.authorizedRoots() {
            let restored = try await restore(record)
            roots[restored.id] = restored
        }
        return allRoots()
    }

    @discardableResult
    public func authorize(_ selectedURLs: [URL]) async throws -> [AuthorizedRoot] {
        for selectedURL in selectedURLs {
            let canonical = try validatedDirectory(selectedURL)
            if roots.values.contains(where: { Self.samePath($0.url, canonical) || Self.contains(canonical, in: $0.url) }) {
                continue
            }

            let nestedIDs = roots.values.filter { Self.contains($0.url, in: canonical) }.map(\.id)
            let bookmark = try bookmarks.makeBookmark(for: selectedURL)
            guard bookmarks.startAccessing(selectedURL) else { throw RootAuthorizationError.permissionDenied }
            do {
                let scopedCanonical = try validatedDirectory(selectedURL)
                let root = AuthorizedRoot(
                    url: scopedCanonical,
                    volumeUUID: try bookmarks.volumeUUID(for: scopedCanonical),
                    enabled: true,
                    eventCursor: UInt64(kFSEventStreamEventIdSinceNow),
                    status: .active
                )
                try await persist(root, bookmark: bookmark)
                retainedAccess[root.id] = selectedURL
                roots[root.id] = root
                for id in nestedIDs { try? await remove(id: id) }
            } catch {
                bookmarks.stopAccessing(selectedURL)
                throw error
            }
        }
        return allRoots()
    }

    @discardableResult
    public func reAuthorize(id: UUID, with selectedURL: URL) async throws -> AuthorizedRoot {
        guard let previous = roots[id] else { throw RootAuthorizationError.missingRoot }
        let previousBookmark = try await bookmark(for: id)
        let canonical = try validatedDirectory(selectedURL)
        let bookmark = try bookmarks.makeBookmark(for: selectedURL)
        releaseAccess(id: id)
        guard bookmarks.startAccessing(selectedURL) else {
            let failed = AuthorizedRoot(id: previous.id, url: previous.url, volumeUUID: previous.volumeUUID, enabled: false, eventCursor: previous.eventCursor, status: .permissionLost)
            try await persist(failed, bookmark: previousBookmark)
            roots[id] = failed
            throw RootAuthorizationError.permissionDenied
        }
        do {
            let root = AuthorizedRoot(
                id: id,
                url: canonical,
                volumeUUID: try bookmarks.volumeUUID(for: canonical),
                enabled: true,
                eventCursor: UInt64(kFSEventStreamEventIdSinceNow),
                status: .active
            )
            try await persist(root, bookmark: bookmark)
            retainedAccess[id] = selectedURL
            roots[id] = root
            return root
        } catch {
            bookmarks.stopAccessing(selectedURL)
            let failed = AuthorizedRoot(id: previous.id, url: previous.url, volumeUUID: previous.volumeUUID, enabled: false, eventCursor: previous.eventCursor, status: .permissionLost)
            try? await persist(failed, bookmark: previousBookmark)
            roots[id] = failed
            throw error
        }
    }

    public func setEnabled(id: UUID, enabled: Bool) async throws {
        guard let root = roots[id] else { throw RootAuthorizationError.missingRoot }
        if !enabled {
            releaseAccess(id: id)
            let disabled = AuthorizedRoot(id: root.id, url: root.url, volumeUUID: root.volumeUUID, enabled: false, eventCursor: root.eventCursor, status: .disabled)
            try await persist(disabled, bookmark: try bookmark(for: id))
            roots[id] = disabled
            return
        }
        guard root.status != .active else { return }
        guard let record = try await journal.authorizedRoots().first(where: { $0.id == id }) else { throw RootAuthorizationError.missingRoot }
        let restored = try await restore(record, forceEnabled: true)
        roots[id] = restored
    }

    public func remove(id: UUID) async throws {
        releaseAccess(id: id)
        roots[id] = nil
        try await journal.removeAuthorizedRoot(id: id)
    }

    public func allRoots() -> [AuthorizedRoot] {
        roots.values.sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
    }

    public func monitorableRoots() -> [AuthorizedRoot] {
        allRoots().filter { $0.enabled && $0.status == .active && retainedAccess[$0.id] != nil }
    }

    private func restore(_ record: AuthorizedRootRecord, forceEnabled: Bool = false) async throws -> AuthorizedRoot {
        let enabled = forceEnabled || record.enabled
        guard enabled else {
            return AuthorizedRoot(id: record.id, url: URL(fileURLWithPath: record.displayPath), volumeUUID: record.volumeUUID, enabled: false, eventCursor: record.eventCursor, status: .disabled)
        }
        do {
            let resolution = try bookmarks.resolveBookmark(record.bookmark)
            if resolution.isStale {
                return try await persistFailure(record, status: .staleBookmark)
            }
            guard bookmarks.startAccessing(resolution.url) else {
                return try await persistFailure(record, status: .permissionLost)
            }
            do {
                let canonical = try validatedDirectory(resolution.url)
                guard try bookmarks.volumeUUID(for: canonical) == record.volumeUUID else {
                    bookmarks.stopAccessing(resolution.url)
                    return try await persistFailure(record, status: .permissionLost)
                }
                let root = AuthorizedRoot(id: record.id, url: canonical, volumeUUID: record.volumeUUID, enabled: true, eventCursor: record.eventCursor, status: .active)
                retainedAccess[record.id] = resolution.url
                if record.displayPath != canonical.path || record.status != AuthorizedRootStatus.active.rawValue {
                    try await persist(root, bookmark: record.bookmark)
                }
                return root
            } catch {
                bookmarks.stopAccessing(resolution.url)
                return try await persistFailure(record, status: .permissionLost)
            }
        } catch {
            return try await persistFailure(record, status: .permissionLost)
        }
    }

    private func persistFailure(_ record: AuthorizedRootRecord, status: AuthorizedRootStatus) async throws -> AuthorizedRoot {
        let failed = AuthorizedRoot(id: record.id, url: URL(fileURLWithPath: record.displayPath), volumeUUID: record.volumeUUID, enabled: false, eventCursor: record.eventCursor, status: status)
        try await persist(failed, bookmark: record.bookmark)
        return failed
    }

    private func validatedDirectory(_ url: URL) throws -> URL {
        let canonical = try bookmarks.canonicalURL(for: url)
        guard bookmarks.isDirectory(canonical) else { throw RootAuthorizationError.notDirectory }
        return canonical
    }

    private func bookmark(for id: UUID) async throws -> Data {
        guard let record = try await journal.authorizedRoots().first(where: { $0.id == id }) else { throw RootAuthorizationError.missingRoot }
        return record.bookmark
    }

    private func persist(_ root: AuthorizedRoot, bookmark: Data) async throws {
        try await journal.upsertAuthorizedRoot(AuthorizedRootRecord(id: root.id, bookmark: bookmark, displayPath: root.url.path, volumeUUID: root.volumeUUID, enabled: root.enabled, eventCursor: root.eventCursor, status: root.status.rawValue))
    }

    private func releaseAccess(id: UUID) {
        guard let url = retainedAccess.removeValue(forKey: id) else { return }
        bookmarks.stopAccessing(url)
    }

    private func releaseAllAccess() {
        for id in Array(retainedAccess.keys) { releaseAccess(id: id) }
    }

    private static func samePath(_ lhs: URL, _ rhs: URL) -> Bool { lhs.path == rhs.path }

    private static func contains(_ candidate: URL, in root: URL) -> Bool {
        let rootComponents = root.pathComponents
        let candidateComponents = candidate.pathComponents
        return candidateComponents.count > rootComponents.count && candidateComponents.prefix(rootComponents.count).elementsEqual(rootComponents)
    }
}

public actor RootMonitoringController {
    private let authorization: RootAuthorizationService
    private let pipeline: RenamePipeline
    private let source: any RenameEventSource

    public init(authorization: RootAuthorizationService, pipeline: RenamePipeline, source: any RenameEventSource) {
        self.authorization = authorization
        self.pipeline = pipeline
        self.source = source
    }

    public func restoreAndStart() async throws {
        _ = try await authorization.restore()
        await refreshPipeline()
    }

    public func authorize(_ urls: [URL]) async throws {
        await pipeline.stop()
        do {
            _ = try await authorization.authorize(urls)
        } catch {
            await refreshPipeline()
            throw error
        }
        await refreshPipeline()
    }

    public func setEnabled(id: UUID, enabled: Bool) async throws {
        await pipeline.stop()
        do {
            try await authorization.setEnabled(id: id, enabled: enabled)
        } catch {
            await refreshPipeline()
            throw error
        }
        await refreshPipeline()
    }

    public func remove(id: UUID) async throws {
        await pipeline.stop()
        do {
            try await authorization.remove(id: id)
        } catch {
            await refreshPipeline()
            throw error
        }
        await refreshPipeline()
    }

    public func reAuthorize(id: UUID, with url: URL) async throws {
        await pipeline.stop()
        do {
            _ = try await authorization.reAuthorize(id: id, with: url)
        } catch {
            await refreshPipeline()
            throw error
        }
        await refreshPipeline()
    }

    public func stop() async {
        await pipeline.stop()
    }

    public func drainForUpdateInstallationAndWaitForIdle() async {
        await pipeline.drainForInstallationAndWaitForIdle()
    }

    private func refreshPipeline() async {
        let roots = await authorization.monitorableRoots()
        await pipeline.replaceRoots(roots)
        await pipeline.resume(source: source)
    }
}

public enum LaunchAtLoginStatus: Sendable, Equatable {
    case enabled
    case disabled
    case requiresApproval
    case unavailable
}

public protocol LaunchAtLoginControlling: Sendable {
    func status() -> LaunchAtLoginStatus
    func setEnabled(_ enabled: Bool) throws
}

public struct SystemLaunchAtLoginController: LaunchAtLoginControlling, @unchecked Sendable {
    public init() {}

    public func status() -> LaunchAtLoginStatus {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .notRegistered: .disabled
        case .requiresApproval: .requiresApproval
        case .notFound: .unavailable
        @unknown default: .unavailable
        }
    }

    public func setEnabled(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() }
        else { try SMAppService.mainApp.unregister() }
    }
}
