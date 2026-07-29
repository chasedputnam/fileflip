import CryptoKit
import FileConvertCore
import FileConvertProviders
import Foundation

public enum RouteSetIdentity {
    public static func normalizedRoutes(_ capabilities: Set<ConversionCapability>) throws -> [String] {
        var routes: [String] = []
        routes.reserveCapacity(capabilities.count)
        for capability in capabilities {
            guard capability.providerID == InstalledMediaContract.providerID,
                  let source = InstalledMediaContract.installedFormat(for: capability.source),
                  let target = InstalledMediaContract.installedFormat(forExtension: capability.targetExtension),
                  capability.targetExtension == target.canonicalExtension,
                  source.family == target.family,
                  source.format != target.format else {
                throw EvidenceError.invalidRouteSet("Route is not an installed canonical non-identity media route")
            }
            routes.append("\(source.family.rawValue):\(source.canonicalExtension)->\(target.canonicalExtension)\n")
        }
        routes.sort { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
        guard Set(routes).count == routes.count else {
            throw EvidenceError.invalidRouteSet("Route set contains a duplicate normalized route")
        }
        return routes
    }

    public static func sha256(_ capabilities: Set<ConversionCapability>) throws -> String {
        var digest = SHA256()
        for route in try normalizedRoutes(capabilities) {
            digest.update(data: Data(route.utf8))
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
