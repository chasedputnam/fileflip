import CryptoKit
import Darwin
import FileConvertCore
import Foundation

/// Bounded central-directory inspection used independently of LibreOffice for input denial and output validation.
public enum OfficePackageInspector {
    private static let maximumEntries = 100_000
    private static let maximumDeclaredBytes: UInt64 = 4 * 1024 * 1024 * 1024

    public static func rejectUnsafeInput(_ url: URL, format: DetectedFormat) throws {
        let ext = url.pathExtension.lowercased()
        if ["docx", "odt", "xlsx", "ods"].contains(ext) {
            let entries = try zipEntries(url)
            guard !entries.contains(where: \.isEncrypted) else { throw FileConvertError.validationFailed("Password-protected Office packages are not permitted") }
            let names = Set(entries.map(\.name))
            guard !names.contains(where: {
                let name = $0.lowercased()
                return name.contains("vbaproject.bin") || name.contains("basic/") || name.contains("scripts/")
            }) else { throw FileConvertError.validationFailed("Office macros are not permitted") }
            guard !names.contains(where: {
                let name = $0.lowercased()
                return name.contains("externallink") || name.contains("external-data") || name == "encryptioninfo" || name == "encryptedpackage"
            }) else { throw FileConvertError.validationFailed("Office external links or password protection are not permitted") }
            guard !names.contains(where: {
                let name = $0.lowercased()
                return name.contains("/embeddings/") || name.contains("oleobject") || name.contains("objectreplacements")
            }) else { throw FileConvertError.validationFailed("Embedded Office resources are not permitted without an explicit policy") }
        } else if ext == "rtf" {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard !String(decoding: data.prefix(1 << 20), as: UTF8.self).localizedCaseInsensitiveContains("\\password") else { throw FileConvertError.validationFailed("Password-protected RTF is not permitted") }
        }
    }

    public static func requireSheetPolicy(_ url: URL, policy: ConversionPolicy) throws {
        guard case let .spreadsheet(_, sheetIndex, _, _) = policy else { throw FileConvertError.validationFailed("Spreadsheet policy required") }
        let ext = url.pathExtension.lowercased()
        guard ["xlsx", "ods"].contains(ext) else { return }
        let count = try sheetCount(url, ext: ext)
        guard count <= 1 || sheetIndex != nil, sheetIndex.map({ (0 ..< count).contains($0) }) ?? true else { throw FileConvertError.requiresChoice }
    }

    public static func zipEntries(_ url: URL) throws -> [Entry] {
        var st = stat()
        guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size > 22, st.st_size <= Int64(maximumDeclaredBytes) else { throw FileConvertError.validationFailed("Office package is not a bounded regular file") }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard let eocd = data.range(of: Data([0x50, 0x4b, 0x05, 0x06]), options: .backwards, in: 0 ..< data.count) else { throw FileConvertError.validationFailed("Missing ZIP central directory") }
        let start = eocd.lowerBound
        guard start + 22 <= data.count else { throw FileConvertError.validationFailed("Truncated ZIP directory") }
        let count = Int(u16(data, start + 10)); let directorySize = Int(u32(data, start + 12)); let directoryOffset = Int(u32(data, start + 16))
        guard count <= maximumEntries, directorySize >= 0, directoryOffset >= 0, directoryOffset + directorySize <= data.count else { throw FileConvertError.validationFailed("ZIP directory exceeds bounds") }
        var entries: [Entry] = []; var cursor = directoryOffset; var declared: UInt64 = 0
        for _ in 0 ..< count {
            guard cursor + 46 <= data.count, u32(data, cursor) == 0x02014b50 else { throw FileConvertError.validationFailed("Invalid ZIP directory entry") }
            let flags = u16(data, cursor + 8)
            let compressed = UInt64(u32(data, cursor + 20)); let uncompressed = UInt64(u32(data, cursor + 24)); let nameLength = Int(u16(data, cursor + 28)); let extraLength = Int(u16(data, cursor + 30)); let commentLength = Int(u16(data, cursor + 32)); let end = cursor + 46 + nameLength + extraLength + commentLength
            guard end <= data.count, compressed > 0 ? uncompressed <= compressed * 100 : uncompressed == 0 else { throw FileConvertError.validationFailed("ZIP expansion ratio is unsafe") }
            let nameData = data.subdata(in: (cursor + 46) ..< (cursor + 46 + nameLength)); guard let name = String(data: nameData, encoding: .utf8), !name.isEmpty, !name.hasPrefix("/"), !name.split(separator: "/").contains("..") else { throw FileConvertError.validationFailed("Unsafe ZIP entry path") }
            let (next, overflow) = declared.addingReportingOverflow(uncompressed); guard !overflow, next <= maximumDeclaredBytes else { throw FileConvertError.validationFailed("ZIP declared size exceeds bound") }; declared = next
            entries.append(Entry(name: name, compressedBytes: compressed, uncompressedBytes: uncompressed, isEncrypted: flags & 1 != 0)); cursor = end
        }
        return entries
    }

