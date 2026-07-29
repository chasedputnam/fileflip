import FileConvertCore
import FileConvertProviders
import Foundation
import Testing

private func mediaTools(
    ffmpegURL: URL = URL(filePath: "/verified/ffmpeg"),
    ffprobeURL: URL = URL(filePath: "/verified/ffprobe"),
    encoders: Set<String> = ["aac", "libopus", "libvorbis", "flac", "pcm_s16le", "pcm_s16be", "libmp3lame", "mpeg4", "libvpx-vp9", "h264_videotoolbox"],
    muxers: Set<String> = ["mp3", "ipod", "adts", "wav", "aiff", "flac", "ogg", "opus", "mp4", "mov", "matroska", "webm"]
) -> VerifiedMediaTools {
    VerifiedMediaTools(
        ffmpegURL: ffmpegURL,
        ffprobeURL: ffprobeURL,
        version: "test",
        encoders: encoders,
        muxers: muxers,
        demuxers: ["mp3", "mov", "mp4", "wav", "aiff", "flac", "ogg", "matroska", "webm"]
    )
}

private func mediaRequest(target: String, policy: ConversionPolicy) -> ConversionRequest {
    ConversionRequest(
        jobID: UUID(),
        source: Snapshot(url: URL(filePath: "/staged/source"), fileKey: FileKey(volumeUUID: UUID(), fileID: 1), byteCount: 100, modificationDate: Date()),
        targetExtension: target,
        policy: policy,
        outputDirectory: URL(filePath: "/job"),
        deadline: Date().addingTimeInterval(60),
        maximumOutputBytes: 1_024
    )
}

@Test
func ffmpegCommandSelectsOneAudioTrackAndUsesOnlyApprovedArguments() throws {
    let provider = FFmpegMediaProvider(tools: mediaTools())
    let command = try provider.command(for: mediaRequest(target: "opus", policy: .audio(bitrate: 96_000, sampleRate: 48_000, trackIndex: 2)), outputURL: URL(filePath: "/job/output.opus"))

    #expect(command.executableURL == URL(filePath: "/verified/ffmpeg"))
    #expect(command.arguments == ["-hide_banner", "-nostdin", "-v", "error", "-xerror", "-n", "-i", "/staged/source", "-map", "0:a:2", "-vn", "-sn", "-dn", "-c:a", "libopus", "-f", "opus", "-b:a", "96000", "-ar", "48000", "-fs", "1024", "--", "/job/output.opus"])
}

@Test
func ffmpegCommandPrefersVideoToolboxAndHasMPEG4FallbackCommand() throws {
    let provider = FFmpegMediaProvider(tools: mediaTools())
    let request = mediaRequest(target: "mkv", policy: .video(quality: 20, audioTrack: 1, subtitleTrack: 0))
    let hardware = try provider.command(for: request, outputURL: URL(filePath: "/job/output.mkv"))
    let fallback = try provider.command(for: request, outputURL: URL(filePath: "/job/output.mkv"), forceSoftwareVideo: true)

    #expect(hardware.arguments.contains("h264_videotoolbox"))
    #expect(fallback.arguments.contains("mpeg4"))
    #expect(hardware.arguments.contains("0:v:0"))
    #expect(hardware.arguments.contains("0:a:1?"))
    #expect(hardware.arguments.contains("0:s:0"))
    #expect(hardware.arguments.contains("-c:s"))
}

@Test
func ffmpegCommandRejectsUnrepresentableSubtitleAndUnverifiedTarget() throws {
    let provider = FFmpegMediaProvider(tools: mediaTools())
    #expect(throws: FileConvertError.self) {
        try provider.command(for: mediaRequest(target: "mp4", policy: .video(subtitleTrack: 0)), outputURL: URL(filePath: "/job/output.mp4"))
    }
    #expect(throws: FileConvertError.self) {
        try provider.command(for: mediaRequest(target: "avi", policy: .video()), outputURL: URL(filePath: "/job/output.avi"))
    }
}

@Test
func ffmpegCapabilitiesPublishOnlyVerifiedSameFamilyPairs() async {
    let capabilities = await FFmpegMediaProvider(tools: mediaTools()).capabilities()
    #expect(capabilities == InstalledMediaContract.capabilities(for: mediaTools()))
    #expect(capabilities.allSatisfy { capability in
        guard let source = InstalledMediaContract.installedFormat(for: capability.source),
              let target = InstalledMediaContract.installedFormat(forExtension: capability.targetExtension) else { return false }
        return source.family == target.family && source.format != target.format
    })
    let emptyCapabilities = await FFmpegMediaProvider(tools: mediaTools(muxers: [])).capabilities()
    #expect(emptyCapabilities.isEmpty)
}

