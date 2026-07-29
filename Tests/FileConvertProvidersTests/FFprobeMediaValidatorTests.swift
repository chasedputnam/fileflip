import FileConvertCore
import FileConvertProviders
import Foundation
import Testing

func validatorScript(sourceJSON: String, outputJSON: String) throws -> (script: URL, directory: URL) {
    let directory = FileManager.default.temporaryDirectory.appending(path: "ffprobe-validator-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let script = directory.appending(path: "ffprobe")
    let body = "#!/bin/sh\ncase \"$*\" in\n  *source*) printf '%s' '\(sourceJSON)' ;;\n  *) printf '%s' '\(outputJSON)' ;;\nesac\n"
    try Data(body.utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    return (script, directory)
}

func validatorTools(_ script: URL) -> VerifiedMediaTools {
    VerifiedMediaTools(ffmpegURL: script, ffprobeURL: script, version: "test", encoders: [], muxers: [], demuxers: [])
}

let playableM4A = #"{"streams":[{"codec_type":"audio","codec_name":"aac","nb_read_frames":"240","duration":"5.0","sample_rate":"48000","channels":2}],"format":{"format_name":"mov,mp4,m4a,3gp,3g2,mj2","duration":"5.0","tags":{"major_brand":"M4A "}}}"#

@Test
func ffprobeValidatorAcceptsPlayableRequestedContainerAndDuration() async throws {
    let fixture = try validatorScript(sourceJSON: playableM4A, outputJSON: playableM4A)
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let source = fixture.directory.appending(path: "source.m4a")
    let output = fixture.directory.appending(path: "output.m4a")
    try Data([0x01]).write(to: source)
    try Data([0x02]).write(to: output)

    let result = try await FFprobeMediaValidator(tools: validatorTools(fixture.script)).validate(
        ProducedArtifact(url: output, providerID: ProviderID(rawValue: "test")),
        expectation: MediaValidationExpectation(
            target: .audio(.m4a),
            selectedStreamCounts: [.audio: 1],
            sourceURL: source,
            maximumBytes: 1_024
        )
    )
    #expect(result.format == .audio(.m4a))
    #expect(result.duration == 5)
    #expect(result.streamCounts == [.audio: 1])
    #expect(result.facts.durationMilliseconds == 5_000)
    #expect(result.facts.streams == [
        MediaStreamFacts(
            kind: .audio, codec: "aac", frameCount: 240,
            sampleRate: 48_000, channels: 2, width: nil, height: nil
        ),
    ])
}

@Test
func ffprobeValidatorRejectsExtensionOnlyMasqueradeAndMissingSelectedTrack() async throws {
    let wavJSON = #"{"streams":[{"codec_type":"audio","codec_name":"pcm_s16le","nb_read_frames":"240","duration":"5.0"}],"format":{"format_name":"wav","duration":"5.0"}}"#
    let fixture = try validatorScript(sourceJSON: playableM4A, outputJSON: wavJSON)
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let source = fixture.directory.appending(path: "source.m4a")
    let output = fixture.directory.appending(path: "masquerade.mp3")
    try Data([0x01]).write(to: source)
    try Data([0x02]).write(to: output)
    let validator = FFprobeMediaValidator(tools: validatorTools(fixture.script))

    await #expect(throws: FileConvertError.self) {
        try await validator.validate(
            ProducedArtifact(url: output, providerID: ProviderID(rawValue: "test")),
            expectation: MediaValidationExpectation(target: .audio(.mp3), sourceURL: source, maximumBytes: 1_024)
        )
    }
    await #expect(throws: FileConvertError.self) {
        try await validator.validate(
            ProducedArtifact(url: output, providerID: ProviderID(rawValue: "test")),
            expectation: MediaValidationExpectation(target: .audio(.wav), selectedStreamCounts: [.audio: 2], sourceURL: source, maximumBytes: 1_024)
        )
    }
}

