import FileConvertCore
import Foundation
import Testing

private actor IdleHandlerRecorder {
    private var calls = 0
    func record() { calls += 1 }
    func count() -> Int { calls }
}

private struct SilentEventSource: RenameEventSource {
    func events(for roots: [AuthorizedRoot]) -> AsyncThrowingStream<FileEvent, Error> {
        AsyncThrowingStream { _ in }
    }
}

@Test
func idlePipelineDoesNotScanContentAndStaysWithinMeasuredResourceContract() async throws {
    let rootURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let recorder = IdleHandlerRecorder()
    let controlStart = ProcessResourceProbe.sample()
    try await ContinuousClock().sleep(for: .seconds(1))
    let controlEnd = ProcessResourceProbe.sample()
    let controlCPU = try #require(ProcessResourceProbe.averageCPUFraction(from: controlStart, to: controlEnd))
    let pipeline = RenamePipeline(roots: [AuthorizedRoot(url: rootURL, volumeUUID: UUID())]) { _ in
        await recorder.record()
    }
    await pipeline.start(source: SilentEventSource())
    defer { Task { await pipeline.stop() } }

    let idleStart = ProcessResourceProbe.sample()
    try await ContinuousClock().sleep(for: .seconds(1))
    let idleEnd = ProcessResourceProbe.sample()
    let idleCPU = try #require(ProcessResourceProbe.averageCPUFraction(from: idleStart, to: idleEnd))
    #expect(idleCPU <= controlCPU + 0.005)
    #expect(idleEnd.peakResidentBytes <= 100 * 1_024 * 1_024)
    #expect(await recorder.count() == 0)
}
