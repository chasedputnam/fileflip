import CoreGraphics
import FileConvertCore
import Foundation
import ImageIO
import PDFKit

public struct PDFValidationResult: Hashable, Sendable {
    public let hash: Data
    public let pageCount: Int
}

public struct PDFValidator: Sendable {
    public static let id = ValidatorID(rawValue: "native-pdf-validator-v1")
    public init() {}

    public func validate(_ artifact: ProducedArtifact, maximumBytes: UInt64 = .max) throws -> PDFValidationResult {
        try regularFile(artifact.url, maximumBytes: maximumBytes)
        guard let document = PDFDocument(url: artifact.url), document.pageCount > 0 else {
            throw FileConvertError.validationFailed("PDF output is unreadable")
        }
        return PDFValidationResult(hash: try TransactionCoordinator.sha256(artifact.url), pageCount: document.pageCount)
    }

    public func certificationValidator() -> IndependentValidator {
        IndependentValidator(id: Self.id, targetExtensions: ["pdf"]) { artifact, expected in
            guard case .document(.pdf) = expected else { throw FileConvertError.validationFailed("PDF validator received a non-PDF expectation") }
            let result = try validate(artifact)
            return (result.hash, .document(.pdf))
        }
    }
}

public struct TextValidator: Sendable {
    public static let id = ValidatorID(rawValue: "strict-text-validator-v1")
    public init() {}

    public func validate(_ artifact: ProducedArtifact, maximumBytes: UInt64 = .max) throws -> Data {
        try regularFile(artifact.url, maximumBytes: maximumBytes)
        let data = try Data(contentsOf: artifact.url, options: [.mappedIfSafe])
        guard String(data: data, encoding: .utf8) != nil else {
            throw FileConvertError.validationFailed("Text output is not UTF-8")
        }
        return try TransactionCoordinator.sha256(artifact.url)
    }

    public func certificationValidator() -> IndependentValidator {
        IndependentValidator(id: Self.id, targetExtensions: ["txt"]) { artifact, expected in
            guard case .document(.text) = expected else { throw FileConvertError.validationFailed("Text validator received a non-text expectation") }
            return (try validate(artifact), .document(.text))
        }
    }
}

public struct HTMLValidator: Sendable {
    public static let id = ValidatorID(rawValue: "safe-html-validator-v1")
    public init() {}

    public func validate(_ artifact: ProducedArtifact, maximumBytes: UInt64 = .max) throws -> Data {
        try regularFile(artifact.url, maximumBytes: maximumBytes)
        let data = try Data(contentsOf: artifact.url, options: [.mappedIfSafe])
        guard let html = String(data: data, encoding: .utf8) else {
            throw FileConvertError.validationFailed("HTML output is not UTF-8")
        }
        try SafeHTMLSubset.validate(html)
        return try TransactionCoordinator.sha256(artifact.url)
    }

    public func certificationValidator() -> IndependentValidator {
        IndependentValidator(id: Self.id, targetExtensions: ["html", "htm"]) { artifact, expected in
            guard case .document(.html) = expected else { throw FileConvertError.validationFailed("HTML validator received a non-HTML expectation") }
            return (try validate(artifact), .document(.html))
        }
    }
}

public struct MarkdownValidator: Sendable {
    public static let id = ValidatorID(rawValue: "strict-markdown-validator-v1")
    public init() {}

    public func validate(_ artifact: ProducedArtifact, maximumBytes: UInt64 = .max) throws -> Data {
        try regularFile(artifact.url, maximumBytes: maximumBytes)
        let data = try Data(contentsOf: artifact.url, options: [.mappedIfSafe])
        guard let markdown = String(data: data, encoding: .utf8), !markdown.contains("\u{0}") else {
            throw FileConvertError.validationFailed("Markdown output is not safe UTF-8 text")
        }
        return try TransactionCoordinator.sha256(artifact.url)
    }

    public func certificationValidator() -> IndependentValidator {
        IndependentValidator(id: Self.id, targetExtensions: ["md", "markdown"]) { artifact, expected in
            guard case .document(.markdown) = expected else { throw FileConvertError.validationFailed("Markdown validator received a non-Markdown expectation") }
            return (try validate(artifact), .document(.markdown))
        }
    }
}

public struct PDFPageImageValidator: Sendable {
    public static let id = ValidatorID(rawValue: "pdf-page-image-validator-v1")
    public init() {}

    public func certificationValidator() -> IndependentValidator {
        IndependentValidator(id: Self.id, targetExtensions: ["png", "jpg", "jpeg"]) { artifact, expected in
            guard case let .image(format) = expected else { throw FileConvertError.validationFailed("PDF page validator received a non-image expectation") }
            let result = try NativeImageValidator().validate(artifact, expectation: .init(format: format, maximumBytes: .max))
            return (result.hash, .image(result.format))
        }
    }
}

private func regularFile(_ url: URL, maximumBytes: UInt64) throws {
    var status = stat()
    guard lstat(url.path, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else {
        throw FileConvertError.validationFailed("Output is not a regular file")
    }
    let size = UInt64(status.st_size)
    guard size > 0, size <= maximumBytes else { throw FileConvertError.validationFailed("Output is empty or exceeds its byte limit") }
}
