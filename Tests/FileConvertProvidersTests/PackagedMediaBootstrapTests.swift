import CryptoKit
@testable import FileConvertProviders
import FileConvertCore
import Foundation
import Testing

private func temporaryResourceRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "media-resources-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Test
func bundledMediaToolsLocatorFindsContainedDirectory() throws {
    let root = try temporaryResourceRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let mediaTools = root.appending(path: "MediaTools", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: mediaTools, withIntermediateDirectories: false)

    let located = try BundledMediaToolsLocator().locate(resourcesURL: root)

    #expect(located == mediaTools.resolvingSymlinksInPath().standardizedFileURL)
}

@Test
func bundledMediaToolsLocatorRejectsMissingAndSymlinkDirectories() throws {
    let root = try temporaryResourceRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let locator = BundledMediaToolsLocator()

    #expect(throws: FileConvertError.self) {
        _ = try locator.locate(resourcesURL: root)
    }

    let outside = try temporaryResourceRoot()
    defer { try? FileManager.default.removeItem(at: outside) }
    try FileManager.default.createSymbolicLink(
        at: root.appending(path: "MediaTools"),
        withDestinationURL: outside
    )
    #expect(throws: FileConvertError.self) {
        _ = try locator.locate(resourcesURL: root)
    }
}

@Test
func packagedMediaBootstrapLoadsStrictlyVerifiedComponents() async throws {
    let repositoryRoot = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let directory = repositoryRoot.appending(path: "Sources/FileConvertApp/Resources/MediaTools", directoryHint: .isDirectory)

    let components = try await PackagedMediaBootstrap().load(from: directory)

    #expect(components.tools.version == "8.1.2")
    #expect(await components.provider.health() == .available(version: "8.1.2"))
    #expect(components.validator.id == FFprobeMediaValidator.id)
}

@Test
func packagedMediaBootstrapRejectsMalformedPackage() async throws {
    let directory = try temporaryResourceRoot()
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data("{}".utf8).write(to: directory.appending(path: "manifest.json"))

    await #expect(throws: FileConvertError.self) {
        _ = try await PackagedMediaBootstrap().load(from: directory)
    }
}

private enum MediaPackageTamper: String, CaseIterable, Sendable {
    case missingArtifact
    case missingLicense
    case executableModeRemoved
    case symbolicLink
    case traversalPath
    case malformedManifest
    case unknownManifestField
    case modifiedArtifact
    case invalidSignature
}

private enum MediaInspectionFailure: String, CaseIterable, Sendable {
    case wrongArchitecture
    case timeout
    case configurationMismatch
    case inventoryMismatch
    case selfTestFailure
}

private func repositoryMediaTools() -> URL {
    URL(filePath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Sources/FileConvertApp/Resources/MediaTools", directoryHint: .isDirectory)
}

private func copiedMediaTools() throws -> (directory: URL, cleanupRoot: URL) {
    let root = try temporaryResourceRoot()
    let copy = root.appending(path: "MediaTools", directoryHint: .isDirectory)
    try FileManager.default.copyItem(at: repositoryMediaTools(), to: copy)
    return (copy, root)
}

private func mutateManifest(
    in directory: URL,
    _ mutation: (inout [String: Any]) throws -> Void
) throws {
    let url = directory.appending(path: "manifest.json")
    guard var object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
        throw FileConvertError.validationFailed("Test manifest is not an object")
    }
    try mutation(&object)
    try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        .write(to: url, options: .atomic)
}

private func sha256(_ url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url))
        .map { String(format: "%02x", $0) }
        .joined()
}

