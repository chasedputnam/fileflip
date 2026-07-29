import FileConvertCore
import Foundation
import Testing

private final class TestBookmarking: SecurityScopedBookmarking, @unchecked Sendable {
    private let lock = NSLock()
    private var staleBookmarks: Set<String> = []
    private var deniedURLs: Set<String> = []
    private var startedURLs: [String] = []
    private var stoppedURLs: [String] = []
    private let volume = UUID()
    private var volumes: [String: UUID] = [:]

    func makeBookmark(for url: URL) throws -> Data { Data(url.path.utf8) }
    func resolveBookmark(_ bookmark: Data) throws -> BookmarkResolution {
        let path = String(decoding: bookmark, as: UTF8.self)
        return BookmarkResolution(url: URL(fileURLWithPath: path), isStale: staleBookmarks.contains(path))
    }
    func startAccessing(_ url: URL) -> Bool {
        lock.withLock {
            guard !deniedURLs.contains(url.path) else { return false }
            startedURLs.append(url.path)
            return true
        }
    }
    func stopAccessing(_ url: URL) { lock.withLock { stoppedURLs.append(url.path) } }
    func canonicalURL(for url: URL) throws -> URL { url.standardizedFileURL }
    func volumeUUID(for url: URL) throws -> UUID { lock.withLock { volumes[url.path] ?? volume } }
    func isDirectory(_ url: URL) -> Bool { true }

    func markStale(_ url: URL) { lock.withLock { staleBookmarks.insert(url.path) } }
    func deny(_ url: URL) { lock.withLock { deniedURLs.insert(url.path) } }
    func setVolume(_ volume: UUID, for url: URL) { lock.withLock { volumes[url.path] = volume } }
    func accessCounts() -> (started: Int, stopped: Int) { lock.withLock { (startedURLs.count, stoppedURLs.count) } }
}

private final class RootRecordingSource: RenameEventSource, @unchecked Sendable {
    private let lock = NSLock()
    private var rootCalls: [[AuthorizedRoot]] = []

    func events(for roots: [AuthorizedRoot]) -> AsyncThrowingStream<FileEvent, Error> {
        lock.withLock { rootCalls.append(roots) }
        return AsyncThrowingStream { continuation in continuation.finish() }
    }

    func calls() -> [[AuthorizedRoot]] { lock.withLock { rootCalls } }
}

private func waitForRootSource(_ source: RootRecordingSource, callCount: Int) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(1))
    while source.calls().count < callCount, clock.now < deadline {
        try await clock.sleep(for: .milliseconds(10))
    }
}

private func authorizationStore() throws -> (JournalStore, URL) {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return (try JournalStore(url: directory.appending(path: "journal.sqlite")), directory)
}

@Test
func authorizationStartsOnlyExplicitRootsAndBalancesRemovalAccess() async throws {
    let (journal, directory) = try authorizationStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let bookmarks = TestBookmarking()
    let authorization = RootAuthorizationService(journal: journal, bookmarks: bookmarks)
    let rootURL = URL(fileURLWithPath: "/Volumes/Authorized")

    #expect(await authorization.monitorableRoots().isEmpty)
    let roots = try await authorization.authorize([rootURL])
    #expect(roots.count == 1)
    #expect(await authorization.monitorableRoots().map(\.url) == [rootURL])

    try await authorization.remove(id: roots[0].id)
    #expect(await authorization.monitorableRoots().isEmpty)
    let counts = bookmarks.accessCounts()
    #expect(counts.started == 1)
    #expect(counts.stopped == 1)
}

@Test
func staleAndDeniedBookmarksFailClosedPerRootOnRestore() async throws {
    let (journal, directory) = try authorizationStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let bookmarks = TestBookmarking()
    let staleURL = URL(fileURLWithPath: "/Volumes/Stale")
    let deniedURL = URL(fileURLWithPath: "/Volumes/Denied")
    let activeURL = URL(fileURLWithPath: "/Volumes/Active")
    let volume = try bookmarks.volumeUUID(for: activeURL)
    for url in [staleURL, deniedURL, activeURL] {
        try await journal.upsertAuthorizedRoot(AuthorizedRootRecord(id: UUID(), bookmark: Data(url.path.utf8), displayPath: url.path, volumeUUID: volume, enabled: true, eventCursor: 0, status: AuthorizedRootStatus.active.rawValue))
    }
    bookmarks.markStale(staleURL)
    bookmarks.deny(deniedURL)

    let authorization = RootAuthorizationService(journal: journal, bookmarks: bookmarks)
    let restored = try await authorization.restore()
    #expect(restored.first(where: { $0.url == staleURL })?.status == .staleBookmark)
    #expect(restored.first(where: { $0.url == deniedURL })?.status == .permissionLost)
    #expect(await authorization.monitorableRoots().map(\.url) == [activeURL])
}

