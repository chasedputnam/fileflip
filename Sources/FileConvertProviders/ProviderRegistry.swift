import FileConvertCore
import Foundation

private struct CapabilityKey: Hashable {
    let source: DetectedFormat
    let targetExtension: String
}

private struct CertificationKey: Hashable {
    let capability: CapabilityKey
    let providerID: ProviderID
}

public actor ProviderRegistry {
    private var providers: [ProviderID: any ConversionProvider] = [:]
    private var validators: [ValidatorID: IndependentValidator] = [:]
    private var certifications: [CertificationKey: CapabilityCertification] = [:]

    public init() {}

    public func register(_ provider: any ConversionProvider) async {
        guard case .available = await provider.health() else {
            providers.removeValue(forKey: provider.id)
            return
        }
        providers[provider.id] = provider
    }

    public func remove(_ id: ProviderID) {
        providers.removeValue(forKey: id)
    }

    public func register(_ validator: IndependentValidator) {
        validators[validator.id] = validator
    }

    public func certify(_ certification: CapabilityCertification) {
        let key = CapabilityKey(source: certification.source, targetExtension: certification.targetExtension)
        certifications[CertificationKey(capability: key, providerID: certification.providerID)] = certification
    }

    public func capabilities() async -> Set<ConversionCapability> {
        var grouped: [CapabilityKey: [ConversionCapability]] = [:]
        for provider in providers.values {
            guard case let .available(version) = await provider.health(), !version.isEmpty else { continue }
            for capability in await provider.capabilities() where capability.providerID == provider.id && capability.defaultPolicy.version > 0 {
                let target = capability.targetExtension.lowercased()
                guard Self.isSafeExtension(target) else { continue }
                let key = CapabilityKey(source: capability.source, targetExtension: target)
                let certificationKey = CertificationKey(capability: key, providerID: provider.id)
                guard let certification = certifications[certificationKey],
                      !certification.fixtureIDs.isEmpty,
                      certification.validatorID.rawValue != provider.id.rawValue,
                      let validator = validators[certification.validatorID],
                      validator.targetExtensions.contains(target) else { continue }
                grouped[key, default: []].append(capability)
            }
        }
        return Set(grouped.values.compactMap { values in
            guard values.count == 1 else { return nil }
            return values[0]
        })
    }

    public func capability(source: DetectedFormat, targetExtension: String) async -> ConversionCapability? {
        let normalized = targetExtension.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return await capabilities().first { $0.source == source && $0.targetExtension == normalized }
    }

    public func provider(for capability: ConversionCapability) async -> (any ConversionProvider)? {
        guard await self.capability(source: capability.source, targetExtension: capability.targetExtension) == capability else { return nil }
        return providers[capability.providerID]
    }


    public func validator(for capability: ConversionCapability) async -> IndependentValidator? {
        guard await self.capability(source: capability.source, targetExtension: capability.targetExtension) == capability else { return nil }
        let key = CapabilityKey(source: capability.source, targetExtension: capability.targetExtension)
        guard let certification = certifications[CertificationKey(capability: key, providerID: capability.providerID)] else { return nil }
        return validators[certification.validatorID]
    }

    public func certification(for capability: ConversionCapability) async -> CapabilityCertification? {
        guard await self.capability(source: capability.source, targetExtension: capability.targetExtension) == capability else { return nil }
        let key = CapabilityKey(source: capability.source, targetExtension: capability.targetExtension)
        return certifications[CertificationKey(capability: key, providerID: capability.providerID)]
    }
    private static func isSafeExtension(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 16 && value.unicodeScalars.allSatisfy {
            CharacterSet.lowercaseLetters.contains($0) || CharacterSet.decimalDigits.contains($0)
        }
    }
}
