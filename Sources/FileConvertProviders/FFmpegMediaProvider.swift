import Darwin
import FileConvertCore
import Foundation

public struct FFmpegMediaCommand: Sendable, Equatable {
    public let executableURL: URL
    public let arguments: [String]
    public let outputURL: URL
}

public struct MediaTrackOption: Hashable, Sendable {
    public let index: Int
    public let label: String

    public init(index: Int, label: String) {
        self.index = index
        self.label = label
    }
}

public struct MediaTrackInventory: Hashable, Sendable {
    public let audio: [MediaTrackOption]
    public let subtitles: [MediaTrackOption]

    public init(audio: [MediaTrackOption], subtitles: [MediaTrackOption]) {
        self.audio = audio
        self.subtitles = subtitles
    }
}

public struct MediaTrackChoicesRequired: Hashable, Sendable {
    public let audio: [MediaTrackOption]
    public let subtitles: [MediaTrackOption]

    public init(audio: [MediaTrackOption] = [], subtitles: [MediaTrackOption] = []) {
        self.audio = audio
        self.subtitles = subtitles
    }

    public var isEmpty: Bool { audio.isEmpty && subtitles.isEmpty }
}

private struct FFprobeTrackPayload: Decodable {
    struct Stream: Decodable {
        struct Tags: Decodable {
            let language: String?
            let title: String?
        }

        let codec_name: String?
        let codec_type: String?
        let tags: Tags?
    }

    let streams: [Stream]
}

public struct FFmpegMediaProvider: ConversionProvider {
    public let id = ProviderID(rawValue: "ffmpeg")
    public let tools: VerifiedMediaTools
    private let runner: BoundedProcessRunner

    public init(tools: VerifiedMediaTools, runner: BoundedProcessRunner = BoundedProcessRunner()) {
        self.tools = tools
        self.runner = runner
    }

    public func health() async -> ProviderHealth {
        InstalledMediaContract.supportedFormats(for: tools).isEmpty
            ? .unavailable(reason: "Verified FFmpeg inventory has no approved targets")
            : .available(version: tools.version)
    }

    public func capabilities() async -> Set<ConversionCapability> {
        InstalledMediaContract.capabilities(for: tools)
    }

    public func trackInventory(for source: URL) async throws -> MediaTrackInventory {
        let result = try await runner.run(
            executableURL: tools.ffprobeURL,
            arguments: [
                "-v", "error",
                "-show_entries", "stream=codec_type,codec_name:stream_tags=language,title",
                "-of", "json",
                "--", source.path,
            ],
            environment: Self.environment,
            timeout: .seconds(15)
        )
        guard result.terminationStatus == 0 else {
            throw FileConvertError.validationFailed("FFprobe track inspection failed")
        }
        let payload = try JSONDecoder().decode(FFprobeTrackPayload.self, from: result.stdout)
        return MediaTrackInventory(
            audio: Self.options(for: "audio", streams: payload.streams),
            subtitles: Self.options(for: "subtitle", streams: payload.streams)
        )
    }

    public func requiredTrackChoices(
        for source: URL,
        targetExtension: String,
        policy: ConversionPolicy
    ) async throws -> MediaTrackChoicesRequired {
        let target = InstalledMediaContract.installedFormat(forExtension: targetExtension)
        switch policy {
        case let .audio(_, _, _, trackIndex):
            guard trackIndex == nil else { return MediaTrackChoicesRequired() }
            let inventory = try await trackInventory(for: source)
            return MediaTrackChoicesRequired(audio: inventory.audio.count > 1 ? inventory.audio : [])
        case let .video(_, _, audioTrack, subtitleTrack):
            let maySelectSubtitles = target?.format == .video(.mkv)
            guard audioTrack == nil || (subtitleTrack == nil && maySelectSubtitles) else {
                return MediaTrackChoicesRequired()
            }
            let inventory = try await trackInventory(for: source)
            return MediaTrackChoicesRequired(
                audio: audioTrack == nil && inventory.audio.count > 1 ? inventory.audio : [],
                subtitles: subtitleTrack == nil && maySelectSubtitles && inventory.subtitles.count > 1
                    ? inventory.subtitles
                    : []
            )
        default:
            return MediaTrackChoicesRequired()
        }
    }


    public func convert(_ request: ConversionRequest) async throws -> ProducedArtifact {
        try Task.checkCancellation()
        let maximumDeadline = Date().addingTimeInterval(15 * 60)
        guard request.deadline > Date(), request.deadline <= maximumDeadline, request.maximumOutputBytes > 0 else { throw FileConvertError.validationFailed("Invalid media conversion limits") }
        let output = request.outputDirectory.appending(path: "output.\(Self.normalize(request.targetExtension))")
        var existingOutput = stat()
        guard lstat(output.path, &existingOutput) != 0 else {
            throw FileConvertError.validationFailed("Provider output already exists")
        }
        guard errno == ENOENT else {
            throw FileConvertError.validationFailed("Provider output path is unavailable")
        }
        var retainOutput = false
        defer { if !retainOutput { try? FileManager.default.removeItem(at: output) } }
        let mediaCommand = try command(for: request, outputURL: output)
        let timeout = Duration.seconds(max(1, min(15 * 60, Int(request.deadline.timeIntervalSinceNow.rounded(.up)))))
        let result = try await runner.run(executableURL: mediaCommand.executableURL, arguments: mediaCommand.arguments, environment: Self.environment, timeout: timeout)
        if result.terminationStatus != 0, Self.shouldFallbackToSoftware(mediaCommand, tools: tools) {
            try? FileManager.default.removeItem(at: output)
            let fallback = try command(for: request, outputURL: output, forceSoftwareVideo: true)
            guard request.deadline > Date() else { throw FileConvertError.timedOut }
            let remaining = Duration.seconds(max(1, min(15 * 60, Int(request.deadline.timeIntervalSinceNow.rounded(.up)))))
            let fallbackResult = try await runner.run(executableURL: fallback.executableURL, arguments: fallback.arguments, environment: Self.environment, timeout: remaining)
            guard fallbackResult.terminationStatus == 0 else { throw FileConvertError.validationFailed("FFmpeg conversion failed") }
        } else if result.terminationStatus != 0 {
            throw FileConvertError.validationFailed("FFmpeg conversion failed")
        }
        try Task.checkCancellation()
        guard Date() <= request.deadline else { throw FileConvertError.timedOut }
        var outputInfo = stat()
        guard lstat(output.path, &outputInfo) == 0,
              (outputInfo.st_mode & S_IFMT) == S_IFREG,
              outputInfo.st_size > 0,
              UInt64(outputInfo.st_size) <= request.maximumOutputBytes else {
            throw FileConvertError.validationFailed("FFmpeg output is not one bounded regular file")
        }
        retainOutput = true
        return ProducedArtifact(url: output, providerID: id)
    }

