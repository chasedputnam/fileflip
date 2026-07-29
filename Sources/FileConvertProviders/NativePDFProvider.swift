import CoreGraphics
import FileConvertCore
import Foundation
import ImageIO
import PDFKit

/// Renders individual PDF pages or extracts the PDF's existing text. It never
/// attempts to reconstruct a semantic document from a PDF.
public struct NativePDFProvider: ConversionProvider {
    public let id = ProviderID(rawValue: "native-pdfkit")

    public init() {}

    public func health() async -> ProviderHealth {
        .available(version: ProcessInfo.processInfo.operatingSystemVersionString)
    }

    public func capabilities() async -> Set<ConversionCapability> {
        [
            ConversionCapability(source: .document(.pdf), targetExtension: "png", providerID: id, defaultPolicy: .document(), lossProfile: .requiresChoice),
            ConversionCapability(source: .document(.pdf), targetExtension: "jpg", providerID: id, defaultPolicy: .document(), lossProfile: .requiresChoice),
            ConversionCapability(source: .document(.pdf), targetExtension: "jpeg", providerID: id, defaultPolicy: .document(), lossProfile: .requiresChoice),
            ConversionCapability(source: .document(.pdf), targetExtension: "txt", providerID: id, defaultPolicy: .document(), lossProfile: .potentiallyLossy),
        ]
    }

    public func convert(_ request: ConversionRequest) async throws -> ProducedArtifact {
        try Task.checkCancellation()
        guard Date() < request.deadline else { throw FileConvertError.timedOut }
        guard case let .document(version, acceptsFidelityLoss, pageIndex, imageQuality) = request.policy,
              version == 1, imageQuality.isFinite, (0 ... 1).contains(imageQuality) else {
            throw FileConvertError.validationFailed("PDF conversion requires a version 1 document policy with image quality between 0 and 1")
        }
        guard let document = PDFDocument(url: request.source.url), document.pageCount > 0 else {
            throw FileConvertError.validationFailed("PDF source is unreadable or has no pages")
        }

        let target = normalize(request.targetExtension)
        switch target {
        case "png", "jpg", "jpeg":
            let page = try selectedPage(in: document, pageIndex: pageIndex, acceptsFidelityLoss: acceptsFidelityLoss)
            return try render(page: page, targetExtension: target, imageQuality: imageQuality, request: request)
        case "txt":
            guard pageIndex == nil else {
                throw FileConvertError.validationFailed("PDF text extraction does not accept a page-selection policy")
            }
            return try extractText(from: document, request: request)
        default:
            throw FileConvertError.unsupportedPair
        }
    }

    private func selectedPage(in document: PDFDocument, pageIndex: Int?, acceptsFidelityLoss: Bool) throws -> PDFPage {
        if document.pageCount > 1 && pageIndex == nil {
            throw FileConvertError.requiresChoice
        }
        guard acceptsFidelityLoss else {
            throw FileConvertError.requiresChoice
        }
        let index = pageIndex ?? 0
        guard index >= 0, index < document.pageCount, let page = document.page(at: index) else {
            throw FileConvertError.validationFailed("PDF page index is out of range")
        }
        return page
    }

    private func render(page: PDFPage, targetExtension: String, imageQuality: Double, request: ConversionRequest) throws -> ProducedArtifact {
        let bounds = page.bounds(for: .mediaBox).integral
        guard bounds.width > 0, bounds.height > 0,
              bounds.width <= 32_768, bounds.height <= 32_768 else {
            throw FileConvertError.validationFailed("PDF page dimensions are unsafe to rasterize")
        }
        let width = Int(bounds.width)
        let height = Int(bounds.height)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw FileConvertError.validationFailed("Unable to create PDF raster context")
        }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.saveGState()
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        page.draw(with: .mediaBox, to: context)
        context.restoreGState()
        guard let image = context.makeImage() else {
            throw FileConvertError.validationFailed("PDF rasterization produced no image")
        }

        let output = request.outputDirectory.appending(path: "output.\(targetExtension)")
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw FileConvertError.validationFailed("Provider output already exists")
        }
        let type = targetExtension == "png" ? "public.png" : "public.jpeg"
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, type as CFString, 1, nil) else {
            throw FileConvertError.validationFailed("Unable to create PDF image output")
        }
        let properties: [CFString: Any] = targetExtension == "png" ? [:] : [kCGImageDestinationLossyCompressionQuality: imageQuality]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw FileConvertError.validationFailed("Unable to encode PDF image output")
        }
        try validateOutputSize(output, maximum: request.maximumOutputBytes)
        return ProducedArtifact(url: output, providerID: id)
    }

    private func extractText(from document: PDFDocument, request: ConversionRequest) throws -> ProducedArtifact {
        let text = (0 ..< document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n\u{000C}\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FileConvertError.validationFailed("PDF has no extractable text")
        }
        let output = request.outputDirectory.appending(path: "output.txt")
        guard let data = text.data(using: .utf8), UInt64(data.count) <= request.maximumOutputBytes else {
            throw FileConvertError.validationFailed("PDF text output exceeds its byte limit")
        }
        try data.write(to: output, options: .atomic)
        return ProducedArtifact(url: output, providerID: id)
    }

    private func validateOutputSize(_ output: URL, maximum: UInt64) throws {
        let size = UInt64(try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        guard size > 0, size <= maximum else {
            throw FileConvertError.validationFailed("PDF output is empty or exceeds its byte limit")
        }
    }

    private func normalize(_ extension: String) -> String {
        `extension`.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }
}
