import CoreGraphics
import CoreText
import FileConvertCore
import FileConvertProviders
import Foundation
import Testing

@Test
func everyAdvertisedDocumentPairRunsRenameTransactionHistoryAndExactUndo() async throws {
    let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let root = base.appending(path: "watched", directoryHint: .isDirectory)
    let storage = base.appending(path: "storage", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    let journal = try JournalStore(url: base.appending(path: "journal.sqlite"))
    let transaction = try TransactionCoordinator(journal: journal, storageRoot: storage)
    let undo = UndoCoordinator(journal: journal, storageRoot: storage)
    let providers: [any ConversionProvider] = [NativePDFProvider(), MarkdownHTMLProvider()]

    for provider in providers {
        for capability in await provider.capabilities().sorted(by: { $0.targetExtension < $1.targetExtension }) {
            let fixture = root.appending(path: "fixture-\(UUID().uuidString).\(sourceExtension(capability.source))")
            try writeDocumentFixture(for: capability.source, to: fixture)
            let originalBytes = try Data(contentsOf: fixture)
            let oldRelativePath = fixture.lastPathComponent
            let newRelativePath = "\(fixture.deletingPathExtension().lastPathComponent).\(capability.targetExtension)"
            let renamed = root.appending(path: newRelativePath)
            try FileManager.default.moveItem(at: fixture, to: renamed)

            let id = UUID()
            let policy = policy(for: capability)
            let request = TransactionRequest(
                id: id,
                rootID: UUID(),
                rootURL: root,
                oldRelativePath: oldRelativePath,
                newRelativePath: newRelativePath,
                sourceFormat: capability.source,
                targetFormat: targetFormat(for: capability.targetExtension),
                targetExtension: capability.targetExtension,
                providerID: provider.id,
                providerVersion: "phase7-test",
                policy: policy,
                conversionBehavior: .replaceWithBackup
            )
            let validator = validator(for: capability.targetExtension)
            let produced = try await transaction.execute(
                request,
                produce: { staged, outputDirectory in
                    let values = try staged.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                    return try await provider.convert(
                        ConversionRequest(
                            jobID: id,
                            source: Snapshot(url: staged, fileKey: .init(volumeUUID: UUID(), fileID: 1), byteCount: UInt64(values.fileSize ?? 0), modificationDate: values.contentModificationDate ?? Date()),
                            targetExtension: capability.targetExtension,
                            policy: policy,
                            outputDirectory: outputDirectory,
                            deadline: Date().addingTimeInterval(30),
                            maximumOutputBytes: 10_000_000
                        )
                    )
                },
                validate: validator
            )

            let backup = try #require(await journal.backup(jobID: id))
            let backupHash = try TransactionCoordinator.sha256(storage.appending(path: backup.relativeStoragePath))
            #expect(try await journal.job(id: id)?.state == .succeeded)
            #expect(produced.sourceHash == backupHash)
            #expect(try await undo.undo(jobID: id, rootURL: root) == .restored(root.appending(path: oldRelativePath)))
            #expect(try Data(contentsOf: root.appending(path: oldRelativePath)) == originalBytes)
            #expect(!FileManager.default.fileExists(atPath: renamed.path))
        }
    }
}

private func sourceExtension(_ format: DetectedFormat) -> String {
    switch format {
    case .document(.pdf): "pdf"
    case .document(.markdown): "md"
    case .document(.html): "html"
    default: "document"
    }
}

private func targetFormat(for targetExtension: String) -> DetectedFormat {
    switch targetExtension {
    case "png": .image(.png)
    case "jpg", "jpeg": .image(.jpeg)
    case "txt": .document(.text)
    case "html": .document(.html)
    case "pdf": .document(.pdf)
    case "md", "markdown": .document(.markdown)
    default: fatalError("Unexpected Phase 7 target")
    }
}

private func policy(for capability: ConversionCapability) -> ConversionPolicy {
    switch (capability.source, capability.targetExtension) {
    case (.document(.pdf), "png"), (.document(.pdf), "jpg"), (.document(.pdf), "jpeg"):
        .document(acceptsFidelityLoss: true, pageIndex: 0, imageQuality: 0.8)
    case (.document(.markdown), "pdf"):
        .document(acceptsFidelityLoss: true)
    default:
        .document()
    }
}

private func validator(for targetExtension: String) -> ArtifactValidator {
    switch targetExtension {
    case "png", "jpg", "jpeg": PDFPageImageValidator().certificationValidator().validate
    case "txt": TextValidator().certificationValidator().validate
    case "html": HTMLValidator().certificationValidator().validate
    case "pdf": PDFValidator().certificationValidator().validate
    case "md", "markdown": MarkdownValidator().certificationValidator().validate
    default: fatalError("Unexpected Phase 7 validator")
    }
}

private func writeDocumentFixture(for format: DetectedFormat, to url: URL) throws {
    switch format {
    case .document(.pdf): try writeTwoPageUnicodePDF(to: url)
    case .document(.markdown): try Data("# Café\n\nA [link](https://example.test/über).".utf8).write(to: url)
    case .document(.html): try Data("<h1>Café</h1><p><a href=\"https://example.test/über\">link</a></p>".utf8).write(to: url)
    default: throw FileConvertError.unsupportedPair
    }
}

private func writeTwoPageUnicodePDF(to url: URL) throws {
    var mediaBox = CGRect(x: 0, y: 0, width: 300, height: 200)
    guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else { throw FileConvertError.validationFailed("Could not create PDF fixture") }
    let font = CTFontCreateWithName("Helvetica" as CFString, 16, nil)
    for text in ["Café — Unicode", "Second page with extractable text"] {
        context.beginPDFPage(nil)
        context.textMatrix = .identity
        context.translateBy(x: 24, y: 100)
        context.scaleBy(x: 1, y: -1)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: CGColor(gray: 0, alpha: 1)]
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), context)
        context.endPDFPage()
    }
    context.closePDF()
}
