import CoreGraphics
import FileConvertCore
import FileConvertProviders
import Foundation
import ImageIO
import Testing

@Test
func nativeImageCapabilitiesReflectWritableImageIOEncoders() async {
    let capabilities = await NativeImageProvider().capabilities()
    #expect(capabilities.contains { $0.source == .image(.png) && $0.targetExtension == "jpg" })
    #expect(capabilities.contains { $0.source == .image(.jpeg) && $0.targetExtension == "png" })
    #expect(!capabilities.contains { $0.targetExtension == "webp" })
}

@Test
func alphaToJPEGRequiresExplicitBackground() async throws {
    let fixture = try ImageFixture()
    defer { fixture.remove() }
    let request = fixture.request(target: "jpg", policy: .image())
    await #expect(throws: FileConvertError.requiresChoice) {
        try await NativeImageProvider().convert(request)
    }
    let remaining = try FileManager.default.contentsOfDirectory(at: fixture.output, includingPropertiesForKeys: nil)
    #expect(remaining.isEmpty, "Unexpected provider output: \(remaining)")
}

@Test
func imageConversionSupportsSpacesAndUnicodeWhitespaceInFilename() async throws {
    let fixture = try ImageFixture(sourceName: "Screenshot 2026-07-29 at 1.10.54\u{202F}PM.png")
    defer { fixture.remove() }
    let artifact = try await NativeImageProvider().convert(
        fixture.request(target: "jpg", policy: .image(alphaBackgroundARGB: 0xffff_ffff))
    )

    #expect(FileManager.default.fileExists(atPath: artifact.url.path))
    #expect(try Data(contentsOf: artifact.url).isEmpty == false)
}

@Test
func imageConversionNormalizesOrientationFlattensAlphaAndValidatesContent() async throws {
    let fixture = try ImageFixture()
    defer { fixture.remove() }
    let request = fixture.request(
        target: "jpg",
        policy: .image(
            quality: 0.8,
            alphaBackgroundARGB: 0xffff_ffff,
            frames: .requireSingle,
            metadata: .strip,
            orientation: .normalizePixels,
            colorProfile: .convertToSRGB
        )
    )
    let artifact = try await NativeImageProvider().convert(request)
    let result = try NativeImageValidator().validate(
        artifact,
        expectation: ImageValidationExpectation(
            format: .jpeg,
            dimensions: .init(width: 3, height: 2),
            frameCount: 1,
            hasAlpha: false,
            normalizedOrientation: true,
            maximumBytes: request.maximumOutputBytes
        )
    )
    #expect(result.format == .jpeg)
    #expect(result.hash.count == 32)
    #expect(artifact.url.pathExtension == "jpg")
    let source = try #require(CGImageSourceCreateWithURL(artifact.url as CFURL, nil))
    let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(decoded.colorSpace?.name == CGColorSpace.sRGB)
}

@Test
func imageConversionDeletesOutputThatExceedsLimit() async throws {
    let fixture = try ImageFixture()
    defer { fixture.remove() }
    let request = fixture.request(
        target: "png",
        policy: .image(frames: .first),
        maximumOutputBytes: 1
    )
    await #expect(throws: FileConvertError.self) {
        try await NativeImageProvider().convert(request)
    }
    #expect(try FileManager.default.contentsOfDirectory(at: fixture.output, includingPropertiesForKeys: nil).isEmpty)
}

@Test
func imageFramePoliciesRejectAmbiguityAndPreserveAllFramesWhenSupported() async throws {
    let fixture = try ImageFixture(sourceFormat: .tiff, hasAlpha: false, orientation: 1, frameCount: 2)
    defer { fixture.remove() }
    await #expect(throws: FileConvertError.validationFailed("Multi-frame input requires an explicit frame policy")) {
        try await NativeImageProvider().convert(fixture.request(target: "png", policy: .image()))
    }
    let request = fixture.request(target: "tiff", policy: .image(frames: .all))
    let artifact = try await NativeImageProvider().convert(request)
    let result = try NativeImageValidator().validate(
        artifact,
        expectation: ImageValidationExpectation(
            format: .tiff,
            frameCount: 2,
            maximumBytes: request.maximumOutputBytes
        )
    )
    #expect(result.frameCount == 2)
}

@Test
func imageMetadataStripRemovesSourceDescription() async throws {
    let fixture = try ImageFixture(sourceFormat: .tiff, hasAlpha: false, orientation: 6)
    defer { fixture.remove() }
    let artifact = try await NativeImageProvider().convert(
        fixture.request(
            target: "png",
            policy: .image(metadata: .strip, orientation: .normalizePixels, colorProfile: .strip)
        )
    )
    let source = try #require(CGImageSourceCreateWithURL(artifact.url as CFURL, nil))
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    let tiff = properties?[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
    #expect(tiff?[kCGImagePropertyTIFFImageDescription] == nil)
    #expect((properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1 == 1)
}

@Test
func imageValidatorRejectsExtensionOnlyMasquerade() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let output = directory.appending(path: "fake.png")
    try Data("not an image".utf8).write(to: output)
    let artifact = ProducedArtifact(url: output, providerID: ProviderID(rawValue: "fixture"))
    #expect(throws: FileConvertError.self) {
        try NativeImageValidator().validate(
            artifact,
            expectation: ImageValidationExpectation(format: .png, maximumBytes: 1024)
        )
    }
}