private func apply(_ tamper: MediaPackageTamper, to directory: URL) throws {
    let ffmpeg = directory.appending(path: "ffmpeg")
    switch tamper {
    case .missingArtifact:
        try FileManager.default.removeItem(at: directory.appending(path: "ffprobe"))
    case .missingLicense:
        try FileManager.default.removeItem(at: directory.appending(path: "LICENSES/opus.txt"))
    case .executableModeRemoved:
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o644)], ofItemAtPath: ffmpeg.path)
    case .symbolicLink:
        try FileManager.default.removeItem(at: ffmpeg)
        try FileManager.default.createSymbolicLink(atPath: ffmpeg.path, withDestinationPath: "ffprobe")
    case .traversalPath:
        try mutateManifest(in: directory) { manifest in
            var artifacts = manifest["artifacts"] as! [[String: Any]]
            artifacts[0]["path"] = "../ffmpeg"
            manifest["artifacts"] = artifacts
        }
    case .malformedManifest:
        try Data("{".utf8).write(to: directory.appending(path: "manifest.json"), options: .atomic)
    case .unknownManifestField:
        try mutateManifest(in: directory) { $0["unexpected"] = true }
    case .modifiedArtifact:
        let handle = try FileHandle(forWritingTo: ffmpeg)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("tamper".utf8))
    case .invalidSignature:
        let handle = try FileHandle(forWritingTo: ffmpeg)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("tamper".utf8))
        try handle.close()
        let digest = try sha256(ffmpeg)
        try mutateManifest(in: directory) { manifest in
            var artifacts = manifest["artifacts"] as! [[String: Any]]
            let index = artifacts.firstIndex { $0["name"] as? String == "ffmpeg" }!
            artifacts[index]["sha256"] = digest
            manifest["artifacts"] = artifacts
        }
    }
}

private func rejectedActivation(
    directory: URL,
    signaturePolicy: MediaToolSignaturePolicy,
    inspection: MediaToolInspection? = nil
) async -> (hasTools: Bool, capabilities: Set<ConversionCapability>) {
    let verifier = inspection.map {
        MediaToolVerifier(directory: directory, signaturePolicy: signaturePolicy, inspection: $0)
    } ?? MediaToolVerifier(directory: directory, signaturePolicy: signaturePolicy)
    do {
        let tools = try await verifier.verify()
        return (true, InstalledMediaContract.capabilities(for: tools))
    } catch {
        return (false, [])
    }
}

@Test(arguments: MediaPackageTamper.allCases)
private func copiedMediaPackageTamperingFailsClosed(_ tamper: MediaPackageTamper) async throws {
    let copy = try copiedMediaTools()
    defer { try? FileManager.default.removeItem(at: copy.cleanupRoot) }
    try apply(tamper, to: copy.directory)

    let rejection = await rejectedActivation(
        directory: copy.directory,
        signaturePolicy: tamper == .invalidSignature ? .requireValid : .skipForTesting
    )

    #expect(!rejection.hasTools)
    #expect(rejection.capabilities.isEmpty)
}

@Test(arguments: MediaInspectionFailure.allCases)
private func boundedMediaInspectionFailuresFailClosed(_ failure: MediaInspectionFailure) async throws {
    let live = BoundedProcessRunner()
    let inspection: MediaToolInspection = { executable, arguments, environment, timeout in
        if executable.path == "/usr/bin/lipo" {
            switch failure {
            case .wrongArchitecture:
                return BoundedProcessResult(stdout: Data("x86_64\n".utf8), stderr: Data(), terminationStatus: 0)
            case .timeout:
                throw FileConvertError.timedOut
            default:
                break
            }
        }
        if failure == .configurationMismatch, arguments.contains("-buildconf") {
            return BoundedProcessResult(stdout: Data("configuration: --mismatch\n".utf8), stderr: Data(), terminationStatus: 0)
        }
        if failure == .inventoryMismatch, arguments.contains("-encoders") {
            return BoundedProcessResult(stdout: Data(), stderr: Data(), terminationStatus: 0)
        }
        if failure == .selfTestFailure, arguments.contains(where: { $0.contains("anullsrc=") }) {
            return BoundedProcessResult(stdout: Data(), stderr: Data(), terminationStatus: 1)
        }
        return try await live.run(
            executableURL: executable, arguments: arguments,
            environment: environment, timeout: timeout
        )
    }

    let rejection = await rejectedActivation(
        directory: repositoryMediaTools(), signaturePolicy: .skipForTesting, inspection: inspection
    )

    #expect(!rejection.hasTools)
    #expect(rejection.capabilities.isEmpty)
}
