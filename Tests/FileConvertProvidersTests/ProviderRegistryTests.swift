import FileConvertCore
import FileConvertProviders
import Foundation
import Testing

private struct HealthyProvider: ConversionProvider {
    let id = ProviderID(rawValue: "test")
    func health() async -> ProviderHealth { .available(version: "1") }
    func capabilities() async -> Set<ConversionCapability> {
        [ConversionCapability(source: .image(.png), targetExtension: "jpg", providerID: id, defaultPolicy: .image(), lossProfile: .potentiallyLossy)]
    }
    func convert(_ request: ConversionRequest) async throws -> ProducedArtifact {
        ProducedArtifact(url: request.outputDirectory.appending(path: "output.jpg"), providerID: id)
    }
}

private struct ConfigurableProvider: ConversionProvider {
    let id: ProviderID
    let providerHealth: ProviderHealth
    let published: Set<ConversionCapability>
    func health() async -> ProviderHealth { providerHealth }
    func capabilities() async -> Set<ConversionCapability> { published }
    func convert(_ request: ConversionRequest) async throws -> ProducedArtifact {
        ProducedArtifact(url: request.outputDirectory.appending(path: "output"), providerID: id)
    }
}

private let validator = IndependentValidator(id: ValidatorID(rawValue: "image-validator"), targetExtensions: ["jpg"]) { produced, expected in
    (Data([1]), expected)
}

@Test
func healthyProviderPublishesOnlyACompleteCertifiedContract() async throws {
    let registry = ProviderRegistry()
    await registry.register(HealthyProvider())
    await registry.register(validator)
    await registry.certify(CapabilityCertification(source: .image(.png), targetExtension: "jpg", providerID: ProviderID(rawValue: "test"), validatorID: validator.id, fixtureIDs: ["png-to-jpeg"]))
    let fixture = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let input = directory.appending(path: "fixture.bin")
    try fixture.write(to: input)
    #expect(try await ContentDetector().detect(input) == .image(.png))
    guard let capability = await registry.capability(source: .image(.png), targetExtension: ".JPG") else {
        Issue.record("Certified capability was not advertised")
        return
    }
    #expect(await registry.capabilities().count == 1)
    #expect(await registry.provider(for: capability) != nil)
    #expect(await registry.validator(for: capability)?.id == validator.id)
    #expect(await registry.certification(for: capability)?.fixtureIDs == ["png-to-jpeg"])
    #expect(capability.defaultPolicy.version == 1)
    let produced = ProducedArtifact(url: directory.appending(path: "validated.jpg"), providerID: capability.providerID)
    let validation = try await #require(await registry.validator(for: capability)).validate(produced, .image(.jpeg))
    #expect(validation.format == .image(.jpeg))
}

@Test
func uncertifiedAmbiguousAndFailedProviderPairsAreNotAdvertised() async {
    let registry = ProviderRegistry()
    let first = HealthyProvider()
    await registry.register(first)
    #expect(await registry.capabilities().isEmpty)

    await registry.register(validator)
    await registry.certify(CapabilityCertification(source: .image(.png), targetExtension: "jpg", providerID: first.id, validatorID: validator.id, fixtureIDs: ["fixture"]))
    #expect(await registry.capabilities().count == 1)

    let failedID = ProviderID(rawValue: "failed")
    let failedCapability = ConversionCapability(source: .image(.tiff), targetExtension: "jpg", providerID: failedID, defaultPolicy: .image(), lossProfile: .potentiallyLossy)
    await registry.register(ConfigurableProvider(id: failedID, providerHealth: .unavailable(reason: "self-test failed"), published: [failedCapability]))
    await registry.certify(CapabilityCertification(source: .image(.tiff), targetExtension: "jpg", providerID: failedID, validatorID: validator.id, fixtureIDs: ["fixture"]))
    #expect(await registry.capabilities().count == 1)

    let duplicateID = ProviderID(rawValue: "duplicate")
    let duplicate = ConversionCapability(source: .image(.png), targetExtension: "jpg", providerID: duplicateID, defaultPolicy: .image(), lossProfile: .potentiallyLossy)
    await registry.register(ConfigurableProvider(id: duplicateID, providerHealth: .available(version: "1"), published: [duplicate]))
    await registry.certify(CapabilityCertification(source: .image(.png), targetExtension: "jpg", providerID: duplicateID, validatorID: validator.id, fixtureIDs: ["fixture"]))
    #expect(await registry.capabilities().isEmpty)
}
