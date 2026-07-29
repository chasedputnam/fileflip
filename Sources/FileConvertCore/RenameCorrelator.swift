import Darwin
import Foundation

public struct RenameCandidate: Hashable, Sendable {
    public let eventID: UInt64
    public let rootID: UUID
    public let fileKey: FileKey
    public let oldRelativePath: String
    public let newRelativePath: String
    public let observedAt: Date

    public init(eventID: UInt64, rootID: UUID, fileKey: FileKey, oldRelativePath: String, newRelativePath: String, observedAt: Date) {
        self.eventID = eventID; self.rootID = rootID; self.fileKey = fileKey
        self.oldRelativePath = oldRelativePath; self.newRelativePath = newRelativePath; self.observedAt = observedAt
    }
}

public enum RenameSignal: Sendable, Equatable {
    case candidate(RenameCandidate)
    case streamDegraded(rootID: UUID, cursor: UInt64)
}

public actor RenameCorrelator {
    private struct Key: Hashable { let rootID: UUID; let eventID: UInt64; let fileID: UInt64 }
    private struct Pending { var old: FileEvent?; var new: FileEvent?; let firstObserved: Date }

    private var roots: [UUID: AuthorizedRoot]
    private var pending: [Key: Pending] = [:]
    private var emitted: [Key: Date] = [:]
    private var identityPaths: [UUID: [UInt64: URL]] = [:]
    private let maximumPending: Int
    private let maximumAge: TimeInterval

    public init(roots: [AuthorizedRoot], maximumPending: Int = 4096, maximumAge: TimeInterval = 10) {
        self.roots = Dictionary(uniqueKeysWithValues: roots.map { ($0.id, $0) })
        self.maximumPending = maximumPending; self.maximumAge = maximumAge
        self.identityPaths = Dictionary(uniqueKeysWithValues: roots.filter(\.enabled).map { ($0.id, Self.scan($0.url)) })
    }

    public func replaceRoots(_ roots: [AuthorizedRoot]) {
        self.roots = Dictionary(uniqueKeysWithValues: roots.map { ($0.id, $0) })
        pending = pending.filter { self.roots[$0.key.rootID]?.enabled == true }
        emitted = emitted.filter { self.roots[$0.key.rootID]?.enabled == true }
        identityPaths = Dictionary(uniqueKeysWithValues: roots.filter(\.enabled).map { ($0.id, Self.scan($0.url)) })
    }


    public func ingest(_ event: FileEvent) -> [RenameSignal] {
        expire(before: event.observedAt.addingTimeInterval(-maximumAge))
        guard let root = roots[event.rootID], root.enabled else { return [] }
        if event.reportsDrop {
            pending = pending.filter { $0.key.rootID != event.rootID }
            identityPaths[event.rootID] = Self.scan(root.url)
            return [.streamDegraded(rootID: event.rootID, cursor: event.eventID)]
        }
        guard !event.isOwnEvent, let fileID = event.fileID else { return [] }
        if !event.isRename {
            if FileManager.default.fileExists(atPath: event.path.path) { identityPaths[event.rootID, default: [:]][fileID] = event.path }
            else { identityPaths[event.rootID]?[fileID] = nil }
            return []
        }
        guard event.side != .unknown else { return [] }
        let key = Key(rootID: event.rootID, eventID: event.eventID, fileID: fileID)
        guard emitted[key] == nil else { return [] }
        var pair = pending[key] ?? Pending(firstObserved: event.observedAt)
        switch event.side {
        case .old:
            pair.old = event
            identityPaths[event.rootID, default: [:]][fileID] = event.path
        case .new:
            pair.new = event
            if let prior = identityPaths[event.rootID]?[fileID], prior.standardizedFileURL != event.path.standardizedFileURL {
                pair.old = FileEvent(rootID: event.rootID, eventID: event.eventID, path: prior, fileID: fileID, flags: event.flags, side: .old, observedAt: event.observedAt)
            }
            identityPaths[event.rootID, default: [:]][fileID] = event.path
        case .unknown:
            return []
        }
        pending[key] = pair
        enforceBound()
        guard let old = pair.old, let new = pair.new, let candidate = validate(old: old, new: new, root: root) else { return [] }
        pending.removeValue(forKey: key)
        emitted[key] = event.observedAt
        enforceBound()
        identityPaths[event.rootID, default: [:]][fileID] = new.path
        return [.candidate(candidate)]
    }

    private func validate(old: FileEvent, new: FileEvent, root: AuthorizedRoot) -> RenameCandidate? {
        let oldName = old.path.deletingPathExtension().lastPathComponent
        let newName = new.path.deletingPathExtension().lastPathComponent
        let oldExtension = old.path.pathExtension.lowercased()
        let newExtension = new.path.pathExtension.lowercased()
        guard oldName == newName, !oldExtension.isEmpty, !newExtension.isEmpty, oldExtension != newExtension else { return nil }
        guard let oldRelative = relative(old.path, to: root.url), let newRelative = relative(new.path, to: root.url) else { return nil }
        guard isEligibleCurrentFile(new.path) else { return nil }
        return RenameCandidate(eventID: new.eventID, rootID: root.id, fileKey: FileKey(volumeUUID: root.volumeUUID, fileID: new.fileID!), oldRelativePath: oldRelative, newRelativePath: newRelative, observedAt: max(old.observedAt, new.observedAt))
    }

    private func relative(_ candidate: URL, to root: URL) -> String? {
        guard let rootComponents = Self.canonicalComponents(root),
              let candidateComponents = Self.canonicalComponents(candidate),
              candidateComponents.count > rootComponents.count,
              candidateComponents.prefix(rootComponents.count).elementsEqual(rootComponents) else { return nil }
        return candidateComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }

    private static func canonicalComponents(_ url: URL) -> [String]? {
        let exists = FileManager.default.fileExists(atPath: url.path)
        let resolvable = exists ? url : url.deletingLastPathComponent()
        guard let resolved = realpath(resolvable.path, nil) else { return nil }
        defer { free(resolved) }
        var canonical = URL(fileURLWithPath: String(cString: resolved))
        if !exists { canonical.append(path: url.lastPathComponent) }
        return canonical.pathComponents
    }

    private func isEligibleCurrentFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        guard !name.hasPrefix("."), !name.hasPrefix("~$"), !name.hasSuffix("~"), !name.hasSuffix(".tmp"), !name.contains(".fileconvert-") else { return false }
        var status = stat()
        guard lstat(url.path, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else { return false }
        let values = try? url.resourceValues(forKeys: [.isPackageKey, .isSymbolicLinkKey, .isRegularFileKey])
        return values?.isRegularFile == true && values?.isSymbolicLink != true && values?.isPackage != true
    }

    private static func scan(_ root: URL) -> [UInt64: URL] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsPackageDescendants]) else { return [:] }
        var result: [UInt64: URL] = [:]
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]), values.isRegularFile == true, values.isSymbolicLink != true,
                  let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let fileID = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value else { continue }
            result[fileID] = url
        }
        return result
    }

    private func expire(before date: Date) {
        pending = pending.filter { $0.value.firstObserved >= date }
        emitted = emitted.filter { $0.value >= date }
    }

    private func enforceBound() {
        if pending.count > maximumPending {
            for key in pending.sorted(by: { $0.value.firstObserved < $1.value.firstObserved }).prefix(pending.count - maximumPending).map(\.key) { pending.removeValue(forKey: key) }
        }
        if emitted.count > maximumPending {
            for key in emitted.sorted(by: { $0.value < $1.value }).prefix(emitted.count - maximumPending).map(\.key) { emitted.removeValue(forKey: key) }
        }
    }
}

