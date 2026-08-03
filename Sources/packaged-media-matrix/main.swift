import Darwin
import FileConvertCore
import FileConvertEvidence
import FileConvertProviders
import Foundation

@main
struct PackagedMediaMatrixCommand {
    static func main() async {
        do {
            let arguments = try Arguments.parse(CommandLine.arguments)
            let report = try await PackagedMediaMatrixRunner(arguments: arguments).run()
            try report.writeAtomically(to: arguments.reportURL)
            print("Packaged media matrix passed 76/76 routes: \(arguments.reportURL.path)")
        } catch {
            FileHandle.standardError.write(Data("packaged-media-matrix: \(error)\n".utf8))
            Foundation.exit(EXIT_FAILURE)
        }
    }
}

private struct Arguments: Sendable {
    let appURL: URL
    let fixturesURL: URL
    let reportURL: URL
    let revision: String

    static func parse(_ raw: [String]) throws -> Self {
        var values: [String: String] = [:]
        var index = 1
        while index < raw.count {
            let flag = raw[index]
            guard ["--app", "--fixtures", "--report"].contains(flag), index + 1 < raw.count,
                  values[flag] == nil else { throw MatrixFailure.usage }
            values[flag] = raw[index + 1]
            index += 2
        }
        guard index == raw.count,
              let appPath = values["--app"], let fixturesPath = values["--fixtures"],
              let reportPath = values["--report"], values.count == 3,
              appPath.hasPrefix("/"), fixturesPath.hasPrefix("/"), reportPath.hasPrefix("/"),
              let revision = ProcessInfo.processInfo.environment["FILECONVERT_REVISION"], !revision.isEmpty else {
            throw MatrixFailure.usage
        }
        let appURL = URL(filePath: appPath, directoryHint: .isDirectory).standardizedFileURL
        let fixturesURL = URL(filePath: fixturesPath).standardizedFileURL
        let reportURL = URL(filePath: reportPath).standardizedFileURL
        guard appURL.pathExtension == "app", !contains(reportURL, in: appURL),
              FileManager.default.fileExists(atPath: reportURL.deletingLastPathComponent().path) else {
            throw MatrixFailure.invalidInput("Candidate, fixture, or report path is invalid")
        }
        return Self(appURL: appURL, fixturesURL: fixturesURL, reportURL: reportURL, revision: revision)
    }
}

private struct PackagedMediaMatrixRunner: Sendable {
    let arguments: Arguments
    private let maximumArtifactBytes: UInt64 = 16 * 1_024 * 1_024

    func run() async throws -> MatrixReport {
        #if !arch(arm64)
        throw MatrixFailure.invalidInput("The packaged media matrix requires arm64")
        #endif
        let candidateSHA256 = try CandidateBundleHasher.sha256(of: arguments.appURL)
        guard let bundle = Bundle(url: arguments.appURL),
              bundle.bundleIdentifier == "com.chasedputnam.FileFlip",
              let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              !version.isEmpty else {
            throw MatrixFailure.invalidInput("Candidate application identity is invalid")
        }
        let mediaDirectory = try BundledMediaToolsLocator().locate(in: bundle)
        let manifestURL = mediaDirectory.appending(path: "manifest.json")
        let manifestSHA256 = try CandidateBundleHasher.fileSHA256(manifestURL)
        let components = try await PackagedMediaBootstrap().load(from: mediaDirectory)
        let probeValidator = FFprobeMediaValidator(tools: components.tools)
        let fixtureManifest = try CertifiedMediaManifest.load(from: arguments.fixturesURL)
        guard fixtureManifest.generator.ffmpegVersion == components.tools.version else {
            throw MatrixFailure.invalidInput("Certified fixtures do not match packaged media tools")
        }

        let fixtureFacts = try await certifyFixtures(fixtureManifest, validator: probeValidator)
        let actualCapabilities = await components.provider.capabilities()
        let expectedCapabilities = InstalledMediaContract.declaredCapabilities()
        guard actualCapabilities == expectedCapabilities else {
            throw MatrixFailure.invalidCapabilities
        }
        let routeSetSHA256 = try RouteSetIdentity.sha256(actualCapabilities)
        guard routeSetSHA256 == "c64bb5ac29e4f126f42e32a48b096e42668ed412bdbbdf1ab5ae3c35a155924d" else {
            throw MatrixFailure.invalidCapabilities
        }
        let orderedRoutes = try orderedCapabilities(actualCapabilities)
        var reports: [MatrixRouteReport] = []
        reports.reserveCapacity(orderedRoutes.count)
        for route in orderedRoutes {
            reports.append(try await execute(
                route: route, manifest: fixtureManifest, certifiedFacts: fixtureFacts,
                provider: components.provider, validator: probeValidator
            ))
        }
        guard try CandidateBundleHasher.sha256(of: arguments.appURL) == candidateSHA256 else {
            throw MatrixFailure.candidateChanged
        }
        let audioCount = reports.filter { $0.family == "audio" }.count
        let videoCount = reports.filter { $0.family == "video" }.count
        guard reports.count == 76, audioCount == 56, videoCount == 20 else {
            throw MatrixFailure.invalidCapabilities
        }
        return try MatrixReport(
            generatedAt: ISO8601DateFormatter().string(from: Date()), revision: arguments.revision,
            platform: MatrixPlatform(os: "macOS", architecture: "arm64"),
            application: MatrixApplication(bundleIdentifier: bundle.bundleIdentifier ?? "", version: version, candidateSHA256: candidateSHA256),
            provider: MatrixProvider(
                ffmpegVersion: components.tools.version, manifestSHA256: manifestSHA256,
                contractVersion: InstalledMediaContract.version, routeSetSHA256: routeSetSHA256
            ),
            summary: MatrixSummary(
                expectedRoutes: 76, executedRoutes: reports.count, passedRoutes: reports.count,
                failedRoutes: 0, skippedRoutes: 0, audioRoutes: audioCount, videoRoutes: videoCount
            ),
            routes: reports
        )
    }

