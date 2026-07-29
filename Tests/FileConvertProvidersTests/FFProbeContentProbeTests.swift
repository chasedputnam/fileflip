import FileConvertCore
import FileConvertProviders
import Foundation
import Testing

private func executableScript(_ body: String) throws -> (URL, URL) {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let script = directory.appending(path: "ffprobe")
    try Data(("#!/bin/sh\n" + body).utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    return (script, directory)
}

@Test
func ffprobeJSONMapsOnlyKnownMediaFields() async throws {
    let json = #"{"unknown":"ignored","streams":[{"codec_name":"h264","codec_type":"video","extra":1}],"format":{"format_name":"mov,mp4,m4a,3gp,3g2,mj2","tags":{"major_brand":"isom"}}}"#
    let (script, directory) = try executableScript("printf '%s' '\(json)'\n")
    defer { try? FileManager.default.removeItem(at: directory) }
    let input = directory.appending(path: "input.any")
    try Data([1]).write(to: input)

    #expect(try await FFProbeContentProbe(executableURL: script).probe(input, maximumOutputBytes: 4_096) == .video(.mp4))
}

@Test
func ffprobeOutputAndRuntimeAreBounded() async throws {
    let (largeScript, largeDirectory) = try executableScript("printf '%02048d' 1\n")
    defer { try? FileManager.default.removeItem(at: largeDirectory) }
    let input = largeDirectory.appending(path: "input.any")
    try Data([1]).write(to: input)
    await #expect(throws: FileConvertError.self) {
        try await FFProbeContentProbe(executableURL: largeScript).probe(input, maximumOutputBytes: 64)
    }

    let (slowScript, slowDirectory) = try executableScript("sleep 2\nprintf '{}'")
    defer { try? FileManager.default.removeItem(at: slowDirectory) }
    let slowInput = slowDirectory.appending(path: "input.any")
    try Data([1]).write(to: slowInput)
    await #expect(throws: FileConvertError.timedOut) {
        try await FFProbeContentProbe(executableURL: slowScript, timeout: .milliseconds(20)).probe(slowInput, maximumOutputBytes: 64)
    }
}