    public func command(for request: ConversionRequest, outputURL: URL, forceSoftwareVideo: Bool = false) throws -> FFmpegMediaCommand {
        guard outputURL.deletingLastPathComponent().standardizedFileURL.path == request.outputDirectory.standardizedFileURL.path else { throw FileConvertError.validationFailed("Output path escapes job directory") }
        let targetExtension = Self.normalize(request.targetExtension)
        guard let target = InstalledMediaContract.installedFormat(forExtension: targetExtension),
              target.isSupported(by: tools) else { throw FileConvertError.unsupportedPair }
        var arguments = ["-hide_banner", "-nostdin", "-v", "error", "-xerror", "-n", "-i", request.source.url.path]
        switch (target.format, request.policy) {
        case let (.audio(_), .audio(version, bitrate, sampleRate, trackIndex)):
            guard version == 1, trackIndex == nil || trackIndex! >= 0, bitrate == nil || bitrate! > 0, sampleRate == nil || sampleRate! > 0 else { throw FileConvertError.validationFailed("Invalid audio policy") }
            guard let encoder = target.requiredEncoders.first else { throw FileConvertError.unsupportedPair }
            arguments += ["-map", "0:a:\(trackIndex ?? 0)", "-vn", "-sn", "-dn", "-c:a", encoder, "-f", target.requiredMuxer]
            if let bitrate { arguments += ["-b:a", "\(bitrate)"] }
            if let sampleRate { arguments += ["-ar", "\(sampleRate)"] }
        case let (.video(format), .video(version, quality, audioTrack, subtitleTrack)):
            guard version == 1, (0...51).contains(quality), audioTrack == nil || audioTrack! >= 0, subtitleTrack == nil || subtitleTrack! >= 0 else { throw FileConvertError.validationFailed("Invalid video policy") }
            guard let videoCodec = InstalledMediaContract.videoEncoder(for: target, tools: tools, forceSoftware: forceSoftwareVideo) else { throw FileConvertError.unsupportedPair }
            arguments += ["-map", "0:v:0", "-map", "0:a:\(audioTrack ?? 0)?", "-dn", "-c:v", videoCodec]
            if videoCodec == "libvpx-vp9" {
                arguments += ["-crf", "\(quality)", "-b:v", "0"]
            } else {
                arguments += ["-q:v", "\(max(1, min(31, 1 + quality * 30 / 51)))"]
            }
            arguments += ["-c:a", format == .webM ? "libopus" : "aac", "-f", target.requiredMuxer]
            if let subtitleTrack {
                guard format == .mkv else { throw FileConvertError.validationFailed("Selected subtitles require Matroska output") }
                arguments += ["-map", "0:s:\(subtitleTrack)", "-c:s", "copy"]
            } else {
                arguments += ["-sn"]
            }
        default:
            throw FileConvertError.unsupportedPair
        }
        arguments += ["-fs", "\(request.maximumOutputBytes)", "--", outputURL.path]
        return FFmpegMediaCommand(executableURL: tools.ffmpegURL, arguments: arguments, outputURL: outputURL)
    }

    private static let environment = ["PATH": "/usr/bin:/bin", "HOME": "/var/empty", "LANG": "C"]

    private static func shouldFallbackToSoftware(_ command: FFmpegMediaCommand, tools: VerifiedMediaTools) -> Bool {
        command.arguments.contains("h264_videotoolbox") && tools.encoders.contains("mpeg4")
    }

    private static func options(
        for kind: String,
        streams: [FFprobeTrackPayload.Stream]
    ) -> [MediaTrackOption] {
        streams
            .filter { $0.codec_type == kind }
            .enumerated()
            .map { offset, stream in
                let rawDetails: [String?] = [
                    stream.tags.flatMap(\.language),
                    stream.tags.flatMap(\.title),
                    stream.codec_name,
                ]
                var details = rawDetails.compactMap { optionalValue -> String? in
                    guard let value = optionalValue, !value.isEmpty, value != "und" else { return nil }
                    return value
                }
                if details.isEmpty { details = [kind == "audio" ? "Audio" : "Subtitle"] }
                return MediaTrackOption(
                    index: offset,
                    label: "Track \(offset + 1) · \(details.joined(separator: " · "))"
                )
            }
    }

    private static func normalize(_ value: String) -> String {
        value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }
}