    public static func sheetCount(_ url: URL, ext: String) throws -> Int {
        let names = try zipEntries(url).map(\.name)
        if ext == "xlsx" { return names.filter { $0.hasPrefix("xl/worksheets/sheet") && $0.hasSuffix(".xml") }.count }
        return names.filter { $0 == "content.xml" }.isEmpty ? 0 : 1 // ODF sheet element content needs XML parsing; presence is the bounded structural proof.
    }

    private static func u16(_ data: Data, _ index: Int) -> UInt16 {
        UInt16(data[index]) | UInt16(data[index + 1]) << 8
    }
    private static func u32(_ data: Data, _ index: Int) -> UInt32 {
        UInt32(data[index]) | UInt32(data[index + 1]) << 8 | UInt32(data[index + 2]) << 16 | UInt32(data[index + 3]) << 24
    }
    public struct Entry: Hashable, Sendable {
        public let name: String
        public let compressedBytes: UInt64
        public let uncompressedBytes: UInt64
        public let isEncrypted: Bool
    }
}

public struct OfficeSemanticSummary: Hashable, Sendable {
    public let format: DetectedFormat
    public let readableContent: Bool
    public let pageCount: Int?
    public let sheetCount: Int?
    public let hasFormulaMarkers: Bool
    public let fidelityWarnings: [String]
}

public struct OfficeArtifactValidator: Sendable {
    public static let id = ValidatorID(rawValue: "office-package-validator-v1")
    public init() {}

    public func validator() -> IndependentValidator { IndependentValidator(id: Self.id, targetExtensions: ["docx", "odt", "rtf", "pdf", "txt", "html", "xlsx", "ods", "csv"], validate: validate) }

    public func validate(_ artifact: ProducedArtifact, expected: DetectedFormat) async throws -> (hash: Data, format: DetectedFormat) {
        let ext = artifact.url.pathExtension.lowercased()
        let actual = try validate(url: artifact.url, targetExtension: ext)
        guard actual == expected else { throw FileConvertError.validationFailed("Office output does not match requested format") }
        return (Data(SHA256.hash(data: try Data(contentsOf: artifact.url, options: [.mappedIfSafe]))), actual)
    }

