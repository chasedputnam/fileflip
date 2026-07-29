import FileConvertCore
import FileConvertProviders
import Foundation
import Testing

@Test
func cancellationTerminatesTheEntireProviderProcessGroup() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let script = directory.appending(path: "provider.sh")
    let marker = directory.appending(path: "child-survived")
    try Data("#!/bin/sh\n(sleep 1; printf child > \"$MARKER\") &\nsleep 30\n".utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: script.path)
    let runner = BoundedProcessRunner()

    let work = Task {
        try await runner.run(executableURL: script, arguments: [], environment: ["MARKER": marker.path], timeout: .seconds(10))
    }
    try await ContinuousClock().sleep(for: .milliseconds(100))
    work.cancel()
    await #expect(throws: FileConvertError.cancelled) {
        _ = try await work.value
    }
    try await ContinuousClock().sleep(for: .seconds(2))
    #expect(!FileManager.default.fileExists(atPath: marker.path))
}
