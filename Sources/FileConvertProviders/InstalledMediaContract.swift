import FileConvertCore
import Foundation

public struct InstalledMediaStreamContract: Hashable, Sendable {
    public let audio: Int
    public let video: Int
    public let subtitle: Int

    public init(audio: Int, video: Int, subtitle: Int = 0) {
        self.audio = audio
        self.video = video
        self.subtitle = subtitle
    }
}

public struct InstalledMediaFormat: Hashable, Sendable {
    public enum Family: String, Hashable, Sendable {
        case audio
        case video
    }

    public let format: DetectedFormat
    public let family: Family
    public let canonicalExtension: String
    public let aliases: Set<String>
    public let requiredEncoders: Set<String>
    public let requiredMuxer: String
    public let admittedOutputCodecs: Set<String>
    public let defaultPolicy: ConversionPolicy
    public let defaultStreams: InstalledMediaStreamContract
    public let preferredVideoEncoder: String?
    public let softwareVideoEncoder: String?

    public init(
        format: DetectedFormat,
        family: Family,
        canonicalExtension: String,
        aliases: Set<String> = [],
        requiredEncoders: Set<String>,
        requiredMuxer: String,
        admittedOutputCodecs: Set<String>,
        defaultPolicy: ConversionPolicy,
        defaultStreams: InstalledMediaStreamContract,
        preferredVideoEncoder: String? = nil,
        softwareVideoEncoder: String? = nil
    ) {
        self.format = format
        self.family = family
        self.canonicalExtension = canonicalExtension
        self.aliases = aliases
        self.requiredEncoders = requiredEncoders
        self.requiredMuxer = requiredMuxer
        self.admittedOutputCodecs = admittedOutputCodecs
        self.defaultPolicy = defaultPolicy
        self.defaultStreams = defaultStreams
        self.preferredVideoEncoder = preferredVideoEncoder
        self.softwareVideoEncoder = softwareVideoEncoder
    }

    public func isSupported(by tools: VerifiedMediaTools) -> Bool {
        requiredEncoders.isSubset(of: tools.encoders) && tools.muxers.contains(requiredMuxer)
    }
}

public enum InstalledMediaContract {
    public static let version = 1
    public static let providerID = ProviderID(rawValue: "ffmpeg")

    public static let formats: [InstalledMediaFormat] = [
        audio(.mp3, extension: "mp3", encoder: "libmp3lame", muxer: "mp3", codecs: ["mp3"]),
        audio(.m4a, extension: "m4a", encoder: "aac", muxer: "ipod", codecs: ["aac"]),
        audio(.aac, extension: "aac", encoder: "aac", muxer: "adts", codecs: ["aac"]),
        audio(.wav, extension: "wav", encoder: "pcm_s16le", muxer: "wav", codecs: ["pcm_s16le"]),
        audio(.aiff, extension: "aiff", aliases: ["aif"], encoder: "pcm_s16be", muxer: "aiff", codecs: ["pcm_s16be"]),
        audio(.flac, extension: "flac", encoder: "flac", muxer: "flac", codecs: ["flac"]),
        audio(.ogg, extension: "ogg", encoder: "libvorbis", muxer: "ogg", codecs: ["vorbis"]),
        audio(.opus, extension: "opus", encoder: "libopus", muxer: "opus", codecs: ["opus"]),
        video(.mp4, extension: "mp4", muxer: "mp4"),
        video(.m4v, extension: "m4v", muxer: "mp4"),
        video(.mov, extension: "mov", muxer: "mov"),
        video(.mkv, extension: "mkv", muxer: "matroska"),
        InstalledMediaFormat(
            format: .video(.webM),
            family: .video,
            canonicalExtension: "webm",
            requiredEncoders: ["libvpx-vp9", "libopus"],
            requiredMuxer: "webm",
            admittedOutputCodecs: ["vp9", "opus"],
            defaultPolicy: .video(),
            defaultStreams: InstalledMediaStreamContract(audio: 1, video: 1),
            softwareVideoEncoder: "libvpx-vp9"
        ),
    ]

    public static func installedFormat(for format: DetectedFormat) -> InstalledMediaFormat? {
        formats.first { $0.format == format }
    }

    public static func installedFormat(forExtension fileExtension: String) -> InstalledMediaFormat? {
        let normalized = normalize(fileExtension)
        return formats.first { $0.canonicalExtension == normalized || $0.aliases.contains(normalized) }
    }

    public static func format(forExtension fileExtension: String) -> DetectedFormat? {
        installedFormat(forExtension: fileExtension)?.format
    }

    public static func declaredCapabilities() -> Set<ConversionCapability> {
        Set(formats.flatMap { source in
            formats.compactMap { target in
                guard source.family == target.family, source.format != target.format else { return nil }
                return ConversionCapability(
                    source: source.format,
                    targetExtension: target.canonicalExtension,
                    providerID: providerID,
                    defaultPolicy: target.defaultPolicy,
                    lossProfile: .potentiallyLossy
                )
            }
        })
    }

