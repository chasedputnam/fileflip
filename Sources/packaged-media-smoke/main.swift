import Darwin
import FileConvertCore
import FileConvertEvidence
import FileConvertProviders
import Foundation

@main
struct PackagedMediaSmokeCommand {
    static func main() async {
        do {
            try await InstalledMediaSmoke(arguments: try Arguments.parse(CommandLine.arguments)).run()
            print("Installed packaged media smoke passed: mp3->opus, mp4->webm")
        } catch {
            FileHandle.standardError.write(Data("packaged-media-smoke: \(error)\n".utf8))
            Foundation.exit(EXIT_FAILURE)
        }
    }
}

private struct Arguments: Sendable {
    let appURL: URL
    let fixtureManifestURL: URL

    static func parse(_ raw: [String]) throws -> Self {
        var values: [String: String] = [:]
        var index = 1
        while index < raw.count {
            let flag = raw[index]
            guard ["--app", "--fixtures"].contains(flag), index + 1 < raw.count,
                  values[flag] == nil else { throw SmokeFailure.usage }
            values[flag] = raw[index + 1]
            index += 2
        }
        guard index == raw.count, values.count == 2,
              let app = values["--app"], let fixtures = values["--fixtures"],
              app.hasPrefix("/"), fixtures.hasPrefix("/") else { throw SmokeFailure.usage }
        let appURL = URL(filePath: app, directoryHint: .isDirectory).standardizedFileURL
        let fixtureManifestURL = URL(filePath: fixtures).standardizedFileURL
        guard appURL.pathExtension == "app", FileManager.default.fileExists(atPath: fixtureManifestURL.path) else {
            throw SmokeFailure.invalidInput("Candidate or fixture manifest path is invalid")
        }
        return Self(appURL: appURL, fixtureManifestURL: fixtureManifestURL)
    }
}

private struct InstalledMediaSmoke: Sendable {
    let arguments: Arguments
    private let maximumArtifactBytes: UInt64 = 16 * 1_024 * 1_024