    private func certifyFixtures(
        _ manifest: CertifiedMediaManifest,
        validator: FFprobeMediaValidator
    ) async throws -> [String: MediaFacts] {
        var certified: [String: MediaFacts] = [:]
        for fixture in manifest.fixtures {
            let sourceURL = manifest.sourceURL(for: fixture, manifestURL: arguments.fixturesURL)
            let result = try await validator.validate(
                ProducedArtifact(url: sourceURL, providerID: InstalledMediaContract.providerID),
                expectation: try expectation(for: fixture.detectedFormat, sourceURL: nil, maximumBytes: UInt64(fixture.byteLength))
            )
            try fixture.certify(observed: result.facts)
            guard result.hash.map({ String(format: "%02x", $0) }).joined() == fixture.sha256,
                  certified.updateValue(result.facts, forKey: fixture.canonicalExtension) == nil else {
                throw MatrixFailure.invalidInput("Fixture certification is incomplete or duplicated")
            }
        }
        guard certified.count == 13 else { throw MatrixFailure.invalidInput("Fixture certification is incomplete") }
        return certified
    }

    private func execute(
        route: ConversionCapability,
        manifest: CertifiedMediaManifest,
        certifiedFacts: [String: MediaFacts],
        provider: FFmpegMediaProvider,
        validator: FFprobeMediaValidator
    ) async throws -> MatrixRouteReport {
        guard let sourceContract = InstalledMediaContract.installedFormat(for: route.source),
              let targetContract = InstalledMediaContract.installedFormat(forExtension: route.targetExtension),
              let fixture = manifest.fixtures.first(where: { $0.canonicalExtension == sourceContract.canonicalExtension }),
              let expectedSourceFacts = certifiedFacts[sourceContract.canonicalExtension] else {
            throw MatrixFailure.invalidCapabilities
        }
        let sourceURL = manifest.sourceURL(for: fixture, manifestURL: arguments.fixturesURL).standardizedFileURL
        let before = try await sourceState(sourceURL, fixture: fixture, validator: validator)
        guard before.facts == expectedSourceFacts else { throw MatrixFailure.sourceChanged }

        let directory = FileManager.default.temporaryDirectory.appending(
            path: "packaged-media-route-\(UUID().uuidString)", directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = ConversionRequest(
            jobID: UUID(),
            source: Snapshot(
                url: sourceURL, fileKey: FileKey(volumeUUID: zeroUUID, fileID: before.inode),
                byteCount: UInt64(before.byteLength), modificationDate: before.modificationDate
            ),
            targetExtension: targetContract.canonicalExtension, policy: route.defaultPolicy,
            outputDirectory: directory, deadline: Date().addingTimeInterval(5 * 60),
            maximumOutputBytes: maximumArtifactBytes
        )
        let artifact = try await provider.convert(request)
        let output = try artifact.url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        let children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        guard artifact.url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL,
              children.map(\.standardizedFileURL.path) == [artifact.url.standardizedFileURL.path],
              output.isRegularFile == true, output.isSymbolicLink != true,
              let outputByteLength = output.fileSize, outputByteLength > 0,
              UInt64(outputByteLength) <= maximumArtifactBytes else {
            throw MatrixFailure.invalidOutput
        }
        let validation = try await validator.validate(
            artifact,
            expectation: try expectation(for: targetContract.format, sourceURL: sourceURL, maximumBytes: maximumArtifactBytes)
        )
        let after = try await sourceState(sourceURL, fixture: fixture, validator: validator)
        guard before == after, after.facts == expectedSourceFacts else { throw MatrixFailure.sourceChanged }
        let observed = try MatrixObservedFacts(validation.facts)
        let family = sourceContract.family.rawValue
        guard targetContract.family == sourceContract.family else { throw MatrixFailure.invalidCapabilities }
        return MatrixRouteReport(
            family: family, source: sourceContract.canonicalExtension, target: targetContract.canonicalExtension,
            fixtureSHA256: fixture.sha256, sourceBeforeSHA256: before.sha256, sourceAfterSHA256: after.sha256,
            outputSHA256: validation.hash.map { String(format: "%02x", $0) }.joined(),
            outputByteLength: outputByteLength, observedFacts: observed, status: .passed
        )
    }

    private func sourceState(
        _ url: URL,
        fixture: CertifiedMediaManifest.Fixture,
        validator: FFprobeMediaValidator
    ) async throws -> SourceState {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw MatrixFailure.sourceChanged
        }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true, let byteLength = values.fileSize,
              let modificationDate = values.contentModificationDate, byteLength == fixture.byteLength else {
            throw MatrixFailure.sourceChanged
        }
        let result = try await validator.validate(
            ProducedArtifact(url: url, providerID: InstalledMediaContract.providerID),
            expectation: try expectation(for: fixture.detectedFormat, sourceURL: nil, maximumBytes: UInt64(fixture.byteLength))
        )
        try fixture.certify(observed: result.facts)
        let sha256 = result.hash.map { String(format: "%02x", $0) }.joined()
        guard sha256 == fixture.sha256 else { throw MatrixFailure.sourceChanged }
        return SourceState(
            path: url.path, inode: UInt64(info.st_ino), byteLength: byteLength,
            modificationDate: modificationDate, sha256: sha256, facts: result.facts
        )
    }

