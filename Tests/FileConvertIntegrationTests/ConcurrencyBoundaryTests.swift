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

private actor BlockingWorkRecorder {
    private var started = false
    private var finished = false
    private var continuation: CheckedContinuation<Void, Never>?

    func run() async {
        started = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        finished = true
    }

    func hasStarted() -> Bool { started }
    func hasFinished() -> Bool { finished }

    func release() {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume()
    }
}

private actor DrainWorkRecorder {
    private var started = 0
    private var completed = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var releasePermits = 0

    func run() async {
        started += 1
        if releasePermits > 0 {
            releasePermits -= 1
        } else {
            await withCheckedContinuation { continuation in
                waiting.append(continuation)
            }
        }
        completed += 1
    }

    func snapshot() -> (started: Int, completed: Int) {
        (started, completed)
    }

    func releaseOne() {
        if waiting.isEmpty {
            releasePermits += 1
        } else {
            waiting.removeFirst().resume()
        }
    }
}

private actor CompletionFlag {
    private var value = false
    func mark() { value = true }
    func isMarked() -> Bool { value }
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

@Test
func pauseAndWaitForIdleDoesNotReturnDuringActiveConversion() async throws {
    let rootURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let root = AuthorizedRoot(url: rootURL, volumeUUID: UUID())
    let target = rootURL.appending(path: "item.html")
    try Data("item".utf8).write(to: target)
    let fileID = try #require((try FileManager.default.attributesOfItem(atPath: target.path)[.systemFileNumber] as? NSNumber)?.uint64Value)
    let renamed = UInt32(kFSEventStreamEventFlagItemRenamed)
    let events = [
        FileEvent(rootID: root.id, eventID: 1, path: rootURL.appending(path: "item.txt"), fileID: fileID, flags: renamed, side: .old),
        FileEvent(rootID: root.id, eventID: 1, path: target, fileID: fileID, flags: renamed, side: .new),
    ]
    let work = BlockingWorkRecorder()
    let completion = CompletionFlag()
    let pipeline = RenamePipeline(roots: [root]) { _ in await work.run() }
    await pipeline.start(source: BurstEventSource(events: events))

    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while !(await work.hasStarted()), clock.now < deadline {
        try await clock.sleep(for: .milliseconds(25))
    }
    let didStart = await work.hasStarted()
    #expect(didStart)

    let pauseTask = Task {
        await pipeline.pauseAndWaitForIdle()
        await completion.mark()
    }
    try await clock.sleep(for: .milliseconds(50))
    let completedWhileWorkWasActive = await completion.isMarked()
    #expect(!completedWhileWorkWasActive)

    await work.release()
    await pauseTask.value
    let didFinish = await work.hasFinished()
    let completedAfterWorkFinished = await completion.isMarked()
    #expect(didFinish)
    #expect(completedAfterWorkFinished)
}

@Test
func installationDrainFinishesEveryAcceptedRenameBeyondMaximumConcurrency() async throws {
    let rootURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let root = AuthorizedRoot(url: rootURL, volumeUUID: UUID())
    let renamed = UInt32(kFSEventStreamEventFlagItemRenamed)
    var events: [FileEvent] = []
    for index in 0..<3 {
        let target = rootURL.appending(path: "queued-\(index).html")
        try Data("queued \(index)".utf8).write(to: target)
        let fileID = try #require((try FileManager.default.attributesOfItem(atPath: target.path)[.systemFileNumber] as? NSNumber)?.uint64Value)
        events.append(FileEvent(rootID: root.id, eventID: UInt64(index + 1), path: rootURL.appending(path: "queued-\(index).txt"), fileID: fileID, flags: renamed, side: .old))
        events.append(FileEvent(rootID: root.id, eventID: UInt64(index + 1), path: target, fileID: fileID, flags: renamed, side: .new))
    }
    let work = DrainWorkRecorder()
    let reservationCompleted = CompletionFlag()
    let pipeline = RenamePipeline(roots: [root], maximumConcurrency: 2) { _ in await work.run() }
    await pipeline.start(source: BurstEventSource(events: events))

    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while await work.snapshot().started < 2, clock.now < deadline {
        try await clock.sleep(for: .milliseconds(25))
    }
    #expect(await work.snapshot().started == 2)

    let reservationTask = Task {
        await pipeline.drainForInstallationAndWaitForIdle()
        await reservationCompleted.mark()
    }
    try await clock.sleep(for: .milliseconds(50))
    #expect(!(await reservationCompleted.isMarked()))

    await work.releaseOne()
    await work.releaseOne()
    while await work.snapshot().started < 3, clock.now < deadline {
        try await clock.sleep(for: .milliseconds(25))
    }
    #expect(await work.snapshot().started == 3)
    #expect(!(await reservationCompleted.isMarked()))

    await work.releaseOne()
    await reservationTask.value
    let result = await work.snapshot()
    #expect(result.completed == 3)
    #expect(await reservationCompleted.isMarked())
}
