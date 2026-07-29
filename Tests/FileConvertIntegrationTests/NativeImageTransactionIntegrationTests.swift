import CoreGraphics
import CryptoKit
import FileConvertCore
import FileConvertProviders
import Foundation
import ImageIO
import Testing

@Test
func everyNativeImagePairRunsRenameTransactionHistoryAndExactUndo() async throws {
    let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let root = base.appending(path: "watched", directoryHint: .isDirectory)
    let storage = base.appending(path: "storage", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    let journal = try JournalStore(url: base.appending(path: "journal.sqlite"))
    let transaction = try TransactionCoordinator(journal: journal, storageRoot: storage)
    let undo = UndoCoordinator(journal: journal, storageRoot: storage)
    let provider = NativeImageProvider()
    let validator = NativeImageValidator().certificationValidator().validate
    let capabilities = await provider.capabilities().sorted {
        String(describing: $0.source) + $0.targetExtension < String(describing: $1.source) + $1.targetExtension
    }
    #expect(!capabilities.isEmpty)

    for (index, capability) in capabilities.enumerated() {
        guard case let .image(sourceFormat) = capability.source,
              let targetFormat = imageFormat(for: capability.targetExtension) else {
            Issue.record("Native image capability was malformed")
            continue
        }
        let sourceExtension = canonicalExtension(for: sourceFormat)
        let oldRelativePath = "fixture-\(index).\(sourceExtension)"
        let newRelativePath = "fixture-\(index).\(capability.targetExtension)"
        let oldURL = root.appending(path: oldRelativePath)
        let renamedURL = root.appending(path: newRelativePath)
        try writeImageFixture(format: sourceFormat, to: oldURL)
        let originalBytes = try Data(contentsOf: oldURL)
        let originalHash = try TransactionCoordinator.sha256(oldURL)

        try FileManager.default.moveItem(at: oldURL, to: renamedURL)
        let id = UUID()
        let policy = ConversionPolicy.image(
            quality: 0.8,
            alphaBackgroundARGB: 0xffff_ffff,
            metadata: .strip,
            orientation: .normalizePixels,
            colorProfile: .convertToSRGB
        )
        let request = TransactionRequest(
            id: id,
            rootID: UUID(),
            rootURL: root,
            oldRelativePath: oldRelativePath,
            newRelativePath: newRelativePath,
            sourceFormat: capability.source,
            targetFormat: .image(targetFormat),
            targetExtension: capability.targetExtension,
            providerID: provider.id,
            providerVersion: "ImageIO",
            policy: policy,
            conversionBehavior: .replaceWithBackup
        )
        let produced = try await transaction.execute(
            request,
            produce: { staged, outputDirectory in
                let values = try staged.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                return try await provider.convert(
                    ConversionRequest(
                        jobID: id,
                        source: Snapshot(
                            url: staged,
                            fileKey: FileKey(volumeUUID: UUID(), fileID: UInt64(index + 1)),
                            byteCount: UInt64(values.fileSize ?? 0),
                            modificationDate: values.contentModificationDate ?? Date()
                        ),
                        targetExtension: capability.targetExtension,
                        policy: policy,
                        outputDirectory: outputDirectory,
                        deadline: Date().addingTimeInterval(10),
                        maximumOutputBytes: 1_000_000
                    )
                )
            },
            validate: validator
        )

        #expect(produced.sourceHash == originalHash)
        #expect(try await ContentDetector().detect(renamedURL) == .image(targetFormat))
        #expect(try await journal.job(id: id)?.state == .succeeded)
        let backup = try #require(await journal.backup(jobID: id))
        #expect(backup.sha256 == originalHash)
        #expect(try Data(contentsOf: storage.appending(path: backup.relativeStoragePath)) == originalBytes)

        #expect(try await undo.undo(jobID: id, rootURL: root) == .restored(oldURL))
        #expect(try Data(contentsOf: oldURL) == originalBytes)
        #expect(!FileManager.default.fileExists(atPath: renamedURL.path))
    }
}

@Test
func copyModeSupportedRenamePublishesTwoFilesRecordsHistoryAndUndoesWithoutBackup() async throws {
    let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let root = base.appending(path: "watched", directoryHint: .isDirectory)
    let storage = base.appending(path: "storage", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    let journal = try JournalStore(url: base.appending(path: "journal.sqlite"))
    let transaction = try TransactionCoordinator(journal: journal, storageRoot: storage)
    let undo = UndoCoordinator(journal: journal, storageRoot: storage)
    let provider = NativeImageProvider()
    let validator = NativeImageValidator().certificationValidator().validate
    let oldRelativePath = "photo.jpg"
    let newRelativePath = "photo.png"
    let oldURL = root.appending(path: oldRelativePath)
    let renamedURL = root.appending(path: newRelativePath)
    try writeImageFixture(format: .jpeg, to: oldURL)
    let originalBytes = try Data(contentsOf: oldURL)
    let independentlyComputedOriginalHash = Data(SHA256.hash(data: originalBytes))

    try FileManager.default.moveItem(at: oldURL, to: renamedURL)
    let id = UUID()
    let policy = ConversionPolicy.image(
        quality: 0.8,
        alphaBackgroundARGB: 0xffff_ffff,
        metadata: .strip,
        orientation: .normalizePixels,
        colorProfile: .convertToSRGB
    )
    let request = TransactionRequest(
        id: id,
        rootID: UUID(),
        rootURL: root,
        oldRelativePath: oldRelativePath,
        newRelativePath: newRelativePath,
        sourceFormat: .image(.jpeg),
        targetFormat: .image(.png),
        targetExtension: "png",
        providerID: provider.id,
        providerVersion: "ImageIO",
        policy: policy,
        conversionBehavior: .keepOriginal
    )
    let produced = try await transaction.execute(
        request,
        produce: { staged, outputDirectory in
            let values = try staged.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return try await provider.convert(
                ConversionRequest(
                    jobID: id,
                    source: Snapshot(
                        url: staged,
                        fileKey: FileKey(volumeUUID: UUID(), fileID: 1),
                        byteCount: UInt64(values.fileSize ?? 0),
                        modificationDate: values.contentModificationDate ?? Date()
                    ),
                    targetExtension: "png",
                    policy: policy,
                    outputDirectory: outputDirectory,
                    deadline: Date().addingTimeInterval(10),
                    maximumOutputBytes: 1_000_000
                )
            )
        },
        validate: validator
    )

    #expect(produced.sourceHash == independentlyComputedOriginalHash)
    #expect(try Data(contentsOf: oldURL) == originalBytes)
    #expect(try await ContentDetector().detect(renamedURL) == .image(.png))
    #expect(CGImageSourceCreateWithURL(renamedURL as CFURL, nil) != nil)
    let history = try #require(try await journal.job(id: id))
    #expect(history.state == .succeeded)
    #expect(history.conversionBehavior == .keepOriginal)
    #expect(history.oldRelativePath == oldRelativePath)
    #expect(history.newRelativePath == newRelativePath)
    #expect(history.sourceHash == independentlyComputedOriginalHash)
    let independentlyComputedOutputHash = Data(SHA256.hash(data: try Data(contentsOf: renamedURL)))
    #expect(history.outputHash == independentlyComputedOutputHash)
    #expect(try await journal.backup(jobID: id) == nil)

    #expect(try await undo.undo(jobID: id, rootURL: root) == .restored(oldURL))
    #expect(try Data(contentsOf: oldURL) == originalBytes)
    #expect(!FileManager.default.fileExists(atPath: renamedURL.path))
    #expect(try await journal.backup(jobID: id) == nil)
}

private func imageFormat(for targetExtension: String) -> ImageFormat? {
    switch targetExtension {
    case "jpg", "jpeg": .jpeg
    case "png": .png
    case "heic", "heif": .heic
    case "tif", "tiff": .tiff
    case "webp": .webP
    default: nil
    }
}

private func canonicalExtension(for format: ImageFormat) -> String {
    switch format {
    case .jpeg: "jpg"
    case .png: "png"
    case .heic: "heic"
    case .tiff: "tiff"
    case .webP: "webp"
    }
}

private func writeImageFixture(format: ImageFormat, to url: URL) throws {
    if format == .webP {
        guard let bytes = Data(base64Encoded: "UklGRjIAAABXRUJQVlA4TCUAAAAvAYAAAC8gEEjaH3qN+RcQFPk/2vwHH0QCg0AgDVFkMMAR/Y8GAA==") else {
            throw ImageIntegrationFixtureError.creationFailed
        }
        try bytes.write(to: url)
        return
    }
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: 2,
        height: 3,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else { throw ImageIntegrationFixtureError.creationFailed }
    context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 2, height: 3))
    let identifier: String
    switch format {
    case .jpeg: identifier = "public.jpeg"
    case .png: identifier = "public.png"
    case .heic: identifier = "public.heic"
    case .tiff: identifier = "public.tiff"
    case .webP: throw ImageIntegrationFixtureError.creationFailed
    }
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, identifier as CFString, 1, nil) else {
        throw ImageIntegrationFixtureError.creationFailed
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw ImageIntegrationFixtureError.creationFailed }
}

private enum ImageIntegrationFixtureError: Error { case creationFailed }
