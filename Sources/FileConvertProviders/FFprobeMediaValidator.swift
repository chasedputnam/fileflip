import FileConvertCore
import Foundation

public enum MediaStreamKind: String, CaseIterable, Hashable, Codable, Sendable {
    case audio
    case video
    case subtitle
}

public struct MediaValidationExpectation: Hashable, Sendable {
    /// The requested content type. This is compared to ffprobe's container facts, never the filename.
    public let target: DetectedFormat
    /// Exact counts for streams selected by the conversion policy. An omitted kind is not constrained.
    public let selectedStreamCounts: [MediaStreamKind: Int]
    /// The staged source used to establish the duration preservation bound.
    public let sourceURL: URL?
    public let maximumBytes: UInt64

    public init(
        target: DetectedFormat,
        selectedStreamCounts: [MediaStreamKind: Int] = [:],
        sourceURL: URL? = nil,
        maximumBytes: UInt64
    ) {
        self.target = target
        self.selectedStreamCounts = selectedStreamCounts
        self.sourceURL = sourceURL
        self.maximumBytes = maximumBytes
    }
}

public struct MediaStreamFacts: Codable, Hashable, Sendable {
    public let kind: MediaStreamKind
    public let codec: String
    public let frameCount: Int?
    public let sampleRate: Int?
    public let channels: Int?
    public let width: Int?
    public let height: Int?

    public init(
        kind: MediaStreamKind,
        codec: String,
        frameCount: Int?,
        sampleRate: Int?,
        channels: Int?,
        width: Int?,
        height: Int?
    ) {
        self.kind = kind
        self.codec = codec
        self.frameCount = frameCount
        self.sampleRate = sampleRate
        self.channels = channels
        self.width = width
        self.height = height
    }
}

public struct MediaFacts: Codable, Hashable, Sendable {
    public let format: DetectedFormat
    public let durationMilliseconds: Int64
    public let streams: [MediaStreamFacts]

    public init(format: DetectedFormat, durationMilliseconds: Int64, streams: [MediaStreamFacts]) {
        self.format = format
        self.durationMilliseconds = durationMilliseconds
        self.streams = streams
    }
}

public struct MediaValidationResult: Hashable, Sendable {
    public let hash: Data
    public let facts: MediaFacts

    public var format: DetectedFormat { facts.format }
    public var duration: TimeInterval { TimeInterval(facts.durationMilliseconds) / 1_000 }
    public var streamCounts: [MediaStreamKind: Int] {
        Dictionary(grouping: facts.streams, by: \.kind).mapValues(\.count)
    }
}

/// An independent, bounded ffprobe validator. It deliberately determines the
/// container from probe facts rather than from the output filename or ffmpeg's exit status.
public struct FFprobeMediaValidator: Sendable {
    public static let id = ValidatorID(rawValue: "ffprobe-media-validator-v1")
    public static let maximumProbeOutputBytes = 1 << 20

    private let tools: VerifiedMediaTools
    private let runner: BoundedProcessRunner
    private let timeout: Duration

    public init(
        tools: VerifiedMediaTools,
        timeout: Duration = .seconds(10),
        maximumProbeOutputBytes: Int = FFprobeMediaValidator.maximumProbeOutputBytes
    ) {
        self.tools = tools
        self.runner = BoundedProcessRunner(maximumOutputBytes: maximumProbeOutputBytes)
        self.timeout = timeout
    }

    public func validate(
        _ artifact: ProducedArtifact,
        expectation: MediaValidationExpectation
    ) async throws -> MediaValidationResult {
        let byteCount = try regularFileByteCount(at: artifact.url)
        guard byteCount > 0, byteCount <= expectation.maximumBytes else {
            throw FileConvertError.validationFailed("Media output is empty or exceeds its byte limit")
        }

        let output = try await probe(artifact.url)
        let target = try detectedFormat(for: output, expected: expectation.target)
        let outputDuration = try validDuration(output.duration, label: "output")
        let expectedCounts = try expectedStreamCounts(for: target, selected: expectation.selectedStreamCounts)
        let facts = try mediaFacts(for: output, target: target, duration: outputDuration)
        let counts = streamCounts(facts.streams)
        try validateDecodableSelectedStreams(output.streams, selectedCounts: expectedCounts, target: target)
        try validateStreamCounts(counts, expected: expectedCounts)

        if let sourceURL = expectation.sourceURL {
            let source = try await probe(sourceURL)
            let sourceDuration = try validDuration(source.duration, label: "source")
            let allowedDelta = max(0.250, sourceDuration * 0.005)
            guard abs(outputDuration - sourceDuration) <= allowedDelta else {
                throw FileConvertError.validationFailed("Media output duration differs from its source beyond tolerance")
            }
        }

        return MediaValidationResult(
            hash: try TransactionCoordinator.sha256(artifact.url),
            facts: facts
        )
    }

