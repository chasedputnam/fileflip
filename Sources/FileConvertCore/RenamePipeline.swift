import Foundation

public struct RenameDeduplicationKey: Hashable, Sendable {
    public let volumeUUID: UUID
    public let fileID: UInt64
    public let requestedExtension: String
    public let sourceHash: Data
}

public protocol EventCursorStore: Sendable {
    func persistEventCursor(rootID: UUID, eventID: UInt64) async throws
}

extension JournalStore: EventCursorStore {}

public actor RenamePipeline {
    public enum Status: Sendable { case stopped, monitoring, paused, degraded }

    private var roots: [UUID: AuthorizedRoot]
    private let correlator: RenameCorrelator
    private let handler: @Sendable (StableRename) async -> Void
    private let cursorStore: (any EventCursorStore)?
    private let maximumConcurrency: Int
    private var monitorTask: Task<Void, Never>?
    private var pending: [FileKey: RenameCandidate] = [:]
    private var pendingOrder: [FileKey] = []
    private var activeWorkers = 0
    private var completed: Set<RenameDeduplicationKey> = []
    public private(set) var status: Status = .stopped
    public private(set) var latestCursors: [UUID: UInt64] = [:]

    public init(roots: [AuthorizedRoot], maximumConcurrency: Int = 2, cursorStore: (any EventCursorStore)? = nil, handler: @escaping @Sendable (StableRename) async -> Void) {
        self.roots = Dictionary(uniqueKeysWithValues: roots.map { ($0.id, $0) })
        self.correlator = RenameCorrelator(roots: roots)
        self.maximumConcurrency = min(2, max(1, maximumConcurrency))
        self.cursorStore = cursorStore
        self.handler = handler
    }

    public func start(source: any RenameEventSource) async {
        guard monitorTask == nil else { return }
        let activeRoots = roots.values.filter { $0.enabled && $0.status == .active }.map { root in
            AuthorizedRoot(id: root.id, url: root.url, volumeUUID: root.volumeUUID, enabled: true, eventCursor: latestCursors[root.id] ?? root.eventCursor, status: .active)
        }
        await correlator.replaceRoots(activeRoots)
        status = .monitoring
        monitorTask = Task { [weak self] in
            do {
                for try await event in source.events(for: activeRoots) {
                    guard !Task.isCancelled else { break }
                    await self?.receive(event)
                }
            } catch {
                await self?.sourceFailed()
            }
        }
    }

    public func pause() {
        guard status != .paused else { return }
        status = .paused
        monitorTask?.cancel()
        monitorTask = nil
        pending.removeAll()
        pendingOrder.removeAll()
    }

    public func resume(source: any RenameEventSource) async {
        guard status == .paused || status == .degraded || status == .stopped else { return }
        await start(source: source)
    }

    public func stop() {
        monitorTask?.cancel()
        monitorTask = nil
        pending.removeAll()
        pendingOrder.removeAll()
        status = .stopped
    }

    public func replaceRoots(_ newRoots: [AuthorizedRoot], source: (any RenameEventSource)? = nil) async {
        let activeIDs = Set(newRoots.filter { $0.enabled && $0.status == .active }.map(\.id))
        roots = Dictionary(uniqueKeysWithValues: newRoots.map { ($0.id, $0) })
        pending = pending.filter { activeIDs.contains($0.value.rootID) }
        pendingOrder.removeAll { pending[$0] == nil }
        await correlator.replaceRoots(newRoots)
        if monitorTask != nil {
            monitorTask?.cancel(); monitorTask = nil
            if let source { await start(source: source) }
        }
    }

    private func receive(_ event: FileEvent) async {
        guard status == .monitoring else { return }
        let cursor = max(latestCursors[event.rootID] ?? 0, event.eventID)
        do {
            try await cursorStore?.persistEventCursor(rootID: event.rootID, eventID: cursor)
        } catch {
            status = .degraded
            pending.removeAll(); pendingOrder.removeAll()
            return
        }
        latestCursors[event.rootID] = cursor
        for signal in await correlator.ingest(event) {
            switch signal {
            case .streamDegraded:
                status = .degraded
                pending.removeAll(); pendingOrder.removeAll()
            case let .candidate(candidate):
                if pending[candidate.fileKey] == nil { pendingOrder.append(candidate.fileKey) }
                pending[candidate.fileKey] = candidate
            }
        }
        launchWorkers()
    }

    private func launchWorkers() {
        while status == .monitoring, activeWorkers < maximumConcurrency, let fileKey = pendingOrder.first {
            pendingOrder.removeFirst()
            guard let candidate = pending.removeValue(forKey: fileKey) else { continue }
            activeWorkers += 1
            Task { [weak self] in
                await self?.process(candidate)
            }
        }
    }

    private func process(_ candidate: RenameCandidate) async {
        defer { activeWorkers -= 1; launchWorkers() }
        guard let stable = try? await RenameStabilityGate.evaluate(candidate, roots: roots) else { return }
        await submit(stable)
    }

    public func reserve(_ stable: StableRename) -> Bool {
        completed.insert(Self.deduplicationKey(for: stable)).inserted
    }

    public func reserveRetry(_ stable: StableRename) {
        completed.insert(Self.deduplicationKey(for: stable))
    }

    private static func deduplicationKey(for stable: StableRename) -> RenameDeduplicationKey {
        RenameDeduplicationKey(
            volumeUUID: stable.candidate.fileKey.volumeUUID,
            fileID: stable.candidate.fileKey.fileID,
            requestedExtension: stable.url.pathExtension.lowercased(),
            sourceHash: stable.sourceHash
        )
    }

    public func submit(_ stable: StableRename) async {
        guard reserve(stable) else { return }
        await handler(stable)
    }

    private func sourceFailed() {
        monitorTask = nil
        if status == .monitoring { status = .degraded }
    }
}
