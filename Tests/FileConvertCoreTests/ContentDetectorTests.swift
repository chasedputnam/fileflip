import CoreGraphics
import FileConvertCore
import Foundation
import Testing

private func temporaryFile(_ data: Data, suffix: String = "bin") throws -> (URL, URL) {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appending(path: "fixture.\(suffix)")
    try data.write(to: file)
    return (file, directory)
}

private func append16(_ value: UInt16, to data: inout Data) {
    data.append(UInt8(value & 0xff)); data.append(UInt8(value >> 8))
}

private func append32(_ value: UInt32, to data: inout Data) {
    data.append(UInt8(value & 0xff)); data.append(UInt8((value >> 8) & 0xff)); data.append(UInt8((value >> 16) & 0xff)); data.append(UInt8(value >> 24))
}

private func storedZIP(_ entries: [(name: String, data: Data, advertisedSize: UInt32?)]) -> Data {
    var output = Data()
    var central = Data()
    for entry in entries {
        let name = Data(entry.name.utf8)
        let offset = UInt32(output.count)
        let size = entry.advertisedSize ?? UInt32(entry.data.count)
        append32(0x04034b50, to: &output); append16(20, to: &output); append16(0x0800, to: &output); append16(0, to: &output)
        append16(0, to: &output); append16(0, to: &output); append32(0, to: &output); append32(UInt32(entry.data.count), to: &output)
        append32(size, to: &output); append16(UInt16(name.count), to: &output); append16(0, to: &output); output.append(name); output.append(entry.data)

        append32(0x02014b50, to: &central); append16(20, to: &central); append16(20, to: &central); append16(0x0800, to: &central)
        append16(0, to: &central); append16(0, to: &central); append16(0, to: &central); append32(0, to: &central)
        append32(UInt32(entry.data.count), to: &central); append32(size, to: &central); append16(UInt16(name.count), to: &central)
        append16(0, to: &central); append16(0, to: &central); append16(0, to: &central); append16(0, to: &central)
        append32(0, to: &central); append32(offset, to: &central); central.append(name)
    }
    let centralOffset = UInt32(output.count)
    output.append(central)
    append32(0x06054b50, to: &output); append16(0, to: &output); append16(0, to: &output)
    append16(UInt16(entries.count), to: &output); append16(UInt16(entries.count), to: &output)
    append32(UInt32(central.count), to: &output); append32(centralOffset, to: &output); append16(0, to: &output)
    return output
}

private func asciiPDF(prefix: String = "") -> Data {
    var text = prefix + "%PDF-1.4\n"
    var offsets: [Int] = []
    for object in [
        "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n",
        "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n",
        "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 10 10] /Contents 4 0 R >>\nendobj\n",
        "4 0 obj\n<< /Length 0 >>\nstream\n\nendstream\nendobj\n"
    ] {
        offsets.append(text.utf8.count)
        text += object
    }
    let xref = text.utf8.count
    text += "xref\n0 5\n0000000000 65535 f \n"
    for offset in offsets { text += String(format: "%010d 00000 n \n", offset) }
    text += "trailer\n<< /Size 5 /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
    return Data(text.utf8)
}

private actor ProbeRecorder: MediaContentProbing {
    private(set) var limit: Int?
    func probe(_ url: URL, maximumOutputBytes: Int) async throws -> DetectedFormat? {
        limit = maximumOutputBytes
        return .audio(.flac)
    }
}

@Test
func contentDetectionUsesBytesRatherThanExtension() async throws {
    let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
    let (image, imageDirectory) = try temporaryFile(png, suffix: "txt")
    defer { try? FileManager.default.removeItem(at: imageDirectory) }
    #expect(try await ContentDetector().detect(image) == .image(.png))

    let (html, htmlDirectory) = try temporaryFile(Data("<!doctype html><html><body>safe</body></html>".utf8), suffix: "jpg")
    defer { try? FileManager.default.removeItem(at: htmlDirectory) }
    #expect(try await ContentDetector().detect(html) == .document(.html))

    let (csv, csvDirectory) = try temporaryFile(Data("name,value\na,1\nb,2\n".utf8), suffix: "dat")
    defer { try? FileManager.default.removeItem(at: csvDirectory) }
    #expect(try await ContentDetector().detect(csv) == .spreadsheet(.csv))

    let textualFixtures: [(Data, DetectedFormat)] = [
        (Data("# Heading\n\n- item\n".utf8), .document(.markdown)),
        (Data("{\\rtf1\\ansi hello}".utf8), .document(.rtf)),
        (asciiPDF(), .document(.pdf))
    ]
    for (data, expected) in textualFixtures {
        let (file, directory) = try temporaryFile(data)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try await ContentDetector().detect(file) == expected)
    }

    var utf16 = Data([0xff, 0xfe])
    utf16.append("hello".data(using: .utf16LittleEndian)!)
    let (text, textDirectory) = try temporaryFile(utf16, suffix: "png")
    defer { try? FileManager.default.removeItem(at: textDirectory) }
    #expect(try await ContentDetector().detect(text) == .document(.text))
}