private func executableFixture(_ body: String) throws -> (script: URL, directory: URL) {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "ffmpeg-provider-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let script = directory.appending(path: "ffmpeg")
    try Data(("#!/bin/sh\nset -eu\nfor last do :; done\n" + body).utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: script.path)
    return (script, directory)
}

private func executableRequest(
    directory: URL,
    target: String = "mp3",
    policy: ConversionPolicy = .audio(),
    deadline: Date = Date().addingTimeInterval(30),
    maximumOutputBytes: UInt64 = 1_024
) -> ConversionRequest {
    ConversionRequest(
        jobID: UUID(),
        source: Snapshot(
            url: directory.appending(path: "source"), fileKey: FileKey(volumeUUID: UUID(), fileID: 1),
            byteCount: 1, modificationDate: Date()
        ),
        targetExtension: target, policy: policy, outputDirectory: directory,
        deadline: deadline, maximumOutputBytes: maximumOutputBytes
    )
}

@Test
func ambiguousMediaTracksRequireOnlyUnsetSupportedChoices() async throws {
    let json = """
    {"streams":[
      {"codec_type":"video","codec_name":"h264"},
      {"codec_type":"audio","codec_name":"aac","tags":{"language":"eng","title":"Main"}},
      {"codec_type":"audio","codec_name":"aac","tags":{"language":"spa"}},
      {"codec_type":"subtitle","codec_name":"subrip","tags":{"language":"eng"}},
      {"codec_type":"subtitle","codec_name":"subrip","tags":{"language":"fra"}}
    ]}
    """
    let fixture = try executableFixture("printf '%s' '\(json)'\n")
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let provider = FFmpegMediaProvider(tools: mediaTools(ffprobeURL: fixture.script))
    let source = fixture.directory.appending(path: "source.mkv")

    let audio = try await provider.requiredTrackChoices(
        for: source,
        targetExtension: "mp3",
        policy: .audio()
    )
    #expect(audio.audio.map(\.index) == [0, 1])
    #expect(audio.audio[0].label == "Track 1 · eng · Main · aac")
    #expect(audio.subtitles.isEmpty)

    let selectedAudio = try await provider.requiredTrackChoices(
        for: source,
        targetExtension: "mp3",
        policy: .audio(trackIndex: 0)
    )
    #expect(selectedAudio.isEmpty)

    let matroska = try await provider.requiredTrackChoices(
        for: source,
        targetExtension: "mkv",
        policy: .video()
    )
    #expect(matroska.audio.map(\.index) == [0, 1])
    let selectedVideo = try await provider.requiredTrackChoices(
        for: source,
        targetExtension: "mkv",
        policy: .video(audioTrack: 0, subtitleTrack: 0)
    )
    #expect(selectedVideo.isEmpty)

    #expect(matroska.subtitles.map(\.index) == [0, 1])

    let mp4 = try await provider.requiredTrackChoices(
        for: source,
        targetExtension: "mp4",
        policy: .video()
    )
    #expect(mp4.audio.map(\.index) == [0, 1])
    #expect(mp4.subtitles.isEmpty)
}

@Test
func ffmpegCommandRejectsInvalidPoliciesAndEscapedOutput() throws {
    let provider = FFmpegMediaProvider(tools: mediaTools())
    for policy in [
        ConversionPolicy.audio(version: 2),
        .audio(bitrate: 0),
        .audio(sampleRate: -1),
        .audio(trackIndex: -1),
        .video(version: 2),
        .video(quality: 52),
        .video(audioTrack: -1),
    ] {
        #expect(throws: FileConvertError.self) {
            try provider.command(
                for: mediaRequest(target: policy == .video(version: 2) || policy == .video(quality: 52) || policy == .video(audioTrack: -1) ? "mp4" : "mp3", policy: policy),
                outputURL: URL(filePath: "/job/output")
            )
        }
    }
    #expect(throws: FileConvertError.self) {
        try provider.command(
            for: mediaRequest(target: "mp3", policy: .audio()),
            outputURL: URL(filePath: "/outside/output.mp3")
        )
    }
}

@Test
func ffmpegConversionRejectsPreexistingOutputWithoutLaunching() async throws {
    let fixture = try executableFixture("printf launched > \"$last\"\n")
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let output = fixture.directory.appending(path: "output.mp3")
    try Data("existing".utf8).write(to: output)
    let provider = FFmpegMediaProvider(tools: mediaTools(ffmpegURL: fixture.script))

    await #expect(throws: FileConvertError.self) {
        _ = try await provider.convert(executableRequest(directory: fixture.directory))
    }
    #expect(try Data(contentsOf: output) == Data("existing".utf8))
}

