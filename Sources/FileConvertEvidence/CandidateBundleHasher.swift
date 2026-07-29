import CryptoKit
import Foundation

public enum EvidenceError: Error, Equatable, Sendable {
    case invalidCandidate(String)
    case invalidRouteSet(String)
    case invalidReport(String)
}

public enum CandidateBundleHasher {
    private static let keys: Set<URLResourceKey> = [
        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
    ]

    private enum Entry {
        case file(path: String, url: URL, size: Int, executableMode: Int)
        case symbolicLink(path: String, destination: String)

        var path: String {
            switch self {
            case let .file(path, _, _, _), let .symbolicLink(path, _): path
            }
        }
    }

    public static func sha256(of rootURL: URL) throws -> String {
        let root = rootURL.standardizedFileURL
        let rootValues = try root.resourceValues(forKeys: keys)
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw EvidenceError.invalidCandidate("Candidate root must be a non-symlink directory")
        }
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw EvidenceError.invalidCandidate("Candidate cannot be enumerated")
        }

        var entries: [Entry] = []
        var regularFileCount = 0
        for case let entry as URL in enumerator {
            let url = entry.standardizedFileURL
            guard contains(url, in: root) else {
                throw EvidenceError.invalidCandidate("Candidate entry escapes its root")
            }
            let path = relativePath(url, root: root)
            let values = try url.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true {
                let destination = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
                let destinationURL = destination.hasPrefix("/")
                    ? URL(filePath: destination)
                    : url.deletingLastPathComponent().appending(path: destination)
                let resolved = destinationURL.standardizedFileURL.resolvingSymlinksInPath()
                guard contains(resolved, in: root), FileManager.default.fileExists(atPath: resolved.path) else {
                    throw EvidenceError.invalidCandidate("Candidate symlink is broken or escapes its root: \(path)")
                }
                entries.append(.symbolicLink(path: path, destination: destination))
                continue
            }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true, let size = values.fileSize, size >= 0 else {
                throw EvidenceError.invalidCandidate("Candidate contains a non-regular entry: \(path)")
            }
            let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int ?? 0
            entries.append(.file(path: path, url: url, size: size, executableMode: permissions & 0o111))
            regularFileCount += 1
        }
        if let enumerationError {
            throw EvidenceError.invalidCandidate("Candidate enumeration failed: \(enumerationError.localizedDescription)")
        }
        guard regularFileCount > 0 else { throw EvidenceError.invalidCandidate("Candidate contains no regular files") }
        entries.sort { Array($0.path.utf8).lexicographicallyPrecedes(Array($1.path.utf8)) }

        var candidateDigest = SHA256()
        for entry in entries {
            let record: String
            switch entry {
            case let .file(path, url, size, executableMode):
                record = "F\0\(path)\0\(String(executableMode, radix: 8))\0\(size)\0\(try fileSHA256(url))\n"
            case let .symbolicLink(path, destination):
                record = "L\0\(path)\0\(destination)\n"
            }
            candidateDigest.update(data: Data(record.utf8))
        }
        return candidateDigest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func fileSHA256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 1_024 * 1_024), !data.isEmpty {
            digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func contains(_ candidate: URL, in root: URL) -> Bool {
        let rootComponents = root.pathComponents
        let candidateComponents = candidate.pathComponents
        return candidateComponents.count > rootComponents.count
            && candidateComponents.prefix(rootComponents.count).elementsEqual(rootComponents)
    }

    private static func relativePath(_ url: URL, root: URL) -> String {
        url.pathComponents.dropFirst(root.pathComponents.count).joined(separator: "/")
    }
}
