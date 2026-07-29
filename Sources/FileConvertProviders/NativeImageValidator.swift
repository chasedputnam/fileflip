import CoreGraphics
import FileConvertCore
import Foundation
import ImageIO

public struct ImageValidationExpectation: Hashable, Sendable {
    public struct Dimensions: Hashable, Sendable {
        public let width: Int
        public let height: Int

        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }
    }

    public let format: ImageFormat
    public let dimensions: Dimensions?
    public let frameCount: Int?
    public let hasAlpha: Bool?
    public let normalizedOrientation: Bool
    public let requiresEmbeddedColorProfile: Bool?
    public let maximumBytes: UInt64

    public init(
        format: ImageFormat,
        dimensions: Dimensions? = nil,
        frameCount: Int? = nil,
        hasAlpha: Bool? = nil,
        normalizedOrientation: Bool = false,
        requiresEmbeddedColorProfile: Bool? = nil,
        maximumBytes: UInt64
    ) {
        self.format = format
        self.dimensions = dimensions
        self.frameCount = frameCount
        self.hasAlpha = hasAlpha
        self.normalizedOrientation = normalizedOrientation
        self.requiresEmbeddedColorProfile = requiresEmbeddedColorProfile
        self.maximumBytes = maximumBytes
    }
}

public struct ImageValidationResult: Hashable, Sendable {
    public let hash: Data
    public let format: ImageFormat
    public let dimensions: ImageValidationExpectation.Dimensions
    public let frameCount: Int
    public let hasAlpha: Bool
    public let hasEmbeddedColorProfile: Bool
}

public struct NativeImageValidator: Sendable {
    public static let id = ValidatorID(rawValue: "native-image-validator-v1")

    public init() {}

    public func validate(_ artifact: ProducedArtifact, expectation: ImageValidationExpectation) throws -> ImageValidationResult {
        var statBuffer = stat()
        guard lstat(artifact.url.path, &statBuffer) == 0,
              (statBuffer.st_mode & S_IFMT) == S_IFREG,
              (statBuffer.st_mode & S_IFMT) != S_IFLNK else {
            throw FileConvertError.validationFailed("Image output is not a regular file")
        }
        let byteCount = UInt64(statBuffer.st_size)
        guard byteCount > 0, byteCount <= expectation.maximumBytes else {
            throw FileConvertError.validationFailed("Image output is empty or exceeds its byte limit")
        }
        guard let source = CGImageSourceCreateWithURL(artifact.url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let identifier = CGImageSourceGetType(source) as String?,
              let actualFormat = Self.format(identifier) else {
            throw FileConvertError.validationFailed("Image output has an unrecognized content type")
        }
        guard actualFormat == expectation.format else {
            throw FileConvertError.validationFailed("Image content does not match the requested format")
        }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { throw FileConvertError.validationFailed("Image output has no frames") }
        if let expectedCount = expectation.frameCount, count != expectedCount {
            throw FileConvertError.validationFailed("Image output frame count changed")
        }

        var commonDimensions: ImageValidationExpectation.Dimensions?
        var anyAlpha = false
        var hasProfile = false
        for index in 0 ..< count {
            guard let image = CGImageSourceCreateImageAtIndex(source, index, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
                throw FileConvertError.validationFailed("Image output contains an undecodable frame")
            }
            let dimensions = ImageValidationExpectation.Dimensions(width: image.width, height: image.height)
            guard dimensions.width > 0, dimensions.height > 0 else {
                throw FileConvertError.validationFailed("Image output has invalid dimensions")
            }
            if commonDimensions == nil { commonDimensions = dimensions }
            if let expectedDimensions = expectation.dimensions, dimensions != expectedDimensions {
                throw FileConvertError.validationFailed("Image output dimensions changed")
            }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
            if expectation.normalizedOrientation,
               (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1 != 1 {
                throw FileConvertError.validationFailed("Image output orientation was not normalized")
            }
            anyAlpha = anyAlpha || Self.hasAlpha(image)
            hasProfile = hasProfile || image.colorSpace?.name != nil || properties[kCGImagePropertyProfileName] != nil
        }
        if let expectedAlpha = expectation.hasAlpha, anyAlpha != expectedAlpha {
            throw FileConvertError.validationFailed("Image output alpha semantics changed")
        }
        if let expectedProfile = expectation.requiresEmbeddedColorProfile, hasProfile != expectedProfile {
            throw FileConvertError.validationFailed("Image output color profile policy was not honored")
        }
        guard let dimensions = commonDimensions else { throw FileConvertError.validationFailed("Image output has no dimensions") }
        return ImageValidationResult(
            hash: try TransactionCoordinator.sha256(artifact.url),
            format: actualFormat,
            dimensions: dimensions,
            frameCount: count,
            hasAlpha: anyAlpha,
            hasEmbeddedColorProfile: hasProfile
        )
    }

    public func certificationValidator() -> IndependentValidator {
        IndependentValidator(
            id: Self.id,
            targetExtensions: ["jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "webp"]
        ) { artifact, expected in
            guard case let .image(format) = expected else {
                throw FileConvertError.validationFailed("Native image validator received a non-image expectation")
            }
            let result = try validate(
                artifact,
                expectation: ImageValidationExpectation(format: format, maximumBytes: UInt64.max)
            )
            return (result.hash, .image(result.format))
        }
    }

    private static func format(_ identifier: String) -> ImageFormat? {
        switch identifier {
        case "public.jpeg": .jpeg
        case "public.png": .png
        case "public.heic", "public.heics", "public.heif": .heic
        case "public.tiff": .tiff
        case "org.webmproject.webp": .webP
        default: nil
        }
    }

    private static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly: true
        case .none, .noneSkipFirst, .noneSkipLast: false
        @unknown default: true
        }
    }
}