    public func certificationValidator() -> IndependentValidator {
        IndependentValidator(
            id: Self.id,
            targetExtensions: Set(InstalledMediaContract.formats.flatMap { [$0.canonicalExtension] + $0.aliases })
        ) { artifact, expected in
            let result = try await validate(
                artifact,
                expectation: MediaValidationExpectation(target: expected, maximumBytes: UInt64.max)
            )
            return (result.hash, result.format)
        }
    }

    private func probe(_ url: URL) async throws -> ProbePayload {
        let result = try await runner.run(
            executableURL: tools.ffprobeURL,
            arguments: [
                "-v", "error",
                "-err_detect", "explode",
                "-protocol_whitelist", "file,pipe",
                "-count_frames",
                "-show_entries", "format=format_name,duration:format_tags=major_brand:stream=codec_type,codec_name,nb_read_frames,duration,sample_rate,channels,width,height,disposition",
                "-of", "json",
                "--", url.path,
            ],
            timeout: timeout
        )
        guard result.terminationStatus == 0 else {
            throw FileConvertError.validationFailed("ffprobe rejected media output")
        }
        guard !result.stdout.isEmpty else {
            throw FileConvertError.validationFailed("ffprobe produced no media facts")
        }
        do {
            return try JSONDecoder().decode(ProbePayload.self, from: result.stdout)
        } catch {
            throw FileConvertError.validationFailed("ffprobe produced malformed media facts")
        }
    }

    private func regularFileByteCount(at url: URL) throws -> UInt64 {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0 else {
            throw FileConvertError.validationFailed("Media output is not a nonempty regular file")
        }
        return UInt64(size)
    }

    private func validDuration(_ string: String?, label: String) throws -> TimeInterval {
        guard let string, let duration = TimeInterval(string), duration.isFinite, duration > 0 else {
            throw FileConvertError.validationFailed("Media \(label) has no finite nonzero duration")
        }
        return duration
    }

    private func streamCounts(_ streams: [MediaStreamFacts]) -> [MediaStreamKind: Int] {
        Dictionary(grouping: streams, by: \.kind).mapValues(\.count)
    }

    private func expectedStreamCounts(
        for target: DetectedFormat,
        selected: [MediaStreamKind: Int]
    ) throws -> [MediaStreamKind: Int] {
        guard let contract = InstalledMediaContract.installedFormat(for: target) else {
            throw FileConvertError.validationFailed("Media validator received a non-media target")
        }
        var expected: [MediaStreamKind: Int] = [
            .audio: contract.defaultStreams.audio,
            .video: contract.defaultStreams.video,
            .subtitle: contract.defaultStreams.subtitle,
        ]
        for (kind, count) in selected {
            guard count >= 0 else {
                throw FileConvertError.validationFailed("Media stream selection contains a negative count")
            }
            expected[kind] = count
        }
        return expected
    }

    private func validateStreamCounts(_ actual: [MediaStreamKind: Int], expected: [MediaStreamKind: Int]) throws {
        for (kind, count) in expected {
            guard actual[kind, default: 0] == count else {
                throw FileConvertError.validationFailed("Media output does not preserve the selected \(kind.rawValue) stream count")
            }
        }
    }

