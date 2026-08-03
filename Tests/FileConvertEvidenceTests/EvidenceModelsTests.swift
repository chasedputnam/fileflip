import FileConvertCore
import FileConvertEvidence
import FileConvertProviders
import Foundation
import Testing

@Test
func candidateBundleDigestIsStableAndSensitiveToBytesModesAndPaths() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "candidate-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root.appending(path: "nested", directoryHint: .isDirectory), withIntermediateDirectories: true)
    let executable = root.appending(path: "tool")
    let resource = root.appending(path: "nested/value.txt")
    try Data("tool".utf8).write(to: executable)
    try Data("value".utf8).write(to: resource)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let first = try CandidateBundleHasher.sha256(of: root)
    #expect(try first == CandidateBundleHasher.sha256(of: root))

    try Data("changed".utf8).write(to: resource)
    #expect(try CandidateBundleHasher.sha256(of: root) != first)
    try Data("value".utf8).write(to: resource)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: executable.path)
    #expect(try CandidateBundleHasher.sha256(of: root) != first)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    try FileManager.default.moveItem(at: resource, to: root.appending(path: "nested/renamed.txt"))
    #expect(try CandidateBundleHasher.sha256(of: root) != first)
}

@Test
func candidateBundleDigestHashesContainedSymlinksAndRejectsEscapes() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "candidate-link-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("value".utf8).write(to: root.appending(path: "value"))
    let link = root.appending(path: "link")
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "value")
    let contained = try CandidateBundleHasher.sha256(of: root)
    try FileManager.default.removeItem(at: link)
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/etc/hosts")
    #expect(throws: EvidenceError.self) { try CandidateBundleHasher.sha256(of: root) }
    try FileManager.default.removeItem(at: link)
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "value")
    #expect(try contained == CandidateBundleHasher.sha256(of: root))
}

@Test
func installedRouteSetDigestIsStableAndComplete() throws {
    let tools = completeVerifiedTools()
    let firstCapabilities = InstalledMediaContract.capabilities(for: tools)
    let secondCapabilities = Set(firstCapabilities.reversed())
    let normalized = try RouteSetIdentity.normalizedRoutes(firstCapabilities)
    #expect(normalized.count == 76)
    #expect(normalized.filter { $0.hasPrefix("audio:") }.count == 56)
    #expect(normalized.filter { $0.hasPrefix("video:") }.count == 20)
    #expect(try RouteSetIdentity.sha256(firstCapabilities) == RouteSetIdentity.sha256(secondCapabilities))
    #expect(try RouteSetIdentity.sha256(firstCapabilities) == "c64bb5ac29e4f126f42e32a48b096e42668ed412bdbbdf1ab5ae3c35a155924d")
}

@Test
func routeSetDigestRejectsNoncanonicalRoutes() throws {
    let invalid = ConversionCapability(
        source: .audio(.mp3), targetExtension: "MP3", providerID: InstalledMediaContract.providerID,
        defaultPolicy: .audio(), lossProfile: .potentiallyLossy
    )
    #expect(throws: EvidenceError.self) { try RouteSetIdentity.sha256([invalid]) }
}

@Test
func matrixReportRoundTripsStrictlyAndWritesStableAtomicJSON() throws {
    let report = try passingReport()
    let root = FileManager.default.temporaryDirectory.appending(path: "report-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appending(path: "matrix.json")
    try report.writeAtomically(to: url)
    let first = try Data(contentsOf: url)
    try report.writeAtomically(to: url)
    #expect(try Data(contentsOf: url) == first)
    let decoded = try JSONDecoder().decode(MatrixReport.self, from: first)
    try decoded.validateBinding(candidateSHA256: hex("a"), manifestSHA256: hex("b"), routeSetSHA256: hex("c"))
    #expect(throws: EvidenceError.self) {
        try decoded.validateBinding(candidateSHA256: hex("d"), manifestSHA256: hex("b"), routeSetSHA256: hex("c"))
    }
}