    private func expectation(for format: DetectedFormat, sourceURL: URL?, maximumBytes: UInt64) throws -> MediaValidationExpectation {
        guard let contract = InstalledMediaContract.installedFormat(for: format) else {
            throw MatrixFailure.invalidCapabilities
        }
        var counts: [MediaStreamKind: Int] = [.audio: contract.defaultStreams.audio, .video: contract.defaultStreams.video]
        if contract.defaultStreams.subtitle > 0 { counts[.subtitle] = contract.defaultStreams.subtitle }
        return MediaValidationExpectation(
            target: format, selectedStreamCounts: counts, sourceURL: sourceURL, maximumBytes: maximumBytes
        )
    }

    private func orderedCapabilities(_ capabilities: Set<ConversionCapability>) throws -> [ConversionCapability] {
        let keyed = try capabilities.map { capability -> (String, ConversionCapability) in
            guard let source = InstalledMediaContract.installedFormat(for: capability.source),
                  let target = InstalledMediaContract.installedFormat(forExtension: capability.targetExtension) else {
                throw MatrixFailure.invalidCapabilities
            }
            return ("\(source.family.rawValue):\(source.canonicalExtension)->\(target.canonicalExtension)", capability)
        }
        return keyed.sorted { Array($0.0.utf8).lexicographicallyPrecedes(Array($1.0.utf8)) }.map(\.1)
    }
}

private struct SourceState: Equatable, Sendable {
    let path: String
    let inode: UInt64
    let byteLength: Int
    let modificationDate: Date
    let sha256: String
    let facts: MediaFacts
}

private enum MatrixFailure: Error, CustomStringConvertible {
    case usage
    case invalidInput(String)
    case invalidCapabilities
    case sourceChanged
    case candidateChanged
    case invalidOutput

    var description: String {
        switch self {
        case .usage:
            "usage: packaged-media-matrix --app /absolute/FileFlip.app --fixtures /absolute/manifest.json --report /absolute/report.json (FILECONVERT_REVISION is required)"
        case let .invalidInput(message): message
        case .invalidCapabilities: "Packaged provider capability set is not the exact installed contract"
        case .sourceChanged: "A certified source changed or failed recertification"
        case .candidateChanged: "The application candidate changed during matrix execution"
        case .invalidOutput: "A route produced an invalid output directory or artifact"
        }
    }
}

private let zeroUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

private func contains(_ candidate: URL, in root: URL) -> Bool {
    let rootComponents = root.standardizedFileURL.pathComponents
    let candidateComponents = candidate.standardizedFileURL.pathComponents
    return candidateComponents.count > rootComponents.count
        && candidateComponents.prefix(rootComponents.count).elementsEqual(rootComponents)
}