@Test
func everyNativeImagePairHasCertifiedFixtureAndPassesIndependentValidation() async throws {
    let provider = NativeImageProvider()
    let validator = NativeImageValidator()
    let capabilities = await provider.capabilities()
    let registry = ProviderRegistry()
    await registry.register(provider)
    await registry.register(validator.certificationValidator())
    for capability in capabilities {
        guard case let .image(sourceFormat) = capability.source else {
            Issue.record("Native image provider advertised a non-image source")
            continue
        }
        await registry.certify(
            CapabilityCertification(
                source: capability.source,
                targetExtension: capability.targetExtension,
                providerID: provider.id,
                validatorID: NativeImageValidator.id,
                fixtureIDs: ["self-generated-\(sourceFormat.rawValue)-to-\(capability.targetExtension)"]
            )
        )
    }
    #expect(await registry.capabilities() == capabilities)

    let ordered = capabilities.sorted {
        String(describing: $0.source) + $0.targetExtension < String(describing: $1.source) + $1.targetExtension
    }
    for capability in ordered {
        guard case let .image(sourceFormat) = capability.source else { continue }
        let fixture = try ImageFixture(sourceFormat: sourceFormat, hasAlpha: false, orientation: 1)
        defer { fixture.remove() }
        #expect(try await ContentDetector().detect(fixture.source) == capability.source)
        let request = fixture.request(
            target: capability.targetExtension,
            policy: .image(
                quality: 0.8,
                alphaBackgroundARGB: 0xffff_ffff,
                metadata: .strip,
                orientation: .normalizePixels,
                colorProfile: .convertToSRGB
            )
        )
        let artifact = try await provider.convert(request)
        let expectedFormat = try #require(ImageFixture.format(for: capability.targetExtension))
        let result = try validator.validate(
            artifact,
            expectation: ImageValidationExpectation(
                format: expectedFormat,
                dimensions: .init(width: 2, height: 3),
                frameCount: 1,
                normalizedOrientation: true,
                maximumBytes: request.maximumOutputBytes
            )
        )
        #expect(result.format == expectedFormat)
    }
}

@Test
func selfGeneratedWebPFixtureIsImmutableAndRecognized() async throws {
    let fixture = ImageFixture.webPFixture
    #expect(try TransactionCoordinator.sha256(fixture).map { String(format: "%02x", $0) }.joined() == "f1d5e1077912309e87b420db0575cacc912867751143c0ab122690ca64fc20c9")
    #expect(try await ContentDetector().detect(fixture) == .image(.webP))
}

private struct ImageFixture {
    let directory: URL
    let source: URL
    let output: URL

    init(
        sourceFormat: ImageFormat = .png,
        hasAlpha: Bool = true,
        orientation: Int = 6,
        frameCount: Int = 1,
        sourceName: String? = nil
    ) throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        source = directory.appending(path: sourceName ?? "source.\(sourceFormat.rawValue.lowercased())")
        output = directory.appending(path: "output", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        if sourceFormat == .webP {
            try FileManager.default.copyItem(at: Self.webPFixture, to: source)
        } else {
            try Self.writeImage(to: source, format: sourceFormat, hasAlpha: hasAlpha, orientation: orientation, frameCount: frameCount)
        }
    }
    static var webPFixture: URL {
        let bundle = Bundle(for: ImageFixtureBundleMarker.self)
        return bundle.url(
            forResource: "self-generated-2x3",
            withExtension: "webp",
            subdirectory: "Fixtures/Images"
        ) ?? bundle.url(forResource: "self-generated-2x3", withExtension: "webp")
            ?? URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .appending(path: "Fixtures/Images/self-generated-2x3.webp")
    }

    static func format(for targetExtension: String) -> ImageFormat? {
        switch targetExtension {
        case "jpg", "jpeg": .jpeg
        case "png": .png
        case "heic", "heif": .heic
        case "tif", "tiff": .tiff
        case "webp": .webP
        default: nil
        }
    }

    func request(
        target: String,
        policy: ConversionPolicy,
        maximumOutputBytes: UInt64 = 1_000_000
    ) -> ConversionRequest {
        ConversionRequest(
            jobID: UUID(),
            source: Snapshot(
                url: source,
                fileKey: FileKey(volumeUUID: UUID(), fileID: 1),
                byteCount: UInt64((try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0),
                modificationDate: Date()
            ),
            targetExtension: target,
            policy: policy,
            outputDirectory: output,
            deadline: Date().addingTimeInterval(10),
            maximumOutputBytes: maximumOutputBytes
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    private static func writeImage(
        to url: URL,
        format: ImageFormat,
        hasAlpha: Bool = true,
        orientation: Int = 6,
        frameCount: Int = 1
    ) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: 2,
            height: 3,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: hasAlpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw FixtureError.creationFailed }
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: hasAlpha ? 0.5 : 1)
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 3))
        let type: String
        switch format {
        case .jpeg: type = "public.jpeg"
        case .png: type = "public.png"
        case .heic: type = "public.heic"
        case .tiff: type = "public.tiff"
        case .webP: throw FixtureError.creationFailed
        }
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, frameCount, nil) else {
            throw FixtureError.creationFailed
        }
        let properties = [
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFImageDescription: "fixture metadata"],
        ] as CFDictionary
        for _ in 0 ..< frameCount {
            CGImageDestinationAddImage(destination, image, properties)
        }
        guard CGImageDestinationFinalize(destination) else { throw FixtureError.creationFailed }
    }

    private enum FixtureError: Error { case creationFailed }
}

private final class ImageFixtureBundleMarker {}