@Test
func matrixReportRejectsUnknownFieldsAndDuplicateRoutes() throws {
    let report = try passingReport()
    let encoded = try JSONEncoder().encode(report)
    var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object["unknown"] = true
    #expect(throws: Error.self) {
        try JSONDecoder().decode(MatrixReport.self, from: JSONSerialization.data(withJSONObject: object))
    }

    object.removeValue(forKey: "unknown")
    var routes = try #require(object["routes"] as? [[String: Any]])
    routes[1] = routes[0]
    object["routes"] = routes
    #expect(throws: Error.self) {
        try JSONDecoder().decode(MatrixReport.self, from: JSONSerialization.data(withJSONObject: object))
    }
}

private func completeVerifiedTools() -> VerifiedMediaTools {
    VerifiedMediaTools(
        ffmpegURL: URL(filePath: "/verified/ffmpeg"), ffprobeURL: URL(filePath: "/verified/ffprobe"), version: "8.1.2",
        encoders: ["aac", "flac", "libmp3lame", "libopus", "libvorbis", "libvpx-vp9", "mpeg4", "pcm_s16be", "pcm_s16le"],
        muxers: ["adts", "aiff", "flac", "ipod", "matroska", "mov", "mp3", "mp4", "ogg", "opus", "wav", "webm"],
        demuxers: ["aac", "aiff", "flac", "matroska", "mov", "mp3", "ogg", "wav"]
    )
}

private func passingReport() throws -> MatrixReport {
    let capabilities = InstalledMediaContract.capabilities(for: completeVerifiedTools())
    let identities = try RouteSetIdentity.normalizedRoutes(capabilities)
    let routes = try identities.map { identity -> MatrixRouteReport in
        let line = identity.trimmingCharacters(in: .newlines)
        let familyAndRoute = line.split(separator: ":", maxSplits: 1).map(String.init)
        let endpoints = familyAndRoute[1].split(separator: "->", maxSplits: 1).map(String.init)
        let family = familyAndRoute[0]
        let target = endpoints[1]
        let streams: [MediaStreamFacts] = family == "audio"
            ? [MediaStreamFacts(kind: .audio, codec: "aac", frameCount: 48, sampleRate: 48_000, channels: 1, width: nil, height: nil)]
            : [
                MediaStreamFacts(kind: .video, codec: "mpeg4", frameCount: 24, sampleRate: nil, channels: nil, width: 160, height: 90),
                MediaStreamFacts(kind: .audio, codec: "aac", frameCount: 48, sampleRate: 48_000, channels: 1, width: nil, height: nil),
            ]
        let format = try #require(InstalledMediaContract.format(forExtension: target))
        let observed = try MatrixObservedFacts(MediaFacts(format: format, durationMilliseconds: 1_000, streams: streams))
        return MatrixRouteReport(
            family: family, source: endpoints[0], target: target,
            fixtureSHA256: hex("d"), sourceBeforeSHA256: hex("d"), sourceAfterSHA256: hex("d"),
            outputSHA256: hex("e"), outputByteLength: 1_024, observedFacts: observed, status: .passed
        )
    }
    return try MatrixReport(
        generatedAt: "2026-07-29T00:00:00Z", revision: "test-revision",
        platform: MatrixPlatform(os: "macOS", architecture: "arm64"),
        application: MatrixApplication(bundleIdentifier: "com.chasedputnam.FileFlip", version: "1.0", candidateSHA256: hex("a")),
        provider: MatrixProvider(ffmpegVersion: "8.1.2", manifestSHA256: hex("b"), contractVersion: 1, routeSetSHA256: hex("c")),
        summary: MatrixSummary(expectedRoutes: 76, executedRoutes: 76, passedRoutes: 76, failedRoutes: 0, skippedRoutes: 0, audioRoutes: 56, videoRoutes: 20),
        routes: routes
    )
}

private func hex(_ character: Character) -> String { String(repeating: character, count: 64) }
