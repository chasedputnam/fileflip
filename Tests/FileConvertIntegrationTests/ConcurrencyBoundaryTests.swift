import CoreServices
import FileConvertCore
import Foundation
import Testing

private struct BurstEventSource: RenameEventSource {
    let events: [FileEvent]
    func events(for roots: [AuthorizedRoot]) -> AsyncThrowingStream<FileEvent, Error> {
        AsyncThrowingStream<FileEvent, Error> { (continuation: AsyncThrowingStream<FileEvent, Error>.Continuation) in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

private actor ConcurrentWorkRecorder {
    private var active = 0
    private var maximum = 0
    private var completed = 0
    func begin() { active += 1; maximum = max(maximum, active) }
    func end() { active -= 1; completed += 1 }
    func snapshot() -> (maximum: Int, completed: Int) { (maximum, completed) }
}

@Test
func globalRenamePipelineConcurrencyIsHardCappedAtTwo() async throws {
    let rootURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let root = AuthorizedRoot(url: rootURL, volumeUUID: UUID())
    let renamed = UInt32(kFSEventStreamEventFlagItemRenamed)
    var events: [FileEvent] = []
    for index in 0..<3 {
        let target = rootURL.appending(path: "item\(index).html")
        try Data("item \(index)".utf8).write(to: target)
        let fileID = try #require((try FileManager.default.attributesOfItem(atPath: target.path)[.systemFileNumber] as? NSNumber)?.uint64Value)
        events.append(FileEvent(rootID: root.id, eventID: UInt64(index + 1), path: rootURL.appending(path: "item\(index).txt"), fileID: fileID, flags: renamed, side: .old))
        events.append(FileEvent(rootID: root.id, eventID: UInt64(index + 1), path: target, fileID: fileID, flags: renamed, side: .new))
    }
    let recorder = ConcurrentWorkRecorder()
    let pipeline = RenamePipeline(roots: [root], maximumConcurrency: 9) { _ in
        await recorder.begin()
        try? await ContinuousClock().sleep(for: .milliseconds(200))
        await recorder.end()
    }
    await pipeline.start(source: BurstEventSource(events: events))
    defer { Task { await pipeline.stop() } }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while await recorder.snapshot().completed < 3, clock.now < deadline {
        try await clock.sleep(for: .milliseconds(25))
    }
    let result = await recorder.snapshot()
    #expect(result.completed == 3)
    #expect(result.maximum > 0 && result.maximum <= 2)
}
