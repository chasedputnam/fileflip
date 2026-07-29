import CryptoKit
import FileConvertCore
import FileConvertProviders
import Foundation
import Testing

private enum MediaIntegrationTools {
    static let directoryEnvironment = "FILECONVERT_MEDIA_TOOLS"

    static func verified() async throws -> VerifiedMediaTools? {
        guard let path = ProcessInfo.processInfo.environment[directoryEnvironment], !path.isEmpty else { return nil }
        return try await MediaToolVerifier(
            directory: URL(fileURLWithPath: path, isDirectory: true),
            signaturePolicy: .requireValid
        ).verify()
    }

    static func createAudio(at url: URL, tools: VerifiedMediaTools) async throws {
        let result = try await BoundedProcessRunner().run(
            executableURL: tools.ffmpegURL,
            arguments: ["-hide_banner", "-nostdin", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=1000:sample_rate=48000:duration=1", "-map", "0:a:0", "-c:a", "pcm_s16le", "-f", "wav", "--", url.path],
            environment: ["PATH": "/usr/bin:/bin", "HOME": "/var/empty", "LANG": "C"],
            timeout: .seconds(30)
        )
        guard result.terminationStatus == 0 else { throw FileConvertError.providerUnavailable("Cannot generate deterministic audio fixture") }
    }

    static func createVideo(at url: URL, tools: VerifiedMediaTools) async throws {
        let result = try await BoundedProcessRunner().run(
            executableURL: tools.ffmpegURL,
            arguments: ["-hide_banner", "-nostdin", "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=64x48:rate=24:duration=1", "-f", "lavfi", "-i", "sine=frequency=1000:sample_rate=48000:duration=1", "-map", "0:v:0", "-map", "1:a:0", "-c:v", "mpeg4", "-c:a", "aac", "-shortest", "-f", "matroska", "--", url.path],
            environment: ["PATH": "/usr/bin:/bin", "HOME": "/var/empty", "LANG": "C"],
            timeout: .seconds(30)
        )
        guard result.terminationStatus == 0 else { throw FileConvertError.providerUnavailable("Cannot generate deterministic video fixture") }
    }

    static func target(_ ext: String) -> DetectedFormat? {
        InstalledMediaContract.format(forExtension: ext)
    }

    static func expectedCounts(for format: DetectedFormat) -> [MediaStreamKind: Int] {
        guard let streams = InstalledMediaContract.installedFormat(for: format)?.defaultStreams else { return [:] }
        var counts: [MediaStreamKind: Int] = [:]
        if streams.audio > 0 { counts[.audio] = streams.audio }
        if streams.video > 0 { counts[.video] = streams.video }
        if streams.subtitle > 0 { counts[.subtitle] = streams.subtitle }
        return counts
    }
}

@Test
func packagedMediaToolsConvertAndValidateEveryAdvertisedPair() async throws {
    guard let tools = try await MediaIntegrationTools.verified() else { return }
    let directory = FileManager.default.temporaryDirectory.appending(path: "media-matrix-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let audio = directory.appending(path: "audio.wav")
    let video = directory.appending(path: "video.mkv")
    try await MediaIntegrationTools.createAudio(at: audio, tools: tools)
    try await MediaIntegrationTools.createVideo(at: video, tools: tools)
    let provider = FFmpegMediaProvider(tools: tools)
    let validator = FFprobeMediaValidator(tools: tools)
    let capabilities = await provider.capabilities()
    #expect(!capabilities.isEmpty)

    for capability in capabilities {
        let source: URL
        switch capability.source {
        case .audio: source = audio
        case .video: source = video
        default: Issue.record("Media provider advertised a non-media source"); continue
        }
        let expected = try #require(MediaIntegrationTools.target(capability.targetExtension))
        let outputDirectory = directory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let request = ConversionRequest(
            jobID: UUID(),
            source: Snapshot(url: source, fileKey: FileKey(volumeUUID: UUID(), fileID: 1), byteCount: UInt64(try Data(contentsOf: source).count), modificationDate: Date()),
            targetExtension: capability.targetExtension,
            policy: capability.defaultPolicy,
            outputDirectory: outputDirectory,
            deadline: Date().addingTimeInterval(15 * 60),
            maximumOutputBytes: 16 * 1024 * 1024
        )
        do {
            let command = try provider.command(for: request, outputURL: outputDirectory.appending(path: "inspect.\(capability.targetExtension)"))
            #expect(!command.arguments.contains(where: { $0.contains("://") || $0 == "http" || $0 == "https" }))
            let artifact = try await provider.convert(request)
            let result = try await validator.validate(
                artifact,
                expectation: MediaValidationExpectation(target: expected, selectedStreamCounts: MediaIntegrationTools.expectedCounts(for: expected), sourceURL: source, maximumBytes: request.maximumOutputBytes)
            )
            #expect(result.format == expected)
        } catch {
            Issue.record("Route \(capability.source) -> \(capability.targetExtension) failed: \(error)")
        }
    }
}

@Test
func mediaConversionTransactionPreservesExactBackupHistoryAndUndo() async throws {
    guard let tools = try await MediaIntegrationTools.verified() else { return }
    let base = FileManager.default.temporaryDirectory.appending(path: "media-transaction-\(UUID().uuidString)", directoryHint: .isDirectory)
    let root = base.appending(path: "watched", directoryHint: .isDirectory)
    let storage = base.appending(path: "storage", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let target = root.appending(path: "sample.wav")
    try await MediaIntegrationTools.createAudio(at: target, tools: tools)
    let original = try Data(contentsOf: target)
    let rootID = UUID()
    let request = TransactionRequest(rootID: rootID, rootURL: root, oldRelativePath: "sample.m4a", newRelativePath: "sample.wav", sourceFormat: .audio(.m4a), targetFormat: .audio(.wav), targetExtension: "wav", providerID: ProviderID(rawValue: "ffmpeg"), providerVersion: tools.version, policy: .audio(), conversionBehavior: .replaceWithBackup)
    let journal = try JournalStore(url: base.appending(path: "journal.sqlite"))
    let transaction = try TransactionCoordinator(journal: journal, storageRoot: storage)
    let provider = FFmpegMediaProvider(tools: tools)
    let validator = FFprobeMediaValidator(tools: tools)
    _ = try await transaction.execute(request, produce: { stagedSource, outputDirectory in
        try await provider.convert(ConversionRequest(jobID: request.id, source: Snapshot(url: stagedSource, fileKey: FileKey(volumeUUID: UUID(), fileID: 1), byteCount: UInt64(original.count), modificationDate: Date()), targetExtension: "wav", policy: .audio(), outputDirectory: outputDirectory, deadline: Date().addingTimeInterval(15 * 60), maximumOutputBytes: 16 * 1024 * 1024))
    }, validate: { artifact, expected in
        let result = try await validator.validate(artifact, expectation: MediaValidationExpectation(target: expected, selectedStreamCounts: [.audio: 1], maximumBytes: 16 * 1024 * 1024))
        return (result.hash, result.format)
    })
    let backup = try #require(await journal.backup(jobID: request.id))
    #expect(try Data(contentsOf: storage.appending(path: backup.relativeStoragePath)) == original)
    #expect(try await journal.job(id: request.id)?.state == .succeeded)
    let undo = UndoCoordinator(journal: journal, storageRoot: storage)
    #expect(try await undo.undo(jobID: request.id, rootURL: root) == .restored(root.appending(path: "sample.m4a")))
    #expect(try Data(contentsOf: root.appending(path: "sample.m4a")) == original)
}
