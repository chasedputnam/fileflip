import FileConvertProviders
import Foundation

public struct MatrixPlatform: Codable, Hashable, Sendable {
    public let os: String
    public let architecture: String
    enum CodingKeys: String, CodingKey, CaseIterable { case os, architecture }
    public init(os: String, architecture: String) { self.os = os; self.architecture = architecture }
    public init(from decoder: Decoder) throws {
        try rejectUnknownKeys(in: decoder, allowedBy: CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        os = try values.decode(String.self, forKey: .os)
        architecture = try values.decode(String.self, forKey: .architecture)
    }
}

public struct MatrixApplication: Codable, Hashable, Sendable {
    public let bundleIdentifier: String
    public let version: String
    public let candidateSHA256: String
    enum CodingKeys: String, CodingKey, CaseIterable { case bundleIdentifier, version, candidateSHA256 }
    public init(bundleIdentifier: String, version: String, candidateSHA256: String) {
        self.bundleIdentifier = bundleIdentifier; self.version = version; self.candidateSHA256 = candidateSHA256
    }
    public init(from decoder: Decoder) throws {
        try rejectUnknownKeys(in: decoder, allowedBy: CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        bundleIdentifier = try values.decode(String.self, forKey: .bundleIdentifier)
        version = try values.decode(String.self, forKey: .version)
        candidateSHA256 = try values.decode(String.self, forKey: .candidateSHA256)
    }
}

public struct MatrixProvider: Codable, Hashable, Sendable {
    public let ffmpegVersion: String
    public let manifestSHA256: String
    public let contractVersion: Int
    public let routeSetSHA256: String
    enum CodingKeys: String, CodingKey, CaseIterable { case ffmpegVersion, manifestSHA256, contractVersion, routeSetSHA256 }
    public init(ffmpegVersion: String, manifestSHA256: String, contractVersion: Int, routeSetSHA256: String) {
        self.ffmpegVersion = ffmpegVersion; self.manifestSHA256 = manifestSHA256
        self.contractVersion = contractVersion; self.routeSetSHA256 = routeSetSHA256
    }
    public init(from decoder: Decoder) throws {
        try rejectUnknownKeys(in: decoder, allowedBy: CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        ffmpegVersion = try values.decode(String.self, forKey: .ffmpegVersion)
        manifestSHA256 = try values.decode(String.self, forKey: .manifestSHA256)
        contractVersion = try values.decode(Int.self, forKey: .contractVersion)
        routeSetSHA256 = try values.decode(String.self, forKey: .routeSetSHA256)
    }
}

public struct MatrixSummary: Codable, Hashable, Sendable {
    public let expectedRoutes: Int
    public let executedRoutes: Int
    public let passedRoutes: Int
    public let failedRoutes: Int
    public let skippedRoutes: Int
    public let audioRoutes: Int
    public let videoRoutes: Int
    enum CodingKeys: String, CodingKey, CaseIterable {
        case expectedRoutes, executedRoutes, passedRoutes, failedRoutes, skippedRoutes, audioRoutes, videoRoutes
    }
    public init(expectedRoutes: Int, executedRoutes: Int, passedRoutes: Int, failedRoutes: Int, skippedRoutes: Int, audioRoutes: Int, videoRoutes: Int) {
        self.expectedRoutes = expectedRoutes; self.executedRoutes = executedRoutes; self.passedRoutes = passedRoutes
        self.failedRoutes = failedRoutes; self.skippedRoutes = skippedRoutes; self.audioRoutes = audioRoutes; self.videoRoutes = videoRoutes
    }
    public init(from decoder: Decoder) throws {
        try rejectUnknownKeys(in: decoder, allowedBy: CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        expectedRoutes = try values.decode(Int.self, forKey: .expectedRoutes)
        executedRoutes = try values.decode(Int.self, forKey: .executedRoutes)
        passedRoutes = try values.decode(Int.self, forKey: .passedRoutes)
        failedRoutes = try values.decode(Int.self, forKey: .failedRoutes)
        skippedRoutes = try values.decode(Int.self, forKey: .skippedRoutes)
        audioRoutes = try values.decode(Int.self, forKey: .audioRoutes)
        videoRoutes = try values.decode(Int.self, forKey: .videoRoutes)
    }
}

public struct MatrixStreamFacts: Codable, Hashable, Sendable {
    public let kind: MediaStreamKind
    public let codec: String
    public let frameCount: Int?
    public let sampleRate: Int?
    public let channels: Int?
    public let width: Int?
    public let height: Int?
    enum CodingKeys: String, CodingKey, CaseIterable { case kind, codec, frameCount, sampleRate, channels, width, height }
    public init(_ facts: MediaStreamFacts) {
        kind = facts.kind; codec = facts.codec; frameCount = facts.frameCount
        sampleRate = facts.sampleRate; channels = facts.channels; width = facts.width; height = facts.height
    }
    public init(from decoder: Decoder) throws {
        try rejectUnknownKeys(in: decoder, allowedBy: CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        kind = try values.decode(MediaStreamKind.self, forKey: .kind)
        codec = try values.decode(String.self, forKey: .codec)
        frameCount = try values.decodeIfPresent(Int.self, forKey: .frameCount)
        sampleRate = try values.decodeIfPresent(Int.self, forKey: .sampleRate)
        channels = try values.decodeIfPresent(Int.self, forKey: .channels)
        width = try values.decodeIfPresent(Int.self, forKey: .width)
        height = try values.decodeIfPresent(Int.self, forKey: .height)
    }
}

public struct MatrixObservedFacts: Codable, Hashable, Sendable {
    public let logicalFormat: String
    public let durationMilliseconds: Int64
    public let streams: [MatrixStreamFacts]
    enum CodingKeys: String, CodingKey, CaseIterable { case logicalFormat, durationMilliseconds, streams }
    public init(_ facts: MediaFacts) throws {
        guard let format = InstalledMediaContract.installedFormat(for: facts.format) else {
            throw EvidenceError.invalidReport("Observed facts contain a non-installed media format")
        }
        logicalFormat = format.canonicalExtension
        durationMilliseconds = facts.durationMilliseconds
        streams = facts.streams.map(MatrixStreamFacts.init)
    }
    public init(from decoder: Decoder) throws {
        try rejectUnknownKeys(in: decoder, allowedBy: CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        logicalFormat = try values.decode(String.self, forKey: .logicalFormat)
        durationMilliseconds = try values.decode(Int64.self, forKey: .durationMilliseconds)
        streams = try values.decode([MatrixStreamFacts].self, forKey: .streams)
    }
}

public enum MatrixRouteStatus: String, Codable, Hashable, Sendable { case passed, failed, skipped }

public struct MatrixRouteReport: Codable, Hashable, Sendable {
    public let family: String
    public let source: String
    public let target: String
    public let fixtureSHA256: String
    public let sourceBeforeSHA256: String
    public let sourceAfterSHA256: String
    public let outputSHA256: String
    public let outputByteLength: Int
    public let observedFacts: MatrixObservedFacts
    public let status: MatrixRouteStatus
    enum CodingKeys: String, CodingKey, CaseIterable {
        case family, source, target, fixtureSHA256, sourceBeforeSHA256, sourceAfterSHA256
        case outputSHA256, outputByteLength, observedFacts, status
    }
    public init(family: String, source: String, target: String, fixtureSHA256: String, sourceBeforeSHA256: String, sourceAfterSHA256: String, outputSHA256: String, outputByteLength: Int, observedFacts: MatrixObservedFacts, status: MatrixRouteStatus) {
        self.family = family; self.source = source; self.target = target; self.fixtureSHA256 = fixtureSHA256
        self.sourceBeforeSHA256 = sourceBeforeSHA256; self.sourceAfterSHA256 = sourceAfterSHA256
        self.outputSHA256 = outputSHA256; self.outputByteLength = outputByteLength; self.observedFacts = observedFacts; self.status = status
    }
    public init(from decoder: Decoder) throws {
        try rejectUnknownKeys(in: decoder, allowedBy: CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        family = try values.decode(String.self, forKey: .family)
        source = try values.decode(String.self, forKey: .source)
        target = try values.decode(String.self, forKey: .target)
        fixtureSHA256 = try values.decode(String.self, forKey: .fixtureSHA256)
        sourceBeforeSHA256 = try values.decode(String.self, forKey: .sourceBeforeSHA256)
        sourceAfterSHA256 = try values.decode(String.self, forKey: .sourceAfterSHA256)
        outputSHA256 = try values.decode(String.self, forKey: .outputSHA256)
        outputByteLength = try values.decode(Int.self, forKey: .outputByteLength)
        observedFacts = try values.decode(MatrixObservedFacts.self, forKey: .observedFacts)
        status = try values.decode(MatrixRouteStatus.self, forKey: .status)
    }
    public var identity: String { "\(family):\(source)->\(target)" }
}

public struct MatrixReport: Codable, Hashable, Sendable {
    public static let schemaVersion = 1
    public let schemaVersion: Int
    public let generatedAt: String
    public let revision: String
    public let platform: MatrixPlatform
    public let application: MatrixApplication
    public let provider: MatrixProvider
    public let summary: MatrixSummary
    public let routes: [MatrixRouteReport]
    enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, generatedAt, revision, platform, application, provider, summary, routes
    }

