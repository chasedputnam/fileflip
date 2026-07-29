import FileConvertCore
import FileConvertProviders
import Testing

private actor HealthChangingProvider: ConversionProvider {
    nonisolated let id = ProviderID(rawValue: "health-changing")
    private var currentHealth: ProviderHealth = .available(version: "1")
    private let published: Set<ConversionCapability>

    init(capability: ConversionCapability) { published = [capability] }
    func health() async -> ProviderHealth { currentHealth }
    func capabilities() async -> Set<ConversionCapability> { published }
    func convert(_ request: ConversionRequest) async throws -> ProducedArtifact {
        throw FileConvertError.providerUnavailable("provider health lost")
    }
    func failHealth() { currentHealth = .unavailable(reason: "self-test failed") }
}

private struct StableBoundaryProvider: ConversionProvider {
    let id = ProviderID(rawValue: "stable-boundary")
    let capability: ConversionCapability
    func health() async -> ProviderHealth { .available(version: "1") }
    func capabilities() async -> Set<ConversionCapability> { [capability] }
    func convert(_ request: ConversionRequest) async throws -> ProducedArtifact {
        throw FileConvertError.validationFailed("conversion is outside this registry test")
    }
}

@Test
func providerHealthLossWithdrawsOnlyAffectedCertifiedPair() async throws {
    let registry = ProviderRegistry()
    let target = ConversionCapability(source: .document(.markdown), targetExtension: "html", providerID: ProviderID(rawValue: "health-changing"), defaultPolicy: .document(acceptsFidelityLoss: true), lossProfile: .potentiallyLossy)
    let provider = HealthChangingProvider(capability: target)
    let unaffected = ConversionCapability(source: .document(.html), targetExtension: "md", providerID: ProviderID(rawValue: "stable-boundary"), defaultPolicy: .document(acceptsFidelityLoss: true), lossProfile: .potentiallyLossy)
    let unaffectedProvider = StableBoundaryProvider(capability: unaffected)
    let htmlValidator = HTMLValidator().certificationValidator()
    let markdownValidator = MarkdownValidator().certificationValidator()
    await registry.register(htmlValidator)
    await registry.register(markdownValidator)
    await registry.register(provider)
    await registry.register(unaffectedProvider)
    await registry.certify(CapabilityCertification(source: target.source, targetExtension: target.targetExtension, providerID: target.providerID, validatorID: htmlValidator.id, fixtureIDs: ["markdown-html"]))
    await registry.certify(CapabilityCertification(source: unaffected.source, targetExtension: unaffected.targetExtension, providerID: unaffected.providerID, validatorID: markdownValidator.id, fixtureIDs: ["html-markdown"]))
    #expect(await registry.capability(source: target.source, targetExtension: target.targetExtension) == target)

    await provider.failHealth()
    #expect(await registry.capability(source: target.source, targetExtension: target.targetExtension) == nil)
    #expect(await registry.capability(source: unaffected.source, targetExtension: unaffected.targetExtension) == unaffected)
}
