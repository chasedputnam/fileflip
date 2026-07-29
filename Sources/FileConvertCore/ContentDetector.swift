import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

public protocol MediaContentProbing: Sendable {
    func probe(_ url: URL, maximumOutputBytes: Int) async throws -> DetectedFormat?
}

public enum ContentDetectionError: Error, Equatable, Sendable {
    case unsafeArchive(String)
    case archiveLimitExceeded
    case ambiguous(Set<DetectedFormat>)
    case unreadable
}

public struct ContentDetector: Sendable {
    public struct Limits: Hashable, Sendable {
        public var maximumTextBytes: Int
        public var maximumArchiveEntries: Int
        public var maximumCentralDirectoryBytes: Int
        public var maximumArchiveUncompressedBytes: UInt64
        public var maximumCompressionRatio: UInt64
        public var maximumProbeOutputBytes: Int

        public init(maximumTextBytes: Int = 8 * 1_024 * 1_024, maximumArchiveEntries: Int = 10_000, maximumCentralDirectoryBytes: Int = 16 * 1_024 * 1_024, maximumArchiveUncompressedBytes: UInt64 = 512 * 1_024 * 1_024, maximumCompressionRatio: UInt64 = 200, maximumProbeOutputBytes: Int = 1_024 * 1_024) {
            self.maximumTextBytes = maximumTextBytes
            self.maximumArchiveEntries = maximumArchiveEntries
            self.maximumCentralDirectoryBytes = maximumCentralDirectoryBytes
            self.maximumArchiveUncompressedBytes = maximumArchiveUncompressedBytes
            self.maximumCompressionRatio = maximumCompressionRatio
            self.maximumProbeOutputBytes = maximumProbeOutputBytes
        }
    }

    private let limits: Limits
    private let mediaProbe: (any MediaContentProbing)?

    public init(limits: Limits = Limits(), mediaProbe: (any MediaContentProbing)? = nil) {
        self.limits = limits
        self.mediaProbe = mediaProbe
    }

    public func detect(_ url: URL) async throws -> DetectedFormat? {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { return nil }

        var matches = Set<DetectedFormat>()
        if let image = imageFormat(url) { matches.insert(.image(image)) }
        if try isPDF(url) { matches.insert(.document(.pdf)) }
        if let package = try packageFormat(url) { matches.insert(package) }
        if let text = try textFormat(url, byteCount: values.fileSize ?? 0),
           matches.isEmpty || text != .document(.text) {
            matches.insert(text)
        }
        if matches.isEmpty, let mediaProbe, let media = try await mediaProbe.probe(url, maximumOutputBytes: limits.maximumProbeOutputBytes) {
            matches.insert(media)
        }

        guard matches.count <= 1 else { throw ContentDetectionError.ambiguous(matches) }
        return matches.first
    }

