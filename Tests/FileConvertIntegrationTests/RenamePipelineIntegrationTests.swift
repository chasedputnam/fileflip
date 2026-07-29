import CoreServices
import FileConvertCore
import Foundation
import Testing

private struct FixedEventSource: RenameEventSource {
    let values: [FileEvent]
    func events(for roots: [AuthorizedRoot]) -> AsyncThrowingStream<FileEvent, Error> {
        AsyncThrowingStream { continuation in
            for value in values { continuation.yield(value) }
            continuation.finish()
        }
    }
}

private actor CompletionRecorder {
    private(set) var count = 0
    private(set) var error: String?
    func succeeded() { count += 1 }
    func failed(_ error: Error) { self.error = String(describing: error) }
}

@Test
func eligibleRenameRunsExactlyOneCrashSafeFakeConversion() async throws {
    let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let rootURL = base.appending(path: "watched", directoryHint: .isDirectory)
    let storage = base.appending(path: "storage", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let target = rootURL.appending(path: "sample.html")
    try Data("hello".utf8).write(to: target)
    let fileID = try #require((try FileManager.default.attributesOfItem(atPath: target.path)[.systemFileNumber] as? NSNumber)?.uint64Value)
    let root = AuthorizedRoot(url: rootURL, volumeUUID: UUID())
    let renamed = UInt32(kFSEventStreamEventFlagItemRenamed)
    let old = FileEvent(rootID: root.id, eventID: 100, path: rootURL.appending(path: "sample.txt"), fileID: fileID, flags: renamed, side: .old)
    let new = FileEvent(rootID: root.id, eventID: 100, path: target, fileID: fileID, flags: renamed, side: .new)
    let journal = try JournalStore(url: base.appending(path: "journal.sqlite"))
    let transaction = try TransactionCoordinator(journal: journal, storageRoot: storage)
    let recorder = CompletionRecorder()

    let pipeline = RenamePipeline(roots: [root]) { stable in
        do {
            let request = TransactionRequest(rootID: root.id, rootURL: root.url, oldRelativePath: stable.candidate.oldRelativePath, newRelativePath: stable.candidate.newRelativePath, sourceFormat: .document(.text), targetFormat: .document(.html), targetExtension: "html", providerID: ProviderID(rawValue: "deterministic-fake"), providerVersion: "1", policy: .document(acceptsFidelityLoss: true), conversionBehavior: .replaceWithBackup)
            _ = try await transaction.execute(request, produce: { staged, outputDirectory in
                let source = try String(contentsOf: staged, encoding: .utf8)
                let output = outputDirectory.appending(path: "output.html")
                try Data("<p>\(source)</p>".utf8).write(to: output)
                return ProducedArtifact(url: output, providerID: ProviderID(rawValue: "deterministic-fake"))
            }, validate: { artifact, expected in
                (try TransactionCoordinator.sha256(artifact.url), expected)
            })
            await recorder.succeeded()
        } catch {
            await recorder.failed(error)
        }
    }
    await pipeline.start(source: FixedEventSource(values: [new, old, new, old]))

    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while await recorder.count == 0, await recorder.error == nil, clock.now < deadline { try await clock.sleep(for: .milliseconds(20)) }
    #expect(await recorder.error == nil)
    #expect(await recorder.count == 1)
    #expect(try String(contentsOf: target, encoding: .utf8) == "<p>hello</p>")
}

@Test
func explicitRetryRemainsReservedAgainstDuplicateRenameEvents() async {
    let root = AuthorizedRoot(url: URL(fileURLWithPath: "/tmp"), volumeUUID: UUID())
    let candidate = RenameCandidate(
        eventID: 1,
        rootID: root.id,
        fileKey: FileKey(volumeUUID: root.volumeUUID, fileID: 42),
        oldRelativePath: "image.webp",
        newRelativePath: "image.jpg",
        observedAt: Date()
    )
    let stable = StableRename(candidate: candidate, url: root.url.appending(path: "image.jpg"), sourceHash: Data("source".utf8))
    let pipeline = RenamePipeline(roots: [root]) { _ in }

    await pipeline.reserveRetry(stable)

    #expect(await pipeline.reserve(stable) == false)
}