@Test
func ffprobeValidatorRejectsZeroDurationAndUndecodableStreams() async throws {
    let zeroDuration = #"{"streams":[{"codec_type":"audio","codec_name":"aac","nb_read_frames":"0","duration":"0"}],"format":{"format_name":"mov,mp4,m4a,3gp,3g2,mj2","duration":"0"}}"#
    let fixture = try validatorScript(sourceJSON: playableM4A, outputJSON: zeroDuration)
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let output = fixture.directory.appending(path: "output.m4a")
    try Data([0x02]).write(to: output)

    await #expect(throws: FileConvertError.self) {
        try await FFprobeMediaValidator(tools: validatorTools(fixture.script)).validate(
            ProducedArtifact(url: output, providerID: ProviderID(rawValue: "test")),
            expectation: MediaValidationExpectation(target: .audio(.m4a), maximumBytes: 1_024)
        )
    }
}

@Test
func ffprobeValidatorRejectsMalformedProbeJSON() async throws {
    let fixture = try validatorScript(sourceJSON: playableM4A, outputJSON: "not JSON")
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let output = fixture.directory.appending(path: "output.m4a")
    try Data([0x02]).write(to: output)

    await #expect(throws: FileConvertError.self) {
        try await FFprobeMediaValidator(tools: validatorTools(fixture.script)).validate(
            ProducedArtifact(url: output, providerID: ProviderID(rawValue: "test")),
            expectation: MediaValidationExpectation(target: .audio(.m4a), maximumBytes: 1_024)
        )
    }
}

@Test
func ffprobeValidatorRejectsInvalidOrContradictoryMediaFacts() async throws {
    let invalidStreams = [
        #"{"codec_type":"audio","codec_name":"aac","nb_read_frames":"240","duration":"5.0","channels":2}"#,
        #"{"codec_type":"audio","codec_name":"aac","nb_read_frames":"240","duration":"5.0","sample_rate":"48000","channels":0}"#,
        #"{"codec_type":"audio","codec_name":"aac","nb_read_frames":"invalid","duration":"5.0","sample_rate":"48000","channels":2}"#,
        #"{"codec_type":"audio","codec_name":"aac","nb_read_frames":"240","duration":"5.0","sample_rate":"48000","channels":2,"width":640}"#,
        #"{"codec_type":"audio","codec_name":"pcm_s16le","nb_read_frames":"240","duration":"5.0","sample_rate":"48000","channels":2}"#,
        #"{"codec_type":"data","codec_name":"bin_data","nb_read_frames":"1","duration":"5.0"}"#,
    ]

    for stream in invalidStreams {
        let outputJSON = #"{"streams":[\#(stream)],"format":{"format_name":"mov,mp4,m4a,3gp,3g2,mj2","duration":"5.0","tags":{"major_brand":"M4A "}}}"#
        let fixture = try validatorScript(sourceJSON: playableM4A, outputJSON: outputJSON)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let output = fixture.directory.appending(path: "output.m4a")
        try Data([0x02]).write(to: output)

        await #expect(throws: FileConvertError.self) {
            try await FFprobeMediaValidator(tools: validatorTools(fixture.script)).validate(
                ProducedArtifact(url: output, providerID: ProviderID(rawValue: "test")),
                expectation: MediaValidationExpectation(target: .audio(.m4a), maximumBytes: 1_024)
            )
        }
    }
}

@Test
func ffprobeValidatorEnforcesDefaultVideoStreamContract() async throws {
    let videoOnly = #"{"streams":[{"codec_type":"video","codec_name":"h264","nb_read_frames":"120","duration":"5.0","width":640,"height":480}],"format":{"format_name":"mov,mp4,m4a,3gp,3g2,mj2","duration":"5.0","tags":{"major_brand":"isom"}}}"#
    let fixture = try validatorScript(sourceJSON: videoOnly, outputJSON: videoOnly)
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let output = fixture.directory.appending(path: "output.mp4")
    try Data([0x02]).write(to: output)

    await #expect(throws: FileConvertError.self) {
        try await FFprobeMediaValidator(tools: validatorTools(fixture.script)).validate(
            ProducedArtifact(url: output, providerID: ProviderID(rawValue: "test")),
            expectation: MediaValidationExpectation(target: .video(.mp4), maximumBytes: 1_024)
        )
    }
}