    private func imageFormat(_ url: URL) -> ImageFormat? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) != nil,
              let identifier = CGImageSourceGetType(source) as String?, let type = UTType(identifier) else { return nil }
        if type.conforms(to: .jpeg) { return .jpeg }
        if type.conforms(to: .png) { return .png }
        if type.conforms(to: .heic) || identifier == "public.heif" { return .heic }
        if type.conforms(to: .tiff) { return .tiff }
        if identifier == "org.webmproject.webp" || identifier == "public.webp" { return .webP }
        return nil
    }

    private func isPDF(_ url: URL) throws -> Bool {
        let prefix = try read(url, offset: 0, count: 1_024)
        guard prefix.range(of: Data("%PDF-".utf8)) != nil else { return false }
        guard let document = PDFDocument(url: url), document.pageCount > 0 else { return false }
        return true
    }

    private func packageFormat(_ url: URL) throws -> DetectedFormat? {
        let prefix = try read(url, offset: 0, count: 4)
        guard prefix == Data([0x50, 0x4b, 0x03, 0x04]) else { return nil }
        let archive = try ZIPIndex(url: url, limits: limits)
        let names = archive.names
        if names.contains("[Content_Types].xml") && names.contains("word/document.xml") { return .document(.docx) }
        if names.contains("[Content_Types].xml") && names.contains("xl/workbook.xml") { return .spreadsheet(.xlsx) }
        if let mimetype = try archive.storedContents(named: "mimetype") {
            if mimetype == Data("application/vnd.oasis.opendocument.text".utf8) { return .document(.odt) }
            if mimetype == Data("application/vnd.oasis.opendocument.spreadsheet".utf8) { return .spreadsheet(.ods) }
        }
        return nil
    }

    private func textFormat(_ url: URL, byteCount: Int) throws -> DetectedFormat? {
        guard byteCount <= limits.maximumTextBytes else { return nil }
        let data = try read(url, offset: 0, count: max(byteCount, 1))
        guard let text = strictString(data), !text.unicodeScalars.contains("\0") else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .document(.text) }
        let lower = trimmed.prefix(4_096).lowercased()
        if lower.hasPrefix("{\\rtf") { return .document(.rtf) }
        if lower.hasPrefix("<!doctype html") || lower.hasPrefix("<html") { return .document(.html) }
        if isCSV(text) { return .spreadsheet(.csv) }
        if isMarkdown(text) { return .document(.markdown) }
        return .document(.text)
    }

    private func strictString(_ data: Data) -> String? {
        if let value = String(data: data, encoding: .utf8), Data(value.utf8) == data { return value }
        if data.starts(with: [0xff, 0xfe]) { return String(data: data.dropFirst(2), encoding: .utf16LittleEndian) }
        if data.starts(with: [0xfe, 0xff]) { return String(data: data.dropFirst(2), encoding: .utf16BigEndian) }
        return nil
    }

    private func isMarkdown(_ text: String) -> Bool {
        text.split(whereSeparator: \Character.isNewline).contains { line in
            let value = line.trimmingCharacters(in: .whitespaces)
            return value.hasPrefix("# ") || value.hasPrefix("## ") || value.hasPrefix("- ") || value.hasPrefix("* ") || (value.hasPrefix("[") && value.contains("]("))
        }
    }

    private func isCSV(_ text: String) -> Bool {
        let rows = text.split(omittingEmptySubsequences: true, whereSeparator: \Character.isNewline).prefix(20)
        guard rows.count >= 2 else { return false }
        for delimiter: Character in [",", "\t", ";"] {
            let counts = rows.map { $0.filter { $0 == delimiter }.count }
            if let first = counts.first, first > 0, counts.allSatisfy({ $0 == first }) { return true }
        }
        return false
    }

    private func read(_ url: URL, offset: UInt64, count: Int) throws -> Data {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: offset)
            return try handle.read(upToCount: count) ?? Data()
        } catch {
            throw ContentDetectionError.unreadable
        }
    }
}

private struct ZIPIndex {
    struct Entry {
        let compression: UInt16
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        let localOffset: UInt64
    }

    let url: URL
    let names: Set<String>
    private let entries: [String: Entry]

    init(url: URL, limits: ContentDetector.Limits) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let number = attributes[.size] as? NSNumber else { throw ContentDetectionError.unreadable }
        let fileSize = number.uint64Value
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let tailCount = Int(min(fileSize, 65_557))
        let tail = try Self.read(handle, offset: fileSize - UInt64(tailCount), count: tailCount)
        guard let eocd = Self.lastSignature(0x06054b50, in: tail), eocd + 22 <= tail.count else { throw ContentDetectionError.unsafeArchive("missing end record") }
        let entryCount = Int(Self.u16(tail, eocd + 10))
        let directorySize = UInt64(Self.u32(tail, eocd + 12))
        let directoryOffset = UInt64(Self.u32(tail, eocd + 16))
        guard entryCount != 0xffff, directorySize != 0xffff_ffff, directoryOffset != 0xffff_ffff else { throw ContentDetectionError.archiveLimitExceeded }
        guard entryCount <= limits.maximumArchiveEntries, directorySize <= UInt64(limits.maximumCentralDirectoryBytes), directoryOffset + directorySize <= fileSize else { throw ContentDetectionError.archiveLimitExceeded }

