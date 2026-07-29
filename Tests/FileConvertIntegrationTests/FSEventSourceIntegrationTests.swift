import FileConvertCore
import Foundation
import Testing

@Test
func realFSEventSourceObservesRenameInsideAuthorizedRoot() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let volumeValues = try directory.resourceValues(forKeys: [.volumeUUIDStringKey])
    let root = AuthorizedRoot(url: directory, volumeUUID: UUID(uuidString: volumeValues.volumeUUIDString ?? "") ?? UUID())
    let source = FSEventEventSource(latency: 0.05)
    let collector = Task { () -> [FileEvent] in
        var observed: [FileEvent] = []
        do {
            for try await event in source.events(for: [root]) {
                observed.append(event)
            }
        } catch {}
        return observed
    }
    try await ContinuousClock().sleep(for: .milliseconds(250))
    let old = directory.appending(path: "live.txt")
    let new = directory.appending(path: "live.html")
    try Data("live".utf8).write(to: old)
    try FileManager.default.moveItem(at: old, to: new)
    try await ContinuousClock().sleep(for: .seconds(2))
    collector.cancel()
    let events = await collector.value
    #expect(events.contains(where: { $0.isRename && $0.rootID == root.id }))
    #expect(Set(events.filter(\.isRename).map(\.side)).contains(.new))
}

@Test
func liveSingleSidedFSEventIsCorrelatedFromIdentitySnapshot() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let old = directory.appending(path: "intent.txt")
    let new = directory.appending(path: "intent.html")
    try Data("live".utf8).write(to: old)
    let volumeValues = try directory.resourceValues(forKeys: [.volumeUUIDStringKey])
    let root = AuthorizedRoot(url: directory, volumeUUID: UUID(uuidString: volumeValues.volumeUUIDString ?? "") ?? UUID())
    let correlator = RenameCorrelator(roots: [root])
    let source = FSEventEventSource(latency: 0.05)
    let collector = Task { () -> RenameCandidate? in
        do {
            for try await event in source.events(for: [root]) {
                for signal in await correlator.ingest(event) {
                    if case let .candidate(candidate) = signal { return candidate }
                }
            }
        } catch {}
        return nil
    }
    try await ContinuousClock().sleep(for: .milliseconds(500))
    let rename = Process()
    rename.executableURL = URL(fileURLWithPath: "/bin/mv")
    rename.arguments = [old.path, new.path]
    try rename.run()
    rename.waitUntilExit()
    #expect(rename.terminationStatus == 0)
    try await ContinuousClock().sleep(for: .seconds(2))
    collector.cancel()
    let candidate = await collector.value
    #expect(candidate?.oldRelativePath == "intent.txt")
    #expect(candidate?.newRelativePath == "intent.html")
}
