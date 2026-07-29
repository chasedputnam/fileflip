import Darwin
import Foundation

/// Central fail-closed guards for values crossing into file mutation and persistence.
public enum BoundaryGuards {
    public static func canonicalRegularFile(root: URL, relativePath: String) throws -> URL {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.split(separator: "/").contains(where: { $0 == "." || $0 == ".." || $0.isEmpty }) else {
            throw FileConvertError.validationFailed("Invalid root-relative path")
        }
        let canonicalRoot = try canonicalExisting(root)
        let candidate = root.appending(path: relativePath)
        guard isRegularNonLink(candidate) else {
            throw FileConvertError.validationFailed("Target is not a regular file")
        }
        let canonicalCandidate = try canonicalExisting(candidate)
        guard contains(canonicalCandidate, within: canonicalRoot) else {
            throw FileConvertError.validationFailed("Path escapes authorized root")
        }
        return canonicalCandidate
    }

    public static func canonicalRegularFile(root: URL, candidate: URL) throws -> URL {
        guard candidate.isFileURL else { throw FileConvertError.validationFailed("Provider output is not a file URL") }
        let canonicalRoot = try canonicalExisting(root)
        guard isRegularNonLink(candidate) else {
            throw FileConvertError.validationFailed("Provider output is not a regular file")
        }
        let canonicalCandidate = try canonicalExisting(candidate)
        guard contains(canonicalCandidate, within: canonicalRoot) else {
            throw FileConvertError.validationFailed("Provider output escapes job directory")
        }
        return canonicalCandidate
    }

    public static func strictPolicyData(_ policy: ConversionPolicy) throws -> Data {
        let data = try JSONEncoder().encode(policy)
        _ = try decodePolicy(data)
        return data
    }

    public static func decodePolicy(_ data: Data) throws -> ConversionPolicy {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any], root.count == 1,
              let (family, rawFields) = root.first,
              let fields = rawFields as? [String: Any] else {
            throw FileConvertError.validationFailed("Malformed conversion policy")
        }
        let allowed: Set<String>
        switch family {
        case "image": allowed = ["version", "quality", "alphaBackgroundARGB", "frames", "metadata", "orientation", "colorProfile"]
        case "audio": allowed = ["version", "bitrate", "sampleRate", "trackIndex"]
        case "video": allowed = ["version", "quality", "audioTrack", "subtitleTrack"]
        case "document": allowed = ["version", "acceptsFidelityLoss", "pageIndex", "imageQuality"]
        case "spreadsheet": allowed = ["version", "sheetIndex", "delimiter", "formulaValuesOnly"]
        default: throw FileConvertError.validationFailed("Unknown conversion policy family")
        }
        guard Set(fields.keys).isSubset(of: allowed) else {
            throw FileConvertError.validationFailed("Conversion policy contains unknown fields")
        }
        let decoder = JSONDecoder()
        let policy: ConversionPolicy
        do {
            policy = try decoder.decode(ConversionPolicy.self, from: data)
        } catch {
            throw FileConvertError.validationFailed("Malformed conversion policy")
        }
        try validate(policy)
        return policy
    }

    public static func validate(_ policy: ConversionPolicy) throws {
        switch policy {
        case let .image(version, quality, _, frames, _, _, _):
            guard version == 1, quality > 0, quality <= 1 else { throw FileConvertError.validationFailed("Invalid image policy") }
            if case let .index(index) = frames, index < 0 { throw FileConvertError.validationFailed("Invalid image frame policy") }
        case let .audio(version, bitrate, sampleRate, trackIndex):
            guard version == 1, bitrate == nil || bitrate! > 0, sampleRate == nil || sampleRate! > 0, trackIndex == nil || trackIndex! >= 0 else { throw FileConvertError.validationFailed("Invalid audio policy") }
        case let .video(version, quality, audioTrack, subtitleTrack):
            guard version == 1, (0...51).contains(quality), audioTrack == nil || audioTrack! >= 0, subtitleTrack == nil || subtitleTrack! >= 0 else { throw FileConvertError.validationFailed("Invalid video policy") }
        case let .document(version, _, pageIndex, imageQuality):
            guard version == 1, pageIndex == nil || pageIndex! >= 0, imageQuality > 0, imageQuality <= 1 else { throw FileConvertError.validationFailed("Invalid document policy") }
        case let .spreadsheet(version, sheetIndex, delimiter, _):
            guard version == 1, sheetIndex == nil || sheetIndex! >= 0, delimiter.utf8.count == 1 else { throw FileConvertError.validationFailed("Invalid spreadsheet policy") }
        }
    }

    public static func redact(_ value: String, limit: Int = 1024) -> String {
        let withoutPaths = value.replacingOccurrences(of: #"(?:file://)?/[[:graph:]]+"#, with: "<redacted-path>", options: .regularExpression)
        return String(withoutPaths.prefix(limit))
    }

    private static func canonicalExisting(_ url: URL) throws -> URL {
        guard let pointer = realpath(url.path, nil) else { throw FileConvertError.permissionDenied }
        defer { free(pointer) }
        return URL(fileURLWithPath: String(cString: pointer), isDirectory: url.hasDirectoryPath)
    }


    private static func isRegularNonLink(_ url: URL) -> Bool {
        var status = stat()
        return lstat(url.path, &status) == 0 && (status.st_mode & S_IFMT) == S_IFREG
    }
    private static func contains(_ candidate: URL, within root: URL) -> Bool {
        let rootParts = root.standardizedFileURL.pathComponents
        let candidateParts = candidate.standardizedFileURL.pathComponents
        return candidateParts.count > rootParts.count && candidateParts.prefix(rootParts.count).elementsEqual(rootParts)
    }
}

public protocol FileSystemContractProbing: Sendable {
    func verify(directory: URL) throws
}

/// Exercises only private siblings before a transaction mutates a user-visible file.
public struct FileSystemContractProbe: FileSystemContractProbing {
    public init() {}

    public func verify(directory: URL) throws {
        let token = UUID().uuidString
        let staging = directory.appending(path: ".fileconvert-probe-\(token).new")
        let destination = directory.appending(path: ".fileconvert-probe-\(token).old")
        defer {
            try? FileManager.default.removeItem(at: staging)
            try? FileManager.default.removeItem(at: destination)
        }
        guard FileManager.default.createFile(atPath: staging.path, contents: Data("new".utf8), attributes: [.posixPermissions: 0o600]),
              FileManager.default.createFile(atPath: destination.path, contents: Data("old".utf8), attributes: [.posixPermissions: 0o600]) else {
            throw FileConvertError.permissionDenied
        }
        try flush(staging)
        let expectedModificationDate = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([
            .posixPermissions: NSNumber(value: 0o640),
            .modificationDate: expectedModificationDate
        ], ofItemAtPath: staging.path)
        guard rename(staging.path, destination.path) == 0,
              try Data(contentsOf: destination) == Data("new".utf8),
              ((try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777 == 0o640,
              let observedModificationDate = try FileManager.default.attributesOfItem(atPath: destination.path)[.modificationDate] as? Date,
              observedModificationDate == expectedModificationDate else {
            throw FileConvertError.validationFailed("Filesystem does not meet replacement contract")
        }
        try flush(destination)
        try flushDirectory(directory)
    }

    private func flush(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw FileConvertError.permissionDenied }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw FileConvertError.validationFailed("Filesystem cannot flush replacement data") }
    }

    private func flushDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw FileConvertError.permissionDenied }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw FileConvertError.validationFailed("Filesystem cannot flush replacement directory") }
    }
}