        let directory = try Self.read(handle, offset: directoryOffset, count: Int(directorySize))
        var cursor = 0
        var parsed: [String: Entry] = [:]
        var totalUncompressed: UInt64 = 0
        for _ in 0..<entryCount {
            guard cursor + 46 <= directory.count, Self.u32(directory, cursor) == 0x02014b50 else { throw ContentDetectionError.unsafeArchive("invalid central directory") }
            let flags = Self.u16(directory, cursor + 8)
            let compression = Self.u16(directory, cursor + 10)
            let compressed = UInt64(Self.u32(directory, cursor + 20))
            let uncompressed = UInt64(Self.u32(directory, cursor + 24))
            let nameLength = Int(Self.u16(directory, cursor + 28))
            let extraLength = Int(Self.u16(directory, cursor + 30))
            let commentLength = Int(Self.u16(directory, cursor + 32))
            let localOffset = UInt64(Self.u32(directory, cursor + 42))
            let next = cursor + 46 + nameLength + extraLength + commentLength
            guard next <= directory.count, flags & 1 == 0, compressed != 0xffff_ffff, uncompressed != 0xffff_ffff else { throw ContentDetectionError.unsafeArchive("encrypted or ZIP64 entry") }
            guard let name = String(data: directory[(cursor + 46)..<(cursor + 46 + nameLength)], encoding: .utf8), Self.safe(name) else { throw ContentDetectionError.unsafeArchive("unsafe entry path") }
            let (sum, overflow) = totalUncompressed.addingReportingOverflow(uncompressed)
            guard !overflow, sum <= limits.maximumArchiveUncompressedBytes else { throw ContentDetectionError.archiveLimitExceeded }
            totalUncompressed = sum
            if uncompressed > 0 {
                guard compressed > 0, uncompressed / compressed <= limits.maximumCompressionRatio else { throw ContentDetectionError.archiveLimitExceeded }
            }
            guard parsed[name] == nil else { throw ContentDetectionError.unsafeArchive("duplicate entry") }
            guard compression == 0 || compression == 8 else { throw ContentDetectionError.unsafeArchive("unsupported compression") }
            let localHeader = try Self.read(handle, offset: localOffset, count: 30)
            guard Self.u32(localHeader, 0) == 0x04034b50,
                  Self.u16(localHeader, 8) == compression,
                  Self.u16(localHeader, 6) & 1 == 0 else { throw ContentDetectionError.unsafeArchive("invalid local header") }
            let localNameLength = UInt64(Self.u16(localHeader, 26))
            let localExtraLength = UInt64(Self.u16(localHeader, 28))
            let dataOffset = localOffset + 30 + localNameLength + localExtraLength
            let (dataEnd, dataOverflow) = dataOffset.addingReportingOverflow(compressed)
            guard !dataOverflow, dataEnd <= directoryOffset else { throw ContentDetectionError.unsafeArchive("entry outside data area") }
            let localNameData = try Self.read(handle, offset: localOffset + 30, count: Int(localNameLength))
            guard String(data: localNameData, encoding: .utf8) == name else { throw ContentDetectionError.unsafeArchive("local name mismatch") }
            if flags & 0x8 == 0 {
                guard UInt64(Self.u32(localHeader, 18)) == compressed, UInt64(Self.u32(localHeader, 22)) == uncompressed else {
                    throw ContentDetectionError.unsafeArchive("local size mismatch")
                }
            }
            parsed[name] = Entry(compression: compression, compressedSize: compressed, uncompressedSize: uncompressed, localOffset: localOffset)
            cursor = next
        }
        guard cursor == directory.count else { throw ContentDetectionError.unsafeArchive("trailing central data") }
        self.url = url
        self.entries = parsed
        self.names = Set(parsed.keys)
    }

    func storedContents(named name: String) throws -> Data? {
        guard let entry = entries[name] else { return nil }
        guard entry.compression == 0, entry.compressedSize == entry.uncompressedSize, entry.uncompressedSize <= 1_024 else { return nil }
        let header = try Self.read(url, offset: entry.localOffset, count: 30)
        guard header.count == 30, Self.u32(header, 0) == 0x04034b50 else { throw ContentDetectionError.unsafeArchive("invalid local header") }
        let nameLength = UInt64(Self.u16(header, 26))
        let extraLength = UInt64(Self.u16(header, 28))
        return try Self.read(url, offset: entry.localOffset + 30 + nameLength + extraLength, count: Int(entry.uncompressedSize))
    }

    private static func safe(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"), !name.contains("\0") else { return false }
        return !name.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }

    private static func read(_ handle: FileHandle, offset: UInt64, count: Int) throws -> Data {
        try handle.seek(toOffset: offset)
        guard let data = try handle.read(upToCount: count), data.count == count else { throw ContentDetectionError.unsafeArchive("truncated archive") }
        return data
    }

    private static func read(_ url: URL, offset: UInt64, count: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        guard let data = try handle.read(upToCount: count), data.count == count else { throw ContentDetectionError.unsafeArchive("truncated archive") }
        return data
    }

    private static func lastSignature(_ signature: UInt32, in data: Data) -> Int? {
        guard data.count >= 4 else { return nil }
        for offset in stride(from: data.count - 4, through: 0, by: -1) where u32(data, offset) == signature { return offset }
        return nil
    }

    private static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }
}
