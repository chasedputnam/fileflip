import CoreGraphics
import CoreImage
import FileConvertCore
import Foundation
import ImageIO

public struct NativeImageProvider: ConversionProvider {
    public let id = ProviderID(rawValue: "native-imageio")

    public init() {}

    public func health() async -> ProviderHealth {
        supportedTargets().isEmpty ? .unavailable(reason: "No approved ImageIO encoders are writable") : .available(version: ProcessInfo.processInfo.operatingSystemVersionString)
    }

    public func capabilities() async -> Set<ConversionCapability> {
        let readable = Set((CGImageSourceCopyTypeIdentifiers() as? [String]) ?? [])
        let sources = ImageFormat.allCases.filter { format in
            Self.sourceIdentifiers[format, default: []].contains(where: readable.contains)
        }
        return Set(sources.flatMap { source in
            supportedTargets().compactMap { target -> ConversionCapability? in
                guard source != target.format else { return nil }
                return ConversionCapability(
                    source: .image(source),
                    targetExtension: target.targetExtension,
                    providerID: id,
                    defaultPolicy: .image(),
                    lossProfile: target.format == .jpeg || target.format == .heic ? .potentiallyLossy : .lossless
                )
            }
        })
    }

    public func convert(_ request: ConversionRequest) async throws -> ProducedArtifact {
        try Task.checkCancellation()
        guard Date() < request.deadline else { throw FileConvertError.timedOut }
        guard case let .image(version, quality, alphaBackground, frames, metadata, orientation, colorProfile) = request.policy,
              version > 0, quality.isFinite, (0 ... 1).contains(quality) else {
            throw FileConvertError.validationFailed("Invalid image policy")
        }
        guard let target = supportedTargets().first(where: { $0.targetExtension == Self.normalize(request.targetExtension) }) else {
            throw FileConvertError.unsupportedPair
        }
        guard let source = CGImageSourceCreateWithURL(request.source.url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw FileConvertError.validationFailed("Image source is not decodable")
        }
        let sourceCount = CGImageSourceGetCount(source)
        guard sourceCount > 0 else { throw FileConvertError.validationFailed("Image has no frames") }
        let indexes = try Self.selectedIndexes(frames, count: sourceCount)
        if indexes.count > 1, target.format != .tiff {
            throw FileConvertError.unsupportedPair
        }
        let destinationType = try destinationType(for: target.format)
        let output = request.outputDirectory.appending(path: "output.\(target.targetExtension)")
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw FileConvertError.validationFailed("Provider output already exists")
        }
        let encodingDirectory = request.outputDirectory.appending(path: ".image-provider-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: encodingDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let encodedOutput = encodingDirectory.appending(path: "encoded.\(target.targetExtension)")
        var keepOutput = false
        defer {
            try? FileManager.default.removeItem(at: encodingDirectory)
            if !keepOutput { try? FileManager.default.removeItem(at: output) }
        }
        guard let destination = CGImageDestinationCreateWithURL(encodedOutput as CFURL, destinationType as CFString, indexes.count, nil) else {
            throw FileConvertError.providerUnavailable("Image destination could not be created")
        }

        for index in indexes {
            try Task.checkCancellation()
            guard Date() < request.deadline else { throw FileConvertError.timedOut }
            guard let original = CGImageSourceCreateImageAtIndex(source, index, [kCGImageSourceShouldCache: false] as CFDictionary) else {
                throw FileConvertError.validationFailed("Image frame is not decodable")
            }
            let hasAlpha = Self.hasAlpha(original)
            if hasAlpha && target.format == .jpeg && alphaBackground == nil {
                throw FileConvertError.requiresChoice
            }
            let rendered = try Self.render(
                original,
                properties: CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:],
                orientation: orientation,
                colorProfile: colorProfile,
                alphaBackgroundARGB: target.format == .jpeg ? alphaBackground : nil
            )
            let properties = Self.destinationProperties(
                source: CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:],
                metadata: metadata,
                orientation: orientation,
                colorProfile: colorProfile,
                quality: quality
            )
            CGImageDestinationAddImage(destination, rendered, properties as CFDictionary)
        }

        guard CGImageDestinationFinalize(destination) else {
            throw FileConvertError.validationFailed("Image encoder did not finalize output")
        }
        let size = try encodedOutput.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, UInt64(size) <= request.maximumOutputBytes else {
            throw FileConvertError.validationFailed("Image output exceeds its byte limit")
        }
        try Task.checkCancellation()
        guard Date() < request.deadline else {
            throw FileConvertError.timedOut
        }
        try FileManager.default.moveItem(at: encodedOutput, to: output)
        keepOutput = true
        return ProducedArtifact(url: output, providerID: id)
    }

    private struct Target: Hashable {
        let format: ImageFormat
        let targetExtension: String
        let identifier: String
    }

    private static let sourceIdentifiers: [ImageFormat: Set<String>] = [
        .jpeg: ["public.jpeg"],
        .png: ["public.png"],
        .heic: ["public.heic", "public.heics", "public.heif"],
        .tiff: ["public.tiff"],
        .webP: ["org.webmproject.webp"],
    ]

    private func supportedTargets() -> [Target] {
        let writable = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
        return [
            Target(format: .jpeg, targetExtension: "jpg", identifier: "public.jpeg"),
            Target(format: .jpeg, targetExtension: "jpeg", identifier: "public.jpeg"),
            Target(format: .png, targetExtension: "png", identifier: "public.png"),
            Target(format: .heic, targetExtension: "heic", identifier: "public.heic"),
            Target(format: .heic, targetExtension: "heif", identifier: "public.heic"),
            Target(format: .tiff, targetExtension: "tiff", identifier: "public.tiff"),
            Target(format: .tiff, targetExtension: "tif", identifier: "public.tiff"),
            Target(format: .webP, targetExtension: "webp", identifier: "org.webmproject.webp"),
        ].filter { writable.contains($0.identifier) }
    }

    private func destinationType(for format: ImageFormat) throws -> String {
        guard let target = supportedTargets().first(where: { $0.format == format }) else {
            throw FileConvertError.unsupportedPair
        }
        return target.identifier
    }

    private static func selectedIndexes(_ policy: ImageFramePolicy, count: Int) throws -> [Int] {
        switch policy {
        case .requireSingle:
            guard count == 1 else { throw FileConvertError.validationFailed("Multi-frame input requires an explicit frame policy") }
            return [0]
        case .first:
            return [0]
        case let .index(index):
            guard (0 ..< count).contains(index) else { throw FileConvertError.validationFailed("Frame index is out of range") }
            return [index]
        case .all:
            return Array(0 ..< count)
        }
    }

    private static func render(
        _ image: CGImage,
        properties: [CFString: Any],
        orientation: ImageOrientationMode,
        colorProfile: ImageColorProfileMode,
        alphaBackgroundARGB: UInt32?
    ) throws -> CGImage {
        var oriented = CIImage(cgImage: image)
        if orientation == .normalizePixels {
            let value = (properties[kCGImagePropertyOrientation] as? NSNumber)?.int32Value ?? 1
            oriented = oriented.oriented(forExifOrientation: value)
        }
        let translated = oriented.transformed(by: CGAffineTransform(translationX: -oriented.extent.origin.x, y: -oriented.extent.origin.y))
        let colorSpace: CGColorSpace
        switch colorProfile {
        case .preserve:
            colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        case .convertToSRGB:
            guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else { throw FileConvertError.validationFailed("sRGB is unavailable") }
            colorSpace = sRGB
        case .strip:
            colorSpace = CGColorSpaceCreateDeviceRGB()
        }
        guard let rendered = CIContext(options: [.cacheIntermediates: false]).createCGImage(translated, from: translated.extent, format: .RGBA8, colorSpace: colorSpace) else {
            throw FileConvertError.validationFailed("Image orientation or color conversion failed")
        }
        guard let argb = alphaBackgroundARGB else { return rendered }
        let width = rendered.width
        let height = rendered.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw FileConvertError.validationFailed("Image alpha flattening failed")
        }
        let a = CGFloat((argb >> 24) & 0xff) / 255
        let r = CGFloat((argb >> 16) & 0xff) / 255
        let g = CGFloat((argb >> 8) & 0xff) / 255
        let b = CGFloat(argb & 0xff) / 255
        context.setFillColor(red: r, green: g, blue: b, alpha: a)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(rendered, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let flattened = context.makeImage() else { throw FileConvertError.validationFailed("Image alpha flattening failed") }
        return flattened
    }

    private static func destinationProperties(
        source: [CFString: Any],
        metadata: MetadataMode,
        orientation: ImageOrientationMode,
        colorProfile: ImageColorProfileMode,
        quality: Double
    ) -> [CFString: Any] {
        var properties = metadata == .preserve ? source : [:]
        properties[kCGImageDestinationLossyCompressionQuality] = quality
        if orientation == .normalizePixels { properties[kCGImagePropertyOrientation] = 1 }
        if colorProfile == .strip { properties[kCGImagePropertyProfileName] = nil }
        return properties
    }

    private static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly:
            true
        case .none, .noneSkipFirst, .noneSkipLast:
            false
        @unknown default:
            true
        }
    }

    private static func normalize(_ value: String) -> String {
        value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }
}