@Test
func boundedPackagesAreIdentifiedByRequiredMarkers() async throws {
    let fixtures: [(Data, DetectedFormat)] = [
        (storedZIP([(name: "[Content_Types].xml", data: Data(), advertisedSize: nil), (name: "word/document.xml", data: Data(), advertisedSize: nil)]), .document(.docx)),
        (storedZIP([(name: "[Content_Types].xml", data: Data(), advertisedSize: nil), (name: "xl/workbook.xml", data: Data(), advertisedSize: nil)]), .spreadsheet(.xlsx)),
        (storedZIP([(name: "mimetype", data: Data("application/vnd.oasis.opendocument.text".utf8), advertisedSize: nil)]), .document(.odt)),
        (storedZIP([(name: "mimetype", data: Data("application/vnd.oasis.opendocument.spreadsheet".utf8), advertisedSize: nil)]), .spreadsheet(.ods))
    ]
    for (data, expected) in fixtures {
        let (file, directory) = try temporaryFile(data)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try await ContentDetector().detect(file) == expected)
    }
}

@Test
func unsafeAndAmbiguousInputsAreRejected() async throws {
    let traversal = storedZIP([(name: "../word/document.xml", data: Data(), advertisedSize: nil)])
    let (traversalFile, traversalDirectory) = try temporaryFile(traversal)
    defer { try? FileManager.default.removeItem(at: traversalDirectory) }
    await #expect(throws: ContentDetectionError.self) { try await ContentDetector().detect(traversalFile) }

    let bomb = storedZIP([(name: "mimetype", data: Data([0]), advertisedSize: 500_000_000)])
    let (bombFile, bombDirectory) = try temporaryFile(bomb)
    defer { try? FileManager.default.removeItem(at: bombDirectory) }
    await #expect(throws: ContentDetectionError.archiveLimitExceeded) { try await ContentDetector().detect(bombFile) }

    let oversized = storedZIP([(name: "[Content_Types].xml", data: Data(), advertisedSize: nil), (name: "word/document.xml", data: Data(), advertisedSize: nil)])
    let (oversizedFile, oversizedDirectory) = try temporaryFile(oversized)
    defer { try? FileManager.default.removeItem(at: oversizedDirectory) }
    let strictLimits = ContentDetector.Limits(maximumCentralDirectoryBytes: 16)
    await #expect(throws: ContentDetectionError.archiveLimitExceeded) { try await ContentDetector(limits: strictLimits).detect(oversizedFile) }

    let (mislabeledFile, mislabeledDirectory) = try temporaryFile(Data([0xff, 0x00, 0xfe]), suffix: "docx")
    defer { try? FileManager.default.removeItem(at: mislabeledDirectory) }
    #expect(try await ContentDetector().detect(mislabeledFile) == nil)

    let polyglot = asciiPDF(prefix: "<!doctype html><html></html>\n")
    let (polyglotFile, polyglotDirectory) = try temporaryFile(polyglot)
    defer { try? FileManager.default.removeItem(at: polyglotDirectory) }
    await #expect(throws: ContentDetectionError.self) { try await ContentDetector().detect(polyglotFile) }
}

@Test
func mediaProbeOutputIsBounded() async throws {
    let recorder = ProbeRecorder()
    let (file, directory) = try temporaryFile(Data([0xff, 0x00, 0xfe]))
    defer { try? FileManager.default.removeItem(at: directory) }
    let limits = ContentDetector.Limits(maximumProbeOutputBytes: 321)
    #expect(try await ContentDetector(limits: limits, mediaProbe: recorder).detect(file) == .audio(.flac))
    #expect(await recorder.limit == 321)
}
