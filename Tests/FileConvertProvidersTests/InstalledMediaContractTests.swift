import FileConvertCore
import FileConvertProviders
import Foundation
import Testing

private let completeInstalledMediaTools = VerifiedMediaTools(
    ffmpegURL: URL(filePath: "/verified/ffmpeg"),
    ffprobeURL: URL(filePath: "/verified/ffprobe"),
    version: "test",
    encoders: ["aac", "libopus", "libvorbis", "flac", "pcm_s16le", "pcm_s16be", "libmp3lame", "mpeg4", "libvpx-vp9", "h264_videotoolbox"],
    muxers: ["mp3", "ipod", "adts", "wav", "aiff", "flac", "ogg", "opus", "mp4", "mov", "matroska", "webm"],
    demuxers: ["mp3", "mov", "mp4", "wav", "aiff", "flac", "ogg", "matroska", "webm"]
)

@Test
func installedMediaContractDeclaresExactInstalledFormatsAndAliases() {
    #expect(InstalledMediaContract.version == 1)
    #expect(InstalledMediaContract.formats.map(\.canonicalExtension) == [
        "mp3", "m4a", "aac", "wav", "aiff", "flac", "ogg", "opus",
        "mp4", "m4v", "mov", "mkv", "webm",
    ])
    #expect(InstalledMediaContract.format(forExtension: ".AIF") == .audio(.aiff))
    #expect(InstalledMediaContract.format(forExtension: "m4v") == .video(.m4v))
    #expect(InstalledMediaContract.format(forExtension: "avi") == nil)
    #expect(Set(InstalledMediaContract.formats.map(\.format)).count == 13)
}

@Test
func installedMediaContractDeclaresExactRouteSet() {
    let capabilities = InstalledMediaContract.capabilities(for: completeInstalledMediaTools)
    let audio = capabilities.filter { if case .audio = $0.source { true } else { false } }
    let video = capabilities.filter { if case .video = $0.source { true } else { false } }

    #expect(capabilities.count == 76)
    #expect(audio.count == 56)
    #expect(video.count == 20)
    #expect(capabilities.allSatisfy { $0.providerID == InstalledMediaContract.providerID })
    #expect(capabilities.allSatisfy { capability in
        InstalledMediaContract.installedFormat(forExtension: capability.targetExtension)?.format != capability.source
    })
}

@Test
func installedMediaContractOmitsEveryRouteToAnUnverifiedTarget() {
    let tools = VerifiedMediaTools(
        ffmpegURL: completeInstalledMediaTools.ffmpegURL,
        ffprobeURL: completeInstalledMediaTools.ffprobeURL,
        version: completeInstalledMediaTools.version,
        encoders: completeInstalledMediaTools.encoders,
        muxers: completeInstalledMediaTools.muxers.subtracting(["adts"]),
        demuxers: completeInstalledMediaTools.demuxers
    )
    let capabilities = InstalledMediaContract.capabilities(for: tools)

    #expect(capabilities.count == 69)
    #expect(!capabilities.contains { $0.targetExtension == "aac" })
    #expect(capabilities.contains { $0.targetExtension == "m4a" })
}

@Test
func installedMediaContractPinsOutputCodecsAndDefaultStreams() throws {
    let opus = try #require(InstalledMediaContract.installedFormat(forExtension: "opus"))
    let mp4 = try #require(InstalledMediaContract.installedFormat(forExtension: "mp4"))
    let webm = try #require(InstalledMediaContract.installedFormat(forExtension: "webm"))

    #expect(opus.admittedOutputCodecs == ["opus"])
    #expect(opus.defaultStreams == InstalledMediaStreamContract(audio: 1, video: 0))
    #expect(mp4.admittedOutputCodecs == ["mpeg4", "h264", "aac"])
    #expect(mp4.defaultStreams == InstalledMediaStreamContract(audio: 1, video: 1))
    #expect(webm.admittedOutputCodecs == ["vp9", "opus"])
    #expect(webm.requiredEncoders == ["libvpx-vp9", "libopus"])
}

@Test
func installedMediaContractDistinguishesEveryProbeContainer() {
    let cases: [(Set<String>, Set<String>, String?, Bool, Bool, DetectedFormat)] = [
        (["mp3"], ["mp3"], nil, true, false, .audio(.mp3)),
        (["mov", "mp4", "m4a"], ["aac"], "M4A ", true, false, .audio(.m4a)),
        (["aac"], ["aac"], nil, true, false, .audio(.aac)),
        (["wav"], ["pcm_s16le"], nil, true, false, .audio(.wav)),
        (["aiff"], ["pcm_s16be"], nil, true, false, .audio(.aiff)),
        (["flac"], ["flac"], nil, true, false, .audio(.flac)),
        (["ogg"], ["vorbis"], nil, true, false, .audio(.ogg)),
        (["ogg"], ["opus"], nil, true, false, .audio(.opus)),
        (["mov", "mp4", "m4a"], ["mpeg4", "aac"], "isom", true, true, .video(.mp4)),
        (["mov", "mp4", "m4a"], ["mpeg4", "aac"], "M4V ", true, true, .video(.m4v)),
        (["mov", "mp4", "m4a"], ["mpeg4", "aac"], "qt  ", true, true, .video(.mov)),
        (["matroska"], ["mpeg4", "aac"], nil, true, true, .video(.mkv)),
        (["matroska", "webm"], ["vp9", "opus"], nil, true, true, .video(.webM)),
    ]

    for (names, codecs, brand, hasAudio, hasVideo, expected) in cases {
        #expect(InstalledMediaContract.detectedFormat(
            formatNames: names,
            codecs: codecs,
            majorBrand: brand,
            hasAudio: hasAudio,
            hasVideo: hasVideo
        ) == expected)
        #expect(InstalledMediaContract.probeMatches(
            expected,
            formatNames: names,
            codecs: codecs,
            majorBrand: brand,
            hasAudio: hasAudio,
            hasVideo: hasVideo
        ))
    }
}
