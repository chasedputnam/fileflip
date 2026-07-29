import FileConvertCore
import FileConvertProviders
import Foundation
import Testing

private func processScript(_ body: String) throws -> (script: URL, directory: URL) {
    let directory = FileManager.default.temporaryDirectory.appending(path: "process-runner-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let script = directory.appending(path: "tool")
    try Data(("#!/bin/sh\n" + body).utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: script.path)
    return (script, directory)
}

@Test
func boundedProcessRunnerRejectsExcessiveOutputWithoutRetainingIt() async throws {
    let fixture = try processScript("while :; do printf 1234567890; done\n")
    defer { try? FileManager.default.removeItem(at: fixture.directory) }

    await #expect(throws: FileConvertError.self) {
        _ = try await BoundedProcessRunner(maximumOutputBytes: 128).run(
            executableURL: fixture.script,
            arguments: [],
            environment: ["PATH": "/usr/bin:/bin"],
            timeout: .seconds(5)
        )
    }
}

@Test
func boundedProcessRunnerTerminatesTimedOutProcess() async throws {
    let fixture = try processScript("sleep 30\n")
    defer { try? FileManager.default.removeItem(at: fixture.directory) }

    await #expect(throws: FileConvertError.timedOut) {
        _ = try await BoundedProcessRunner().run(
            executableURL: fixture.script,
            arguments: [],
            environment: ["PATH": "/usr/bin:/bin"],
            timeout: .milliseconds(50)
        )
    }
}