    private func mediaFacts(
        for payload: ProbePayload,
        target: DetectedFormat,
        duration: TimeInterval
    ) throws -> MediaFacts {
        guard let contract = InstalledMediaContract.installedFormat(for: target) else {
            throw FileConvertError.validationFailed("Media validator received a non-media target")
        }
        let milliseconds = (duration * 1_000).rounded()
        guard milliseconds > 0, milliseconds <= Double(Int64.max) else {
            throw FileConvertError.validationFailed("Media output duration cannot be represented")
        }
        let admittedCodecs = Set(contract.admittedOutputCodecs.map { $0.lowercased() })
        let streams = try payload.streams.map { stream -> MediaStreamFacts in
            guard let kind = MediaStreamKind(rawValue: stream.codecType) else {
                throw FileConvertError.validationFailed("Media output contains an unsupported stream kind")
            }
            let codec = (stream.codecName ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !codec.isEmpty else {
                throw FileConvertError.validationFailed("Media output contains a stream without a codec")
            }
            if kind != .subtitle, !admittedCodecs.contains(codec) {
                throw FileConvertError.validationFailed("Media output contains a codec outside the installed contract")
            }

            let frameCount = try positiveInteger(stream.readFrameCount, label: "frame count")
            let streamDuration = try positiveNumber(stream.duration, label: "stream duration")
            if kind != .subtitle, frameCount == nil, streamDuration == nil {
                throw FileConvertError.validationFailed("Media output contains an undecodable stream")
            }

            let sampleRate = try positiveInteger(stream.sampleRate, label: "sample rate")
            switch kind {
            case .audio:
                guard let sampleRate, let channels = stream.channels, channels > 0,
                      stream.width == nil, stream.height == nil else {
                    throw FileConvertError.validationFailed("Media output contains invalid audio stream facts")
                }
                return MediaStreamFacts(
                    kind: kind, codec: codec, frameCount: frameCount,
                    sampleRate: sampleRate, channels: channels, width: nil, height: nil
                )
            case .video:
                guard let width = stream.width, width > 0, let height = stream.height, height > 0,
                      sampleRate == nil, stream.channels == nil else {
                    throw FileConvertError.validationFailed("Media output contains invalid video stream facts")
                }
                return MediaStreamFacts(
                    kind: kind, codec: codec, frameCount: frameCount,
                    sampleRate: nil, channels: nil, width: width, height: height
                )
            case .subtitle:
                guard sampleRate == nil, stream.channels == nil, stream.width == nil, stream.height == nil else {
                    throw FileConvertError.validationFailed("Media output contains contradictory subtitle stream facts")
                }
                return MediaStreamFacts(
                    kind: kind, codec: codec, frameCount: frameCount,
                    sampleRate: nil, channels: nil, width: nil, height: nil
                )
            }
        }
        return MediaFacts(format: target, durationMilliseconds: Int64(milliseconds), streams: streams)
    }

    private func positiveInteger(_ value: String?, label: String) throws -> Int? {
        guard let value else { return nil }
        guard let parsed = Int(value), parsed > 0 else {
            throw FileConvertError.validationFailed("Media output contains an invalid \(label)")
        }
        return parsed
    }

    private func positiveNumber(_ value: String?, label: String) throws -> Double? {
        guard let value else { return nil }
        guard let parsed = Double(value), parsed.isFinite, parsed > 0 else {
            throw FileConvertError.validationFailed("Media output contains an invalid \(label)")
        }
        return parsed
    }

    private func validateDecodableSelectedStreams(
        _ streams: [ProbePayload.Stream],
        selectedCounts: [MediaStreamKind: Int],
        target: DetectedFormat
    ) throws {
        let primaryKind: MediaStreamKind
        switch target {
        case .audio: primaryKind = .audio
        case .video: primaryKind = .video
        default: throw FileConvertError.validationFailed("Media validator received a non-media target")
        }
        // Subtitle packets are not decoded by ffprobe; their exact preservation is
        // checked by count below, while every selected audio/video stream must read.
        let requiredKinds = Set(selectedCounts.compactMap { kind, count in
            kind != .subtitle && count > 0 ? kind : nil
        }).union([primaryKind])
        for kind in requiredKinds {
            let selected = streams.filter { $0.codecType == kind.rawValue }
            guard selected.contains(where: { stream in
                guard let codec = stream.codecName, !codec.isEmpty else { return false }
                // -count_frames makes a zero/absent count evidence that ffprobe could not read frames.
                return stream.readFrameCount.flatMap(Int.init).map { $0 > 0 } ?? stream.duration.flatMap(TimeInterval.init).map { $0.isFinite && $0 > 0 } ?? false
            }) else {
                throw FileConvertError.validationFailed("Media output has no decodable selected \(kind.rawValue) stream")
            }
        }
    }

    private func detectedFormat(for payload: ProbePayload, expected: DetectedFormat) throws -> DetectedFormat {
        let names = Set((payload.formatName ?? "").split(separator: ",").map { $0.lowercased() })
        let streams = payload.streams
        let hasAudio = streams.contains { $0.codecType == MediaStreamKind.audio.rawValue && !($0.codecName ?? "").isEmpty }
        let hasVideo = streams.contains { $0.codecType == MediaStreamKind.video.rawValue && !($0.codecName ?? "").isEmpty }
        let codecs = Set(streams.compactMap(\.codecName).map { $0.lowercased() })

        guard InstalledMediaContract.installedFormat(for: expected) != nil else {
            throw FileConvertError.validationFailed("Media validator received a non-media target")
        }
        guard InstalledMediaContract.probeMatches(
            expected,
            formatNames: names,
            codecs: codecs,
            majorBrand: payload.majorBrand,
            hasAudio: hasAudio,
            hasVideo: hasVideo
        ) else {
            throw FileConvertError.validationFailed("Media content does not match the requested container")
        }
        return expected
    }


    private struct ProbePayload: Decodable {
        struct Stream: Decodable {
            let codecType: String
            let codecName: String?
            let readFrameCount: String?
            let duration: String?
            let sampleRate: String?
            let channels: Int?
            let width: Int?
            let height: Int?

            enum CodingKeys: String, CodingKey {
                case codecType = "codec_type"
                case codecName = "codec_name"
                case readFrameCount = "nb_read_frames"
                case duration
                case sampleRate = "sample_rate"
                case channels, width, height
            }
        }

        struct Format: Decodable {
            struct Tags: Decodable { let majorBrand: String?; enum CodingKeys: String, CodingKey { case majorBrand = "major_brand" } }
            let formatName: String?
            let duration: String?
            let tags: Tags?

            enum CodingKeys: String, CodingKey {
                case formatName = "format_name"
                case duration, tags
            }
        }

        let streams: [Stream]
        let format: Format?

        var formatName: String? { format?.formatName }
        var duration: String? { format?.duration }
        var majorBrand: String? { format?.tags?.majorBrand }
    }
}