@Test
func authorizingParentNormalizesNestedRootButNotCaseDistinctRoot() async throws {
    let (journal, directory) = try authorizationStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let authorization = RootAuthorizationService(journal: journal, bookmarks: TestBookmarking())
    let nested = URL(fileURLWithPath: "/Volumes/Work/Child")
    let parent = URL(fileURLWithPath: "/Volumes/Work")
    let caseDistinct = URL(fileURLWithPath: "/Volumes/work")

    _ = try await authorization.authorize([nested])
    _ = try await authorization.authorize([parent])
    #expect(await authorization.allRoots().map(\.url) == [parent])

    _ = try await authorization.authorize([caseDistinct])
    #expect(Set(await authorization.allRoots().map(\.url)) == Set([parent, caseDistinct]))
}

@Test
func disabledRootStopsAccessAndReauthorizationRestoresIt() async throws {
    let (journal, directory) = try authorizationStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let bookmarks = TestBookmarking()
    let authorization = RootAuthorizationService(journal: journal, bookmarks: bookmarks)
    let root = try #require(try await authorization.authorize([URL(fileURLWithPath: "/Volumes/Work")]).first)

    try await authorization.setEnabled(id: root.id, enabled: false)
    #expect(await authorization.monitorableRoots().isEmpty)
    _ = try await authorization.reAuthorize(id: root.id, with: URL(fileURLWithPath: "/Volumes/NewWork"))
    #expect(await authorization.monitorableRoots().map(\.url) == [URL(fileURLWithPath: "/Volumes/NewWork")])
    let counts = bookmarks.accessCounts()
    #expect(counts.started == counts.stopped + 1)
}

@Test
func replacedVolumeStopsTheAffectedRootDuringRestartRestore() async throws {
    let (journal, directory) = try authorizationStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let bookmarks = TestBookmarking()
    let rootURL = URL(fileURLWithPath: "/Volumes/Removable")
    let expectedVolume = try bookmarks.volumeUUID(for: rootURL)
    try await journal.upsertAuthorizedRoot(AuthorizedRootRecord(id: UUID(), bookmark: Data(rootURL.path.utf8), displayPath: rootURL.path, volumeUUID: expectedVolume, enabled: true, eventCursor: 0, status: AuthorizedRootStatus.active.rawValue))
    bookmarks.setVolume(UUID(), for: rootURL)

    let authorization = RootAuthorizationService(journal: journal, bookmarks: bookmarks)
    let restored = try await authorization.restore()
    #expect(restored.first?.status == .permissionLost)
    #expect(await authorization.monitorableRoots().isEmpty)
    let counts = bookmarks.accessCounts()
    #expect(counts.started == counts.stopped)
}

@Test
func restartRestoresOnlyAuthorizedRootAtItsPersistedCursor() async throws {
    let (journal, directory) = try authorizationStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let bookmarks = TestBookmarking()
    let rootURL = URL(fileURLWithPath: "/Volumes/Restartable")
    let volume = try bookmarks.volumeUUID(for: rootURL)
    let rootID = UUID()
    try await journal.upsertAuthorizedRoot(AuthorizedRootRecord(id: rootID, bookmark: Data(rootURL.path.utf8), displayPath: rootURL.path, volumeUUID: volume, enabled: true, eventCursor: 91, status: AuthorizedRootStatus.active.rawValue))
    let authorization = RootAuthorizationService(journal: journal, bookmarks: bookmarks)
    let source = RootRecordingSource()
    let pipeline = RenamePipeline(roots: [], cursorStore: journal) { _ in Issue.record("No event should replay") }
    let controller = RootMonitoringController(authorization: authorization, pipeline: pipeline, source: source)

    try await controller.restoreAndStart()
    try await waitForRootSource(source, callCount: 1)
    #expect(source.calls().first == [AuthorizedRoot(id: rootID, url: rootURL, volumeUUID: volume, enabled: true, eventCursor: 91, status: .active)])
}

@Test
func removingRootStopsPipelineAndReleasesBookmarkAccess() async throws {
    let (journal, directory) = try authorizationStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let bookmarks = TestBookmarking()
    let authorization = RootAuthorizationService(journal: journal, bookmarks: bookmarks)
    let source = RootRecordingSource()
    let pipeline = RenamePipeline(roots: [], cursorStore: journal) { _ in Issue.record("Removed root must not convert") }
    let controller = RootMonitoringController(authorization: authorization, pipeline: pipeline, source: source)
    let root = try #require(try await authorization.authorize([URL(fileURLWithPath: "/Volumes/Remove")]).first)

    try await controller.restoreAndStart()
    try await waitForRootSource(source, callCount: 1)
    try await controller.remove(id: root.id)
    try await waitForRootSource(source, callCount: 2)
    #expect(source.calls().last?.isEmpty == true)
    let counts = bookmarks.accessCounts()
    #expect(counts.started == counts.stopped)
}
