import FileConvertEvidence
import FileConvertProviders
import Foundation

private struct ExportedFormat: Encodable {
    let canonicalExtension: String
    let aliases: [String]
}

private struct ExportedFamily: Encodable {
    let formats: [ExportedFormat]
    let directedNonIdentityRoutes: Int
}

private struct ExportedContract: Encodable {
    let schemaVersion: Int
    let contractVersion: Int
    let providerID: String
    let routeSetSHA256: String
    let totalFormats: Int
    let totalRoutes: Int
    let audio: ExportedFamily
    let video: ExportedFamily
}

@main
struct PackagedMediaContractCommand {
    static func main() throws {
        let capabilities = InstalledMediaContract.declaredCapabilities()
        let audioFormats = formats(for: .audio)
        let videoFormats = formats(for: .video)
        let contract = ExportedContract(
            schemaVersion: 1,
            contractVersion: InstalledMediaContract.version,
            providerID: InstalledMediaContract.providerID.rawValue,
            routeSetSHA256: try RouteSetIdentity.sha256(capabilities),
            totalFormats: InstalledMediaContract.formats.count,
            totalRoutes: capabilities.count,
            audio: ExportedFamily(
                formats: audioFormats,
                directedNonIdentityRoutes: audioFormats.count * (audioFormats.count - 1)
            ),
            video: ExportedFamily(
                formats: videoFormats,
                directedNonIdentityRoutes: videoFormats.count * (videoFormats.count - 1)
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(contract)
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }

    private static func formats(for family: InstalledMediaFormat.Family) -> [ExportedFormat] {
        InstalledMediaContract.formats
            .filter { $0.family == family }
            .map {
                ExportedFormat(
                    canonicalExtension: $0.canonicalExtension,
                    aliases: $0.aliases.sorted()
                )
            }
    }
}
