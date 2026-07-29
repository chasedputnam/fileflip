import CoreServices
import FileConvertCore
import Foundation
import Testing

private struct RenameFixture {
    let directory: URL
    let root: AuthorizedRoot
    let fileID: UInt64
    let oldURL: URL
    let newURL: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        oldURL = directory.appending(path: "sample.txt")
        newURL = directory.appending(path: "sample.html")
        try Data("contents".utf8).write(to: newURL)
        let attributes = try FileManager.default.attributesOfItem(atPath: newURL.path)
        fileID = try #require((attributes[.systemFileNumber] as? NSNumber)?.uint64Value)
        root = AuthorizedRoot(url: directory, volumeUUID: UUID())
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    func event(side: FileEventSide, id: UInt64 = 42, flags: UInt32 = UInt32(kFSEventStreamEventFlagItemRenamed)) -> FileEvent {
        FileEvent(rootID: root.id, eventID: id, path: side == .old ? oldURL : newURL, fileID: fileID, flags: flags, side: side)
    }
}

private final class CursorRecordingSource: RenameEventSource, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[AuthorizedRoot]] = []
    private let event: FileEvent

    init(event: FileEvent) { self.event = event }

    func events(for roots: [AuthorizedRoot]) -> AsyncThrowingStream<FileEvent, Error> {
        lock.lock()
        calls.append(roots)
        let callCount = calls.count
        lock.unlock()
        return AsyncThrowingStream { continuation in
            if callCount == 1 { continuation.yield(event) }
            continuation.finish()
        }
    }

    func recordedRoots() -> [[AuthorizedRoot]] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

@Test
func confirmedPairProducesOneCandidateAcrossDuplicateOrders() async throws {
    let fixture = try RenameFixture()
    defer { fixture.remove() }
    let correlator = RenameCorrelator(roots: [fixture.root])
    let sequence = [fixture.event(side: .new), fixture.event(side: .old), fixture.event(side: .new), fixture.event(side: .old)]
    var candidates: [RenameCandidate] = []
    for event in sequence {
        for signal in await correlator.ingest(event) {
            if case let .candidate(candidate) = signal { candidates.append(candidate) }
        }
    }
    #expect(candidates.count == 1)
    #expect(candidates.first?.oldRelativePath == "sample.txt")
    #expect(candidates.first?.newRelativePath == "sample.html")
}

@Test
func identitySnapshotCorrelatesSingleSidedFSEventRename() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let old = directory.appending(path: "single.txt")
    let new = directory.appending(path: "single.html")
    try Data("contents".utf8).write(to: old)
    let fileID = try #require((try FileManager.default.attributesOfItem(atPath: old.path)[.systemFileNumber] as? NSNumber)?.uint64Value)
    let root = AuthorizedRoot(url: directory, volumeUUID: UUID())
    let correlator = RenameCorrelator(roots: [root])
    try FileManager.default.moveItem(at: old, to: new)
    let event = FileEvent(rootID: root.id, eventID: 99, path: new, fileID: fileID, flags: UInt32(kFSEventStreamEventFlagItemRenamed), side: .new)
    let signals = await correlator.ingest(event)
    #expect(signals.count == 1)
    guard let signal = signals.first, case let .candidate(candidate) = signal else { Issue.record("Expected a candidate"); return }
    #expect(candidate.oldRelativePath == "single.txt")
    #expect(candidate.newRelativePath == "single.html")
}

@Test
func generatedDuplicateReorderedSequencesAreExactlyOnce() async throws {
    let fixture = try RenameFixture()
    defer { fixture.remove() }
    for seed in 0..<1_000 {
        let correlator = RenameCorrelator(roots: [fixture.root])
        let old = fixture.event(side: .old, id: UInt64(seed + 1))
        let new = fixture.event(side: .new, id: UInt64(seed + 1))
        let sequence = seed.isMultiple(of: 2) ? [old, new, old, new] : [new, old, new, old]
        var count = 0
        for event in sequence {
            for signal in await correlator.ingest(event) { if case .candidate = signal { count += 1 } }
        }
        #expect(count == 1)
    }
}

@Test
func missingHalfDropAndRemovedRootNeverProduceCandidate() async throws {
    let fixture = try RenameFixture()
    defer { fixture.remove() }
    let correlator = RenameCorrelator(roots: [fixture.root])
    #expect(await correlator.ingest(fixture.event(side: .old)).isEmpty)
    let drop = FileEvent(rootID: fixture.root.id, eventID: 43, path: fixture.directory, fileID: nil, flags: UInt32(kFSEventStreamEventFlagUserDropped), side: .unknown)
    #expect(await correlator.ingest(drop) == [.streamDegraded(rootID: fixture.root.id, cursor: 43)])
    #expect(await correlator.ingest(fixture.event(side: .new)).isEmpty)
    await correlator.replaceRoots([])
    #expect(await correlator.ingest(fixture.event(side: .old, id: 44)).isEmpty)
    #expect(await correlator.ingest(fixture.event(side: .new, id: 44)).isEmpty)
}

@Test
func ordinaryAndUnsafeRenamesAreRejected() async throws {
    let fixture = try RenameFixture()
    defer { fixture.remove() }
    let correlator = RenameCorrelator(roots: [fixture.root])
    let sameExtensionOld = FileEvent(rootID: fixture.root.id, eventID: 50, path: fixture.directory.appending(path: "other.html"), fileID: fixture.fileID, flags: UInt32(kFSEventStreamEventFlagItemRenamed), side: .old)
    #expect(await correlator.ingest(sameExtensionOld).isEmpty)
    #expect(await correlator.ingest(fixture.event(side: .new, id: 50)).isEmpty)

    let hidden = fixture.directory.appending(path: ".sample.html")
    try FileManager.default.moveItem(at: fixture.newURL, to: hidden)
    let hiddenNew = FileEvent(rootID: fixture.root.id, eventID: 51, path: hidden, fileID: fixture.fileID, flags: UInt32(kFSEventStreamEventFlagItemRenamed), side: .new)
    #expect(await correlator.ingest(fixture.event(side: .old, id: 51)).isEmpty)
    #expect(await correlator.ingest(hiddenNew).isEmpty)
}

