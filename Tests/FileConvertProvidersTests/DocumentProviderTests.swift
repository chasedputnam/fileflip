import FileConvertCore
import FileConvertProviders
import Foundation
import Testing

@Test
func safeHTMLSubsetRejectsActiveAndExternalResourcesWithoutRendering() throws {
    #expect(throws: FileConvertError.validationFailed("HTML contains active, external-resource, or unsupported content")) {
        try SafeHTMLSubset.validate("<p>x</p><script>fetch('https://example.test')</script>")
    }
    #expect(throws: FileConvertError.validationFailed("HTML contains active, external-resource, or unsupported content")) {
        try SafeHTMLSubset.validate("<img src=\"https://example.test/pixel.png\">")
    }
}

@Test
func networkDenialHarnessRecordsWithoutOpeningAnExternalConnection() async throws {
    NetworkDenyHarness.reset()
    let session = NetworkDenyHarness.makeSession()
    let url = try #require(URL(string: "https://external-resource.invalid/pixel"))
    await #expect(throws: URLError.self) {
        _ = try await session.data(from: url)
    }
    #expect(NetworkDenyHarness.attempts() == [url])
}

@Test
func rejectedHTMLExternalResourceCreatesNoNetworkAttempt() throws {
    let url = try #require(URL(string: "https://rejected-resource.invalid/pixel"))
    #expect(throws: FileConvertError.self) {
        try SafeHTMLSubset.validate("<img src=\"\(url.absoluteString)\">")
    }
    #expect(!NetworkDenyHarness.attempts().contains(url))
}

@Test
func markdownHTMLRenderingIsDeterministicAndStrictUTF8() async throws {
    let fixture = try DocumentFixture(contents: "# Café\n\nA [link](https://example.test/über).")
    defer { fixture.remove() }
    let artifact = try await MarkdownHTMLProvider().convert(fixture.request(target: "html"))
    let html = try String(contentsOf: artifact.url, encoding: .utf8)
    #expect(html == "<h1>Café</h1>\n<p>A <a href=\"https://example.test/über\">link</a>.</p>")
    _ = try HTMLValidator().validate(artifact)
}

@Test
func htmlToMarkdownRejectsUnsupportedLossBeforeWritingOutput() async throws {
    let fixture = try DocumentFixture(contents: "<table><tr><td>loss</td></tr></table>")
    defer { fixture.remove() }
    await #expect(throws: FileConvertError.validationFailed("HTML tag is outside the safe subset")) {
        try await MarkdownHTMLProvider().convert(fixture.request(target: "md"))
    }
    #expect(try FileManager.default.contentsOfDirectory(at: fixture.output, includingPropertiesForKeys: nil).isEmpty)
}

@Test
func pdfProviderRejectsInvalidTypedImageQualityBeforeInspectingSource() async throws {
    let fixture = try DocumentFixture(contents: "not a PDF")
    defer { fixture.remove() }
    await #expect(throws: FileConvertError.validationFailed("PDF conversion requires a version 1 document policy with image quality between 0 and 1")) {
        try await NativePDFProvider().convert(fixture.request(target: "jpg", policy: .document(acceptsFidelityLoss: true, pageIndex: 0, imageQuality: .nan)))
    }
    #expect(try FileManager.default.contentsOfDirectory(at: fixture.output, includingPropertiesForKeys: nil).isEmpty)
}

private final class DocumentFixture {
    let root: URL
    let source: URL
    let output: URL

    init(contents: String) throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        source = root.appending(path: "source.document")
        output = root.appending(path: "output", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try contents.data(using: .utf8)!.write(to: source)
    }

    func request(target: String, policy: ConversionPolicy = .document()) -> ConversionRequest {
        ConversionRequest(
            jobID: UUID(),
            source: Snapshot(url: source, fileKey: .init(volumeUUID: UUID(), fileID: 1), byteCount: UInt64((try? Data(contentsOf: source).count) ?? 0), modificationDate: Date()),
            targetExtension: target,
            policy: policy,
            outputDirectory: output,
            deadline: Date().addingTimeInterval(10),
            maximumOutputBytes: 1_000_000
        )
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