@Test
func ffmpegConversionRejectsDanglingPreexistingOutputWithoutLaunching() async throws {
    let fixture = try executableFixture("printf launched > \"$last\"\n")
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let output = fixture.directory.appending(path: "output.mp3")
    let destination = fixture.directory.appending(path: "outside")
    try FileManager.default.createSymbolicLink(at: output, withDestinationURL: destination)
    let provider = FFmpegMediaProvider(tools: mediaTools(ffmpegURL: fixture.script))

    await #expect(throws: FileConvertError.self) {
        _ = try await provider.convert(executableRequest(directory: fixture.directory))
    }
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: output.path) == destination.path)
    #expect(!FileManager.default.fileExists(atPath: destination.path))
}

@Test
func ffmpegConversionRejectsProducedSymlinkAndPreservesItsDestination() async throws {
    let fixture = try executableFixture("ln -s outside \"$last\"\n")
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let destination = fixture.directory.appending(path: "outside")
    try Data("existing".utf8).write(to: destination)
    let output = fixture.directory.appending(path: "output.mp3")
    let provider = FFmpegMediaProvider(tools: mediaTools(ffmpegURL: fixture.script))

    await #expect(throws: FileConvertError.self) {
        _ = try await provider.convert(executableRequest(directory: fixture.directory))
    }
    #expect(!FileManager.default.fileExists(atPath: output.path))
    #expect(try Data(contentsOf: destination) == Data("existing".utf8))
}

@Test
func ffmpegConversionCleansPartialOutputOnFailureBoundsAndDeadline() async throws {
    for (body, deadline, maximumBytes) in [
        ("printf partial > \"$last\"\nexit 7\n", Date().addingTimeInterval(30), UInt64(1_024)),
        ("dd if=/dev/zero of=\"$last\" bs=2048 count=1 2>/dev/null\n", Date().addingTimeInterval(30), UInt64(1_024)),
        ("printf late > \"$last\"\n", Date().addingTimeInterval(-1), UInt64(1_024)),
    ] {
        let fixture = try executableFixture(body)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let provider = FFmpegMediaProvider(tools: mediaTools(ffmpegURL: fixture.script))

        await #expect(throws: FileConvertError.self) {
            _ = try await provider.convert(executableRequest(
                directory: fixture.directory, deadline: deadline, maximumOutputBytes: maximumBytes
            ))
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appending(path: "output.mp3").path))
    }
}

@Test
func ffmpegConversionCancellationRemovesPartialOutput() async throws {
    let fixture = try executableFixture("printf partial > \"$last\"\nsleep 30\n")
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let provider = FFmpegMediaProvider(tools: mediaTools(ffmpegURL: fixture.script))
    let output = fixture.directory.appending(path: "output.mp3")
    let work = Task { try await provider.convert(executableRequest(directory: fixture.directory)) }
    for _ in 0..<500 where !FileManager.default.fileExists(atPath: output.path) {
        try await ContinuousClock().sleep(for: .milliseconds(20))
    }
    try #require(FileManager.default.fileExists(atPath: output.path))
    work.cancel()

    await #expect(throws: FileConvertError.cancelled) {
        _ = try await work.value
    }
    #expect(!FileManager.default.fileExists(atPath: output.path))
}

@Test
func ffmpegConversionFallsBackFromHardwareAndRemovesItsPartialOutput() async throws {
    let fixture = try executableFixture("""
    printf '%s\\n' \"$*\" >> \"\(fixtureLogPlaceholder)\"
    case \"$*\" in
      *h264_videotoolbox*) printf hardware-partial > \"$last\"; exit 1 ;;
      *) printf software-success > \"$last\" ;;
    esac
    """)
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let log = fixture.directory.appending(path: "invocations")
    let body = try String(contentsOf: fixture.script, encoding: .utf8)
        .replacingOccurrences(of: fixtureLogPlaceholder, with: log.path)
    try Data(body.utf8).write(to: fixture.script)
    let provider = FFmpegMediaProvider(tools: mediaTools(ffmpegURL: fixture.script))

    let artifact = try await provider.convert(executableRequest(
        directory: fixture.directory, target: "mkv", policy: .video()
    ))
    let invocations = try String(contentsOf: log, encoding: .utf8)

    #expect(invocations.contains("h264_videotoolbox"))
    #expect(invocations.contains("mpeg4"))
    #expect(try Data(contentsOf: artifact.url) == Data("software-success".utf8))
}

private let fixtureLogPlaceholder = "__FILEFLIP_INVOCATION_LOG__"