public struct StableRename: Sendable {
    public let candidate: RenameCandidate
    public let url: URL
    public let sourceHash: Data

    public init(candidate: RenameCandidate, url: URL, sourceHash: Data) {
        self.candidate = candidate
        self.url = url
        self.sourceHash = sourceHash
    }
}

public enum RenameStabilityGate {
    public static func evaluate(_ candidate: RenameCandidate, roots: [UUID: AuthorizedRoot], interval: Duration = .milliseconds(500), timeout: Duration = .seconds(30)) async throws -> StableRename {
        guard let root = roots[candidate.rootID], root.enabled else { throw FileConvertError.permissionDenied }
        var url = locate(fileID: candidate.fileKey.fileID, below: root.url) ?? root.url.appending(path: candidate.newRelativePath)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var previous = try FileFacts.read(url)
        while clock.now < deadline {
            try await clock.sleep(for: interval)
            let latest = locate(fileID: candidate.fileKey.fileID, below: root.url) ?? url
            let current = try FileFacts.read(latest)
            if latest.standardizedFileURL == url.standardizedFileURL, current == previous {
                let hash = try TransactionCoordinator.sha256(latest)
                return StableRename(candidate: candidate, url: latest, sourceHash: hash)
            }
            url = latest
            previous = current
        }
        throw FileConvertError.timedOut
    }

    private static func locate(fileID: UInt64, below root: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        for case let url as URL in enumerator {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path), (attributes[.systemFileNumber] as? NSNumber)?.uint64Value == fileID else { continue }
            return url
        }
        return nil
    }
}