    func run() async throws {
        #if !arch(arm64)
        throw SmokeFailure.invalidInput("Installed media smoke requires arm64")
        #endif
        let fileManager = FileManager.default
        let sourceCandidateSHA256 = try CandidateBundleHasher.sha256(of: arguments.appURL)
        let root = fileManager.temporaryDirectory.appending(
            path: "fileflip-installed-media-smoke-\(UUID().uuidString)", directoryHint: .isDirectory
        )
        let applications = root.appending(path: "Applications", directoryHint: .isDirectory)
        let installedApp = applications.appending(path: "FileFlip.app", directoryHint: .isDirectory)
        let sentinelDirectory = root.appending(path: "ambient-bin", directoryHint: .isDirectory)
        let emptyHome = root.appending(path: "home", directoryHint: .isDirectory)
        let sentinelMarker = root.appending(path: "ambient-media-tool-invoked")
        try fileManager.createDirectory(at: applications, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: sentinelDirectory, withIntermediateDirectories: false)
        try fileManager.createDirectory(at: emptyHome, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.copyItem(at: arguments.appURL, to: installedApp)
        guard try CandidateBundleHasher.sha256(of: installedApp) == sourceCandidateSHA256 else {
            throw SmokeFailure.invalidInput("Relocated application bytes differ from the candidate")
        }
        try installSentinels(in: sentinelDirectory, marker: sentinelMarker)

        let environment = SanitizedEnvironment(
            values: ["PATH": sentinelDirectory.path, "HOME": emptyHome.path, "LANG": "C", "LC_ALL": "C"]
        )
        defer { environment.restore() }
        environment.apply()

        guard let bundle = Bundle(url: installedApp),
              bundle.bundleIdentifier == "app.fileconvert.FileConvert" else {
            throw SmokeFailure.invalidInput("Relocated application identity is invalid")
        }
        let mediaDirectory = try BundledMediaToolsLocator().locate(in: bundle)
        let components = try await PackagedMediaBootstrap().load(from: mediaDirectory)
        guard await components.provider.capabilities() == InstalledMediaContract.declaredCapabilities() else {
            throw SmokeFailure.invalidInput("Relocated application did not expose the installed media contract")
        }
        let validator = FFprobeMediaValidator(tools: components.tools)
        let fixtureManifest = try CertifiedMediaManifest.load(from: arguments.fixtureManifestURL)
        let manifestSHA256 = try CandidateBundleHasher.fileSHA256(mediaDirectory.appending(path: "manifest.json"))
        guard fixtureManifest.generator.ffmpegVersion == components.tools.version,
              fixtureManifest.generator.manifestSHA256 == manifestSHA256 else {
            throw SmokeFailure.invalidInput("Certified fixtures do not match the relocated application tools")
        }

        try await execute(
            sourceExtension: "mp3", targetExtension: "opus", manifest: fixtureManifest,
            provider: components.provider, validator: validator, root: root
        )
        try await execute(
            sourceExtension: "mp4", targetExtension: "webm", manifest: fixtureManifest,
            provider: components.provider, validator: validator, root: root
        )
        guard !fileManager.fileExists(atPath: sentinelMarker.path) else {
            throw SmokeFailure.ambientToolExecuted
        }
        guard try CandidateBundleHasher.sha256(of: installedApp) == sourceCandidateSHA256 else {
            throw SmokeFailure.invalidInput("Relocated application changed during smoke execution")
        }
    }

    private func execute(
        sourceExtension: String,
        targetExtension: String,
        manifest: CertifiedMediaManifest,
        provider: FFmpegMediaProvider,
        validator: FFprobeMediaValidator,
        root: URL
    ) async throws {
        guard let sourceContract = InstalledMediaContract.installedFormat(forExtension: sourceExtension),
              let targetContract = InstalledMediaContract.installedFormat(forExtension: targetExtension),
              sourceContract.family == targetContract.family,
              let fixture = manifest.fixtures.first(where: { $0.canonicalExtension == sourceExtension }) else {
            throw SmokeFailure.invalidInput("Smoke route is absent from the installed contract")
        }
        let sourceURL = manifest.sourceURL(for: fixture, manifestURL: arguments.fixtureManifestURL).standardizedFileURL
        let sourceSHA256 = try CandidateBundleHasher.fileSHA256(sourceURL)
        var sourceInfo = stat()
        guard lstat(sourceURL.path, &sourceInfo) == 0, (sourceInfo.st_mode & S_IFMT) == S_IFREG else {
            throw SmokeFailure.sourceChanged
        }
        let sourceValues = try sourceURL.resourceValues(
            forKeys: [.fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey]
        )
        guard sourceValues.isSymbolicLink != true, let byteCount = sourceValues.fileSize,
              let modificationDate = sourceValues.contentModificationDate,
              byteCount == fixture.byteLength,
              sourceSHA256 == fixture.sha256 else { throw SmokeFailure.sourceChanged }
        let sourceValidation = try await validator.validate(
            ProducedArtifact(url: sourceURL, providerID: InstalledMediaContract.providerID),
            expectation: expectation(for: sourceContract, sourceURL: nil, maximumBytes: UInt64(byteCount))
        )
        try fixture.certify(observed: sourceValidation.facts)

        let outputDirectory = root.appending(path: "route-\(sourceExtension)-\(targetExtension)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: false)
        let artifact = try await provider.convert(ConversionRequest(
            jobID: UUID(),
            source: Snapshot(
                url: sourceURL, fileKey: FileKey(volumeUUID: zeroUUID, fileID: UInt64(sourceInfo.st_ino)),
                byteCount: UInt64(byteCount), modificationDate: modificationDate
            ),
            targetExtension: targetExtension, policy: targetContract.defaultPolicy,
            outputDirectory: outputDirectory, deadline: Date().addingTimeInterval(5 * 60),
            maximumOutputBytes: maximumArtifactBytes
        ))
        let validation = try await validator.validate(
            artifact,
            expectation: expectation(for: targetContract, sourceURL: sourceURL, maximumBytes: maximumArtifactBytes)
        )
        guard validation.facts.format == targetContract.format,
              try CandidateBundleHasher.fileSHA256(sourceURL) == sourceSHA256,
              !FileManager.default.fileExists(atPath: root.appending(path: "ambient-media-tool-invoked").path) else {
            throw SmokeFailure.sourceChanged
        }
    }

    private func expectation(
        for contract: InstalledMediaFormat,
        sourceURL: URL?,
        maximumBytes: UInt64
    ) -> MediaValidationExpectation {
        var counts: [MediaStreamKind: Int] = [.audio: contract.defaultStreams.audio, .video: contract.defaultStreams.video]
        if contract.defaultStreams.subtitle > 0 { counts[.subtitle] = contract.defaultStreams.subtitle }
        return MediaValidationExpectation(
            target: contract.format, selectedStreamCounts: counts,
            sourceURL: sourceURL, maximumBytes: maximumBytes
        )
    }

    private func installSentinels(in directory: URL, marker: URL) throws {
        for name in ["ffmpeg", "ffprobe"] {
            let script = directory.appending(path: name)
            let body = "#!/bin/sh\nprintf invoked > '\(marker.path)'\nexit 97\n"
            try Data(body.utf8).write(to: script)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: script.path
            )
        }
    }
}

private final class SanitizedEnvironment: @unchecked Sendable {
    private let values: [String: String]
    private let previous: [String: String?]

    init(values: [String: String]) {
        self.values = values
        self.previous = values.mapValues { _ in nil }
            .merging(Dictionary(uniqueKeysWithValues: values.keys.map { ($0, getenv($0).map { String(cString: $0) }) })) { _, current in current }
    }

    func apply() {
        for (key, value) in values { setenv(key, value, 1) }
    }

    func restore() {
        for (key, value) in previous {
            if let value { setenv(key, value, 1) } else { unsetenv(key) }
        }
    }
}

private enum SmokeFailure: Error, CustomStringConvertible {
    case usage
    case invalidInput(String)
    case ambientToolExecuted
    case sourceChanged

    var description: String {
        switch self {
        case .usage:
            "usage: packaged-media-smoke --app /absolute/FileFlip.app --fixtures /absolute/manifest.json"
        case let .invalidInput(message): message
        case .ambientToolExecuted: "An ambient ffmpeg or ffprobe sentinel was executed"
        case .sourceChanged: "A certified source changed or a smoke output was invalid"
        }
    }
}

private let zeroUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