    public init(generatedAt: String, revision: String, platform: MatrixPlatform, application: MatrixApplication, provider: MatrixProvider, summary: MatrixSummary, routes: [MatrixRouteReport]) throws {
        schemaVersion = Self.schemaVersion
        self.generatedAt = generatedAt; self.revision = revision; self.platform = platform
        self.application = application; self.provider = provider; self.summary = summary
        self.routes = routes.sorted { Array($0.identity.utf8).lexicographicallyPrecedes(Array($1.identity.utf8)) }
        try validate()
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownKeys(in: decoder, allowedBy: CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        generatedAt = try values.decode(String.self, forKey: .generatedAt)
        revision = try values.decode(String.self, forKey: .revision)
        platform = try values.decode(MatrixPlatform.self, forKey: .platform)
        application = try values.decode(MatrixApplication.self, forKey: .application)
        provider = try values.decode(MatrixProvider.self, forKey: .provider)
        summary = try values.decode(MatrixSummary.self, forKey: .summary)
        routes = try values.decode([MatrixRouteReport].self, forKey: .routes)
        try validate()
    }

    public func validateBinding(candidateSHA256: String, manifestSHA256: String, routeSetSHA256: String) throws {
        guard application.candidateSHA256 == candidateSHA256,
              provider.manifestSHA256 == manifestSHA256,
              provider.routeSetSHA256 == routeSetSHA256 else {
            throw EvidenceError.invalidReport("Matrix report does not match the candidate, manifest, and route set")
        }
    }

    public func writeAtomically(to url: URL) throws {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(0x0A)
        try data.write(to: url, options: [.atomic])
    }

    private func validate() throws {
        let identities = routes.map(\.identity)
        let sorted = identities.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
        guard schemaVersion == Self.schemaVersion, !revision.isEmpty,
              ISO8601DateFormatter().date(from: generatedAt) != nil,
              platform.os == "macOS", platform.architecture == "arm64",
              application.bundleIdentifier == "com.chasedputnam.FileFlip", !application.version.isEmpty,
              isLowercaseSHA256(application.candidateSHA256), provider.ffmpegVersion == "8.1.2",
              isLowercaseSHA256(provider.manifestSHA256), provider.contractVersion == InstalledMediaContract.version,
              isLowercaseSHA256(provider.routeSetSHA256), identities == sorted,
              Set(identities).count == identities.count,
              summary.expectedRoutes == 76, summary.executedRoutes == routes.count,
              summary.passedRoutes == routes.count, summary.failedRoutes == 0, summary.skippedRoutes == 0,
              summary.audioRoutes == 56, summary.videoRoutes == 20,
              routes.filter({ $0.family == "audio" }).count == 56,
              routes.filter({ $0.family == "video" }).count == 20 else {
            throw EvidenceError.invalidReport("Matrix report violates its identity, ordering, or summary contract")
        }
        for route in routes {
            guard route.status == .passed, route.source != route.target,
                  route.family == "audio" || route.family == "video",
                  route.fixtureSHA256 == route.sourceBeforeSHA256,
                  route.sourceBeforeSHA256 == route.sourceAfterSHA256,
                  isLowercaseSHA256(route.fixtureSHA256), isLowercaseSHA256(route.outputSHA256),
                  route.outputByteLength > 0, route.observedFacts.logicalFormat == route.target,
                  route.observedFacts.durationMilliseconds > 0, !route.observedFacts.streams.isEmpty,
                  route.observedFacts.streams.allSatisfy({ !$0.codec.isEmpty }) else {
                throw EvidenceError.invalidReport("Matrix route violates its passing evidence contract: \(route.identity)")
            }
        }
    }
}

private struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func rejectUnknownKeys<Key: CodingKey & CaseIterable>(in decoder: Decoder, allowedBy _: Key.Type) throws {
    let allowed = Set(Key.allCases.map(\.stringValue))
    let observed = try decoder.container(keyedBy: AnyCodingKey.self).allKeys.map(\.stringValue)
    guard Set(observed).isSubset(of: allowed) else {
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown keys are forbidden"))
    }
}

private func isLowercaseSHA256(_ value: String) -> Bool {
    value.count == 64 && value.allSatisfy { $0.isNumber || ("a"..."f").contains(String($0)) }
}