@Test
func ownSymlinkPackageAndCrossRootEventsAreRejected() async throws {
    let firstDirectory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let secondDirectory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: firstDirectory)
        try? FileManager.default.removeItem(at: secondDirectory)
    }
    let firstRoot = AuthorizedRoot(url: firstDirectory, volumeUUID: UUID())
    let secondRoot = AuthorizedRoot(url: secondDirectory, volumeUUID: UUID())
    let target = firstDirectory.appending(path: "target.html")
    let link = firstDirectory.appending(path: "linked.html")
    try Data("target".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    let targetID = try #require((try FileManager.default.attributesOfItem(atPath: target.path)[.systemFileNumber] as? NSNumber)?.uint64Value)
    let renamed = UInt32(kFSEventStreamEventFlagItemRenamed)
    let correlator = RenameCorrelator(roots: [firstRoot, secondRoot])
    let linkOld = FileEvent(rootID: firstRoot.id, eventID: 70, path: firstDirectory.appending(path: "linked.txt"), fileID: targetID, flags: renamed, side: .old)
    let linkNew = FileEvent(rootID: firstRoot.id, eventID: 70, path: link, fileID: targetID, flags: renamed, side: .new)
    #expect(await correlator.ingest(linkOld).isEmpty)
    #expect(await correlator.ingest(linkNew).isEmpty)

    let package = firstDirectory.appending(path: "Bundle.app", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
    let packageID = try #require((try FileManager.default.attributesOfItem(atPath: package.path)[.systemFileNumber] as? NSNumber)?.uint64Value)
    let packageOld = FileEvent(rootID: firstRoot.id, eventID: 73, path: firstDirectory.appending(path: "Bundle.txt"), fileID: packageID, flags: renamed, side: .old)
    let packageNew = FileEvent(rootID: firstRoot.id, eventID: 73, path: package, fileID: packageID, flags: renamed, side: .new)
    #expect(await correlator.ingest(packageOld).isEmpty)
    #expect(await correlator.ingest(packageNew).isEmpty)

    let ownFlags = renamed | UInt32(kFSEventStreamEventFlagOwnEvent)
    let own = FileEvent(rootID: firstRoot.id, eventID: 71, path: target, fileID: targetID, flags: ownFlags, side: .new)
    #expect(await correlator.ingest(own).isEmpty)

    let crossOld = FileEvent(rootID: firstRoot.id, eventID: 72, path: firstDirectory.appending(path: "target.txt"), fileID: targetID, flags: renamed, side: .old)
    let crossNew = FileEvent(rootID: secondRoot.id, eventID: 72, path: secondDirectory.appending(path: "target.html"), fileID: targetID, flags: renamed, side: .new)
    #expect(await correlator.ingest(crossOld).isEmpty)
    #expect(await correlator.ingest(crossNew).isEmpty)
}

@Test
func stabilityGateReevaluatesLatestFilenameByIdentity() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let html = directory.appending(path: "queued.html")
    let pdf = directory.appending(path: "queued.pdf")
    try Data("stable".utf8).write(to: html)
    let fileID = try #require((try FileManager.default.attributesOfItem(atPath: html.path)[.systemFileNumber] as? NSNumber)?.uint64Value)
    let root = AuthorizedRoot(url: directory, volumeUUID: UUID())
    let candidate = RenameCandidate(eventID: 80, rootID: root.id, fileKey: FileKey(volumeUUID: root.volumeUUID, fileID: fileID), oldRelativePath: "queued.txt", newRelativePath: "queued.html", observedAt: Date())
    try FileManager.default.moveItem(at: html, to: pdf)
    let stable = try await RenameStabilityGate.evaluate(candidate, roots: [root.id: root], interval: .milliseconds(20), timeout: .seconds(1))
    #expect(stable.url.lastPathComponent == "queued.pdf")
}

@Test
func pauseAndResumeUsesOnlyEventsAfterLatestCursor() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = AuthorizedRoot(url: directory, volumeUUID: UUID())
    let store = try JournalStore(url: directory.appending(path: "journal.sqlite"))
    try await store.upsertAuthorizedRoot(AuthorizedRootRecord(id: root.id, bookmark: Data([1]), displayPath: directory.path, volumeUUID: root.volumeUUID, enabled: true, eventCursor: 0, status: "available"))
    let cursorEvent = FileEvent(rootID: root.id, eventID: 123, path: directory, fileID: nil, flags: UInt32(kFSEventStreamEventFlagMustScanSubDirs), side: .unknown)
    let source = CursorRecordingSource(event: cursorEvent)
    let pipeline = RenamePipeline(roots: [root], cursorStore: store) { _ in Issue.record("Cursor event must not convert") }
    await pipeline.start(source: source)
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(1))
    while await pipeline.latestCursors[root.id] != 123, clock.now < deadline { try await clock.sleep(for: .milliseconds(10)) }
    #expect(try await store.authorizedRoots().first?.eventCursor == 123)
    await pipeline.pause()
    await pipeline.resume(source: source)
    try await clock.sleep(for: .milliseconds(50))
    let calls = source.recordedRoots()
    #expect(calls.count == 2)
    #expect(calls.last?.first?.eventCursor == 123)
}
