import FileConvertCore
import FileConvertProviders
import Foundation
import Testing

private let sourceFiveSeconds = #"{"streams":[{"codec_type":"audio","codec_name":"aac","nb_read_frames":"240","duration":"5.0"}],"format":{"format_name":"mov,mp4,m4a,3gp,3g2,mj2","duration":"5.0"}}"#

@Test
func ffprobeValidatorRejectsTruncatedOutputBeyondDurationTolerance() async throws {
    let truncated = #"{"streams":[{"codec_type":"audio","codec_name":"aac","nb_read_frames":"225","duration":"4.7","sample_rate":"48000","channels":2}],"format":{"format_name":"mov,mp4,m4a,3gp,3g2,mj2","duration":"4.7"}}"#
    let fixture = try validatorScript(sourceJSON: sourceFiveSeconds, outputJSON: truncated)
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let source = fixture.directory.appending(path: "source.m4a")
    let output = fixture.directory.appending(path: "output.m4a")
    try Data([1]).write(to: source)
    try Data([2]).write(to: output)

    await #expect(throws: FileConvertError.self) {
        try await FFprobeMediaValidator(tools: validatorTools(fixture.script)).validate(
            ProducedArtifact(url: output, providerID: ProviderID(rawValue: "test")),
            expectation: MediaValidationExpectation(target: .audio(.m4a), selectedStreamCounts: [.audio: 1], sourceURL: source, maximumBytes: 1_024)
        )
    }
}

@Test
func ffprobeValidatorRejectsAmbiguousSubtitleTrackLoss() async throws {
    let source = #"{"streams":[{"codec_type":"video","codec_name":"h264","nb_read_frames":"120","duration":"5.0"},{"codec_type":"audio","codec_name":"aac","nb_read_frames":"240","duration":"5.0"},{"codec_type":"subtitle","codec_name":"subrip","duration":"5.0"},{"codec_type":"subtitle","codec_name":"subrip","duration":"5.0"}],"format":{"format_name":"matroska,webm","duration":"5.0"}}"#
    let output = #"{"streams":[{"codec_type":"video","codec_name":"h264","nb_read_frames":"120","duration":"5.0","width":640,"height":480},{"codec_type":"audio","codec_name":"aac","nb_read_frames":"240","duration":"5.0","sample_rate":"48000","channels":2}],"format":{"format_name":"matroska,webm","duration":"5.0"}}"#
    let fixture = try validatorScript(sourceJSON: source, outputJSON: output)
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let sourceURL = fixture.directory.appending(path: "source.mkv")
    let outputURL = fixture.directory.appending(path: "output.mkv")
    try Data([1]).write(to: sourceURL)
    try Data([2]).write(to: outputURL)

    await #expect(throws: FileConvertError.self) {
        try await FFprobeMediaValidator(tools: validatorTools(fixture.script)).validate(
            ProducedArtifact(url: outputURL, providerID: ProviderID(rawValue: "test")),
            expectation: MediaValidationExpectation(target: .video(.mkv), selectedStreamCounts: [.video: 1, .audio: 1, .subtitle: 1], sourceURL: sourceURL, maximumBytes: 1_024)
        )
    }
}
