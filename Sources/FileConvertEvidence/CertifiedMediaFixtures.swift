import CryptoKit
import FileConvertCore
import FileConvertProviders
import Foundation

public struct CertifiedMediaManifest: Decodable, Sendable {
    public struct Generator: Decodable, Sendable {
        public let ffmpegVersion: String
        public let manifestSHA256: String

        enum CodingKeys: String, CodingKey, CaseIterable {
            case ffmpegVersion
            case manifestSHA256
        }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            try rejectUnknownKeys(in: decoder, allowedBy: CodingKeys.self)
            ffmpegVersion = try values.decode(String.self, forKey: .ffmpegVersion)
            manifestSHA256 = try values.decode(String.self, forKey: .manifestSHA256)
        }
    }

    public struct Fixture: Decodable, Sendable {
        public let id: String
        public let family: String
        public let format: String
        public let canonicalExtension: String
        public let path: String
        public let sha256: String
        public let byteLength: Int
        public let license: String
        public let provenance: String
        public let facts: Facts

        enum CodingKeys: String, CodingKey, CaseIterable {
            case id, family, format, canonicalExtension, path, sha256, byteLength, license, provenance, facts
        }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            try rejectUnknownKeys(in: decoder, allowedBy: CodingKeys.self)
            id = try values.decode(String.self, forKey: .id)
            family = try values.decode(String.self, forKey: .family)
            format = try values.decode(String.self, forKey: .format)
            canonicalExtension = try values.decode(String.self, forKey: .canonicalExtension)
            path = try values.decode(String.self, forKey: .path)
            sha256 = try values.decode(String.self, forKey: .sha256)
            byteLength = try values.decode(Int.self, forKey: .byteLength)
            license = try values.decode(String.self, forKey: .license)
            provenance = try values.decode(String.self, forKey: .provenance)
            facts = try values.decode(Facts.self, forKey: .facts)
        }

        public var detectedFormat: DetectedFormat {
            get throws {
                guard let detected = InstalledMediaContract.format(forExtension: canonicalExtension) else {
                    throw CertifiedMediaFixtureError.invalid("Unknown certified format extension: \(canonicalExtension)")
                }
                return detected
            }
        }

        public func certify(observed: MediaFacts) throws {
            guard observed.format == (try detectedFormat),
                  observed.durationMilliseconds == Int64(facts.durationMilliseconds),
                  observed.streams.count == facts.streams.count else {
                throw CertifiedMediaFixtureError.invalid("Observed facts do not match certified fixture: \(id)")
            }
            for (actual, expected) in zip(observed.streams, facts.streams) {
                guard actual.kind == expected.kind, actual.codec == expected.codec,
                      actual.frameCount == expected.frameCount, actual.sampleRate == expected.sampleRate,
                      actual.channels == expected.channels, actual.width == expected.width,
                      actual.height == expected.height else {
                    throw CertifiedMediaFixtureError.invalid("Observed stream facts do not match certified fixture: \(id)")
                }
            }
        }
    }

    public struct Facts: Decodable, Sendable {
        public let formatNames: [String]
        public let majorBrand: String?
        public let durationMilliseconds: Int
        public let streams: [Stream]

        enum CodingKeys: String, CodingKey, CaseIterable {
            case formatNames, majorBrand, durationMilliseconds, streams
        }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            try rejectUnknownKeys(in: decoder, allowedBy: CodingKeys.self)
            formatNames = try values.decode([String].self, forKey: .formatNames)
            majorBrand = try values.decodeIfPresent(String.self, forKey: .majorBrand)
            durationMilliseconds = try values.decode(Int.self, forKey: .durationMilliseconds)
            streams = try values.decode([Stream].self, forKey: .streams)
        }
    }

    public struct Stream: Decodable, Sendable {
        public let kind: MediaStreamKind
        public let codec: String
        public let frameCount: Int
        public let sampleRate: Int?
        public let channels: Int?
        public let width: Int?
        public let height: Int?

        enum CodingKeys: String, CodingKey, CaseIterable {
            case kind, codec, frameCount, sampleRate, channels, width, height
        }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            try rejectUnknownKeys(in: decoder, allowedBy: CodingKeys.self)
            kind = try values.decode(MediaStreamKind.self, forKey: .kind)
            codec = try values.decode(String.self, forKey: .codec)
            frameCount = try values.decode(Int.self, forKey: .frameCount)
            sampleRate = try values.decodeIfPresent(Int.self, forKey: .sampleRate)
            channels = try values.decodeIfPresent(Int.self, forKey: .channels)
            width = try values.decodeIfPresent(Int.self, forKey: .width)
            height = try values.decodeIfPresent(Int.self, forKey: .height)
        }
    }

    public let schemaVersion: Int
    public let recipeVersion: Int
    public let generator: Generator
    public let fixtures: [Fixture]

    enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, recipeVersion, generator, fixtures
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try rejectUnknownKeys(in: decoder, allowedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        recipeVersion = try values.decode(Int.self, forKey: .recipeVersion)
        generator = try values.decode(Generator.self, forKey: .generator)
        fixtures = try values.decode([Fixture].self, forKey: .fixtures)
        try validateContract()
    }

    public static func load(from manifestURL: URL) throws -> CertifiedMediaManifest {
        let manifest = try JSONDecoder().decode(Self.self, from: Data(contentsOf: manifestURL))
        let root = manifestURL.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        for fixture in manifest.fixtures {
            let url = root.appending(path: fixture.path).standardizedFileURL
            guard url.path.hasPrefix(root.path + "/") else {
                throw CertifiedMediaFixtureError.invalid("Fixture path escapes its root: \(fixture.path)")
            }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, values.fileSize == fixture.byteLength,
                  fixture.byteLength > 0, fixture.byteLength <= 2 * 1_024 * 1_024 else {
                throw CertifiedMediaFixtureError.invalid("Fixture bytes do not satisfy the manifest: \(fixture.path)")
            }
            let digest = SHA256.hash(data: try Data(contentsOf: url, options: [.mappedIfSafe]))
                .map { String(format: "%02x", $0) }.joined()
            guard digest == fixture.sha256 else {
                throw CertifiedMediaFixtureError.invalid("Fixture hash does not match: \(fixture.path)")
            }
        }
        return manifest
    }

    public func sourceURL(for fixture: Fixture, manifestURL: URL) -> URL {
        manifestURL.deletingLastPathComponent().appending(path: fixture.path)
    }

    private func validateContract() throws {
        let expected = [
            ("audio-mp3", "audio", "mp3", "mp3"), ("audio-m4a", "audio", "m4a", "m4a"),
            ("audio-aac", "audio", "aac", "aac"),
            ("audio-wav", "audio", "wav", "wav"), ("audio-aiff", "audio", "aiff", "aiff"),
            ("audio-flac", "audio", "flac", "flac"), ("audio-ogg", "audio", "ogg", "ogg"),
            ("audio-opus", "audio", "opus", "opus"), ("video-mp4", "video", "mp4", "mp4"),
            ("video-m4v", "video", "m4v", "m4v"), ("video-mov", "video", "mov", "mov"),
            ("video-mkv", "video", "mkv", "mkv"), ("video-webm", "video", "webm", "webm"),
        ]
        guard schemaVersion == 1, recipeVersion == 1, generator.ffmpegVersion == "8.1.2",
              isLowercaseSHA256(generator.manifestSHA256), fixtures.count == expected.count else {
            throw CertifiedMediaFixtureError.invalid("Unsupported certified fixture manifest contract")
        }
        guard Set(fixtures.map(\.id)).count == fixtures.count, Set(fixtures.map(\.path)).count == fixtures.count else {
            throw CertifiedMediaFixtureError.invalid("Duplicate certified fixture ID or path")
        }
        for (fixture, contract) in zip(fixtures, expected) {
            guard fixture.id == contract.0, fixture.family == contract.1, fixture.format == contract.2,
                  fixture.canonicalExtension == contract.3,
                  fixture.path == "\(contract.1)/source.\(contract.3)",
                  fixture.license == "CC0-1.0",
                  fixture.provenance == "FileFlip deterministic synthetic media recipe v1",
                  isLowercaseSHA256(fixture.sha256), fixture.byteLength > 0,
                  fixture.facts.durationMilliseconds >= 900, fixture.facts.durationMilliseconds <= 2_000,
                  !fixture.facts.formatNames.isEmpty, fixture.facts.formatNames.allSatisfy({ !$0.isEmpty }),
                  !fixture.facts.streams.isEmpty else {
                throw CertifiedMediaFixtureError.invalid("Invalid certified fixture record: \(fixture.id)")
            }
            let expectedKinds: [MediaStreamKind] = fixture.family == "audio" ? [.audio] : [.video, .audio]
            guard fixture.facts.streams.map(\.kind) == expectedKinds else {
                throw CertifiedMediaFixtureError.invalid("Invalid stream contract: \(fixture.id)")
            }
            for stream in fixture.facts.streams {
                let commonValid = !stream.codec.isEmpty && stream.frameCount > 0
                let shapeValid = switch stream.kind {
                case .audio:
                    stream.sampleRate == 48_000 && stream.channels == 1 && stream.width == nil && stream.height == nil
                case .video:
                    stream.width == 160 && stream.height == 90 && stream.sampleRate == nil && stream.channels == nil
                case .subtitle:
                    false
                }
                guard commonValid, shapeValid else {
                    throw CertifiedMediaFixtureError.invalid("Invalid stream facts: \(fixture.id)")
                }
            }
        }
    }
}

public enum CertifiedMediaFixtureError: Error, Equatable, Sendable {
    case invalid(String)
}

private struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func rejectUnknownKeys<Key: CodingKey & CaseIterable>(
    in decoder: Decoder,
    allowedBy _: Key.Type
) throws {
    let allowed = Set(Key.allCases.map(\.stringValue))
    let observed = try decoder.container(keyedBy: AnyCodingKey.self).allKeys.map(\.stringValue)
    guard Set(observed).isSubset(of: allowed) else {
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown keys are forbidden"))
    }
}

private func isLowercaseSHA256(_ value: String) -> Bool {
    value.count == 64 && value.allSatisfy { $0.isNumber || ("a"..."f").contains(String($0)) }
}
