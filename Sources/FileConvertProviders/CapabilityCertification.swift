import FileConvertCore
import Foundation

public struct ValidatorID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct IndependentValidator: Sendable {
    public let id: ValidatorID
    public let targetExtensions: Set<String>
    public let validate: ArtifactValidator

    public init(id: ValidatorID, targetExtensions: Set<String>, validate: @escaping ArtifactValidator) {
        self.id = id
        self.targetExtensions = Set(targetExtensions.map { $0.lowercased() })
        self.validate = validate
    }
}

public struct CapabilityCertification: Hashable, Codable, Sendable {
    public let source: DetectedFormat
    public let targetExtension: String
    public let providerID: ProviderID
    public let validatorID: ValidatorID
    public let fixtureIDs: Set<String>

    public init(source: DetectedFormat, targetExtension: String, providerID: ProviderID, validatorID: ValidatorID, fixtureIDs: Set<String>) {
        self.source = source
        self.targetExtension = targetExtension.lowercased()
        self.providerID = providerID
        self.validatorID = validatorID
        self.fixtureIDs = fixtureIDs
    }
}