    public static func supportedFormats(for tools: VerifiedMediaTools) -> [InstalledMediaFormat] {
        formats.filter { $0.isSupported(by: tools) }
    }

    public static func capabilities(for tools: VerifiedMediaTools) -> Set<ConversionCapability> {
        let targets = supportedFormats(for: tools)
        return Set(formats.flatMap { source in
            targets.compactMap { target in
                guard source.family == target.family, source.format != target.format else { return nil }
                return ConversionCapability(
                    source: source.format,
                    targetExtension: target.canonicalExtension,
                    providerID: providerID,
                    defaultPolicy: target.defaultPolicy,
                    lossProfile: .potentiallyLossy
                )
            }
        })
    }

    public static func videoEncoder(
        for target: InstalledMediaFormat,
        tools: VerifiedMediaTools,
        forceSoftware: Bool
    ) -> String? {
        guard target.family == .video, let software = target.softwareVideoEncoder else { return nil }
        if !forceSoftware,
           let preferred = target.preferredVideoEncoder,
           tools.encoders.contains(preferred) {
            return preferred
        }
        return tools.encoders.contains(software) ? software : nil
    }

    public static func detectedFormat(
        formatNames: Set<String>,
        codecs: Set<String>,
        majorBrand: String?,
        hasAudio: Bool,
        hasVideo: Bool
    ) -> DetectedFormat? {
        let brand = majorBrand?.lowercased() ?? ""
        return formats.reversed().first {
            if $0.format == .video(.m4v), !brand.contains("m4v") {
                return false
            }
            return probeMatches(
                $0.format,
                formatNames: formatNames,
                codecs: codecs,
                majorBrand: majorBrand,
                hasAudio: hasAudio,
                hasVideo: hasVideo
            )
        }?.format
    }

    public static func probeMatches(
        _ format: DetectedFormat,
        formatNames: Set<String>,
        codecs: Set<String>,
        majorBrand: String?,
        hasAudio: Bool,
        hasVideo: Bool
    ) -> Bool {
        let names = Set(formatNames.map { $0.lowercased() })
        let observedCodecs = Set(codecs.map { $0.lowercased() })
        let brand = majorBrand?.lowercased() ?? ""
        let isISOBaseMedia = !names.isDisjoint(with: ["mov", "mp4", "m4a", "3gp", "3g2", "mj2"])

        switch format {
        case .audio(.mp3): return hasAudio && !hasVideo && names.contains("mp3")
        case .audio(.m4a): return hasAudio && !hasVideo && isISOBaseMedia && observedCodecs.contains("aac")
        case .audio(.aac): return hasAudio && !hasVideo && names.contains("aac") && observedCodecs.contains("aac")
        case .audio(.wav): return hasAudio && !hasVideo && names.contains("wav")
        case .audio(.aiff): return hasAudio && !hasVideo && names.contains("aiff")
        case .audio(.flac): return hasAudio && !hasVideo && names.contains("flac")
        case .audio(.ogg): return hasAudio && !hasVideo && (names.contains("ogg") || names.contains("oga")) && !observedCodecs.contains("opus")
        case .audio(.opus): return hasAudio && !hasVideo && (names.contains("ogg") || names.contains("oga")) && observedCodecs.contains("opus")
        case .video(.mp4): return hasVideo && isISOBaseMedia && !brand.contains("qt") && !brand.contains("m4v")
        case .video(.m4v): return hasVideo && isISOBaseMedia && !brand.contains("qt")
        case .video(.mov): return hasVideo && isISOBaseMedia && brand.contains("qt")
        case .video(.mkv): return hasVideo && names.contains("matroska")
        case .video(.webM): return hasVideo && names.contains("webm")
        default: return false
        }
    }

    private static func audio(
        _ format: AudioFormat,
        extension fileExtension: String,
        aliases: Set<String> = [],
        encoder: String,
        muxer: String,
        codecs: Set<String>
    ) -> InstalledMediaFormat {
        InstalledMediaFormat(
            format: .audio(format),
            family: .audio,
            canonicalExtension: fileExtension,
            aliases: aliases,
            requiredEncoders: [encoder],
            requiredMuxer: muxer,
            admittedOutputCodecs: codecs,
            defaultPolicy: .audio(),
            defaultStreams: InstalledMediaStreamContract(audio: 1, video: 0)
        )
    }

    private static func video(_ format: VideoFormat, extension fileExtension: String, muxer: String) -> InstalledMediaFormat {
        InstalledMediaFormat(
            format: .video(format),
            family: .video,
            canonicalExtension: fileExtension,
            requiredEncoders: ["mpeg4", "aac"],
            requiredMuxer: muxer,
            admittedOutputCodecs: ["mpeg4", "h264", "aac"],
            defaultPolicy: .video(),
            defaultStreams: InstalledMediaStreamContract(audio: 1, video: 1),
            preferredVideoEncoder: "h264_videotoolbox",
            softwareVideoEncoder: "mpeg4"
        )
    }

    private static func normalize(_ value: String) -> String {
        value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }
}