    public func validate(url: URL, targetExtension: String) throws -> DetectedFormat {
        var st = stat()
        guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size > 0 else { throw FileConvertError.validationFailed("Office output is not a regular nonempty file") }
        switch targetExtension.lowercased() {
        case "docx": let names = Set(try OfficePackageInspector.zipEntries(url).map(\.name)); guard names.contains("[Content_Types].xml"), names.contains("word/document.xml") else { throw FileConvertError.validationFailed("Invalid DOCX") }; return .document(.docx)
        case "odt": let names = Set(try OfficePackageInspector.zipEntries(url).map(\.name)); guard names.contains("mimetype"), names.contains("content.xml") else { throw FileConvertError.validationFailed("Invalid ODT") }; return .document(.odt)
        case "xlsx": let names = Set(try OfficePackageInspector.zipEntries(url).map(\.name)); guard names.contains("[Content_Types].xml"), names.contains("xl/workbook.xml"), names.contains(where: { $0.hasPrefix("xl/worksheets/sheet") }) else { throw FileConvertError.validationFailed("Invalid XLSX") }; return .spreadsheet(.xlsx)
        case "ods": let names = Set(try OfficePackageInspector.zipEntries(url).map(\.name)); guard names.contains("mimetype"), names.contains("content.xml") else { throw FileConvertError.validationFailed("Invalid ODS") }; return .spreadsheet(.ods)
        case "pdf": let data = try Data(contentsOf: url, options: [.mappedIfSafe]); guard data.starts(with: Data("%PDF-".utf8)), data.suffix(4096).range(of: Data("%%EOF".utf8)) != nil else { throw FileConvertError.validationFailed("Invalid PDF") }; return .document(.pdf)
        case "rtf": let data = try Data(contentsOf: url, options: [.mappedIfSafe]); guard data.starts(with: Data("{\\rtf".utf8)) else { throw FileConvertError.validationFailed("Invalid RTF") }; return .document(.rtf)
        case "txt": let data = try Data(contentsOf: url, options: [.mappedIfSafe]); guard String(data: data, encoding: .utf8) != nil else { throw FileConvertError.validationFailed("TXT is not UTF-8") }; return .document(.text)
        case "html": let text = try String(contentsOf: url, encoding: .utf8).lowercased(); guard text.contains("<html") || text.contains("<!doctype html") else { throw FileConvertError.validationFailed("Invalid HTML") }; return .document(.html)
        case "csv": let text = try String(contentsOf: url, encoding: .utf8); guard !text.isEmpty, !text.unicodeScalars.contains(where: { $0.value == 0 }) else { throw FileConvertError.validationFailed("Invalid CSV") }; return .spreadsheet(.csv)
        default: throw FileConvertError.unsupportedPair
        }
    }

    public func semanticSummary(url: URL, targetExtension: String) throws -> OfficeSemanticSummary {
        let format = try validate(url: url, targetExtension: targetExtension)
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let text = String(decoding: data.prefix(1 << 20), as: UTF8.self)
        switch format {
        case .document(.pdf):
            let pages = text.components(separatedBy: "/Type /Page").count - 1
            guard pages > 0 else { throw FileConvertError.validationFailed("PDF has no pages") }
            return OfficeSemanticSummary(format: format, readableContent: text.contains("/Contents"), pageCount: pages, sheetCount: nil, hasFormulaMarkers: false, fidelityWarnings: [])
        case .spreadsheet(.xlsx), .spreadsheet(.ods):
            let sheets = try OfficePackageInspector.sheetCount(url, ext: targetExtension.lowercased())
            guard sheets > 0 else { throw FileConvertError.validationFailed("Spreadsheet has no sheets") }
            return OfficeSemanticSummary(format: format, readableContent: true, pageCount: nil, sheetCount: sheets, hasFormulaMarkers: text.contains("<f") || text.contains("formula"), fidelityWarnings: ["Spreadsheet formatting, comments, and embedded resources may not round-trip"])
        case .spreadsheet(.csv):
            return OfficeSemanticSummary(format: format, readableContent: !text.isEmpty, pageCount: nil, sheetCount: 1, hasFormulaMarkers: false, fidelityWarnings: ["CSV cannot preserve formulas, comments, or multiple sheets"])
        case .document:
            return OfficeSemanticSummary(format: format, readableContent: !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, pageCount: nil, sheetCount: nil, hasFormulaMarkers: false, fidelityWarnings: ["Document layout may vary with installed fonts"])
        default:
            throw FileConvertError.unsupportedPair
        }
    }
}
