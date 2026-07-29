import CoreServices
import Foundation

public enum AuthorizedRootStatus: String, Codable, Sendable {
    case active
    case disabled
    case permissionLost
    case staleBookmark
    case degraded
}

public struct AuthorizedRoot: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let url: URL
    public let volumeUUID: UUID
    public let enabled: Bool
    public let eventCursor: UInt64
    public let status: AuthorizedRootStatus

    public init(id: UUID = UUID(), url: URL, volumeUUID: UUID, enabled: Bool = true, eventCursor: UInt64 = UInt64(kFSEventStreamEventIdSinceNow), status: AuthorizedRootStatus = .active) {
        self.id = id; self.url = url; self.volumeUUID = volumeUUID; self.enabled = enabled; self.eventCursor = eventCursor; self.status = status
    }
}

public enum FileEventSide: String, Codable, Sendable { case old, new, unknown }

public struct FileEvent: Hashable, Sendable {
    public let rootID: UUID
    public let eventID: UInt64
    public let path: URL
    public let fileID: UInt64?
    public let flags: UInt32
    public let side: FileEventSide
    public let observedAt: Date

    public init(rootID: UUID, eventID: UInt64, path: URL, fileID: UInt64?, flags: UInt32, side: FileEventSide, observedAt: Date = Date()) {
        self.rootID = rootID; self.eventID = eventID; self.path = path; self.fileID = fileID
        self.flags = flags; self.side = side; self.observedAt = observedAt
    }

    public var isRename: Bool { flags & UInt32(kFSEventStreamEventFlagItemRenamed) != 0 }
    public var reportsDrop: Bool { flags & UInt32(kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged) != 0 }
    public var isOwnEvent: Bool { flags & UInt32(kFSEventStreamEventFlagOwnEvent) != 0 }
}

public enum FileEventSourceError: Error, Sendable { case streamCreationFailed, streamStartFailed }

public protocol RenameEventSource: Sendable {
    func events(for roots: [AuthorizedRoot]) -> AsyncThrowingStream<FileEvent, Error>
}

public final class FSEventEventSource: RenameEventSource, @unchecked Sendable {
    private let latency: CFTimeInterval
    private let queue: DispatchQueue

    public init(latency: CFTimeInterval = 0.2, queue: DispatchQueue = DispatchQueue(label: "app.fileconvert.fsevents", qos: .utility)) {
        self.latency = latency; self.queue = queue
    }

    public func events(for roots: [AuthorizedRoot]) -> AsyncThrowingStream<FileEvent, Error> {
        let enabled = roots.filter { $0.enabled && $0.status == .active }
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(4096)) { continuation in
            guard !enabled.isEmpty else { continuation.finish(); return }
            let box = FSEventCallbackBox(roots: enabled, continuation: continuation)
            let retained = Unmanaged.passRetained(box)
            var context = FSEventStreamContext(version: 0, info: retained.toOpaque(), retain: nil, release: nil, copyDescription: nil)
            let paths = enabled.map { $0.url.path } as CFArray
            let since = enabled.map(\.eventCursor).min() ?? UInt64(kFSEventStreamEventIdSinceNow)
            let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagUseExtendedData | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagMarkSelf | kFSEventStreamCreateFlagFullHistory)
            guard let stream = FSEventStreamCreate(nil, fileConvertFSEventCallback, &context, paths, since, latency, flags) else {
                retained.release(); continuation.finish(throwing: FileEventSourceError.streamCreationFailed); return
            }
            let session = FSEventSession(stream: stream, retainedBox: retained)
            box.session = session
            FSEventStreamSetDispatchQueue(stream, queue)
            guard FSEventStreamStart(stream) else {
                session.stop(); continuation.finish(throwing: FileEventSourceError.streamStartFailed); return
            }
            continuation.onTermination = { @Sendable _ in session.stop() }
        }
    }
}

private final class FSEventSession: @unchecked Sendable {
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private var retainedBox: Unmanaged<FSEventCallbackBox>?

    init(stream: FSEventStreamRef, retainedBox: Unmanaged<FSEventCallbackBox>) {
        self.stream = stream; self.retainedBox = retainedBox
    }

    func stop() {
        lock.lock()
        guard let stream else { lock.unlock(); return }
        self.stream = nil
        let retained = retainedBox
        retainedBox = nil
        lock.unlock()
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        retained?.release()
    }
}

private final class FSEventCallbackBox: @unchecked Sendable {
    let roots: [AuthorizedRoot]
    let continuation: AsyncThrowingStream<FileEvent, Error>.Continuation
    var session: FSEventSession?

    init(roots: [AuthorizedRoot], continuation: AsyncThrowingStream<FileEvent, Error>.Continuation) {
        self.roots = roots.sorted { $0.url.path.count > $1.url.path.count }
        self.continuation = continuation
    }

    func receive(count: Int, pathsPointer: UnsafeMutableRawPointer, flags: UnsafePointer<FSEventStreamEventFlags>, ids: UnsafePointer<FSEventStreamEventId>) {
        let array = unsafeBitCast(pathsPointer, to: CFArray.self) as NSArray
        for index in 0..<count {
            guard let dictionary = array[index] as? [String: Any], let path = dictionary["path"] as? String else { continue }
            let url = URL(fileURLWithPath: path)
            guard let root = roots.first(where: { Self.matches(url, root: $0.url) }) else { continue }
            guard root.eventCursor == UInt64(kFSEventStreamEventIdSinceNow) || ids[index] > root.eventCursor else { continue }
            let rawFlags = UInt32(flags[index])
            let fileID = (dictionary["fileID"] as? NSNumber)?.uint64Value
            let side: FileEventSide
            if rawFlags & UInt32(kFSEventStreamEventFlagItemRenamed) == 0 { side = .unknown }
            else { side = FileManager.default.fileExists(atPath: path) ? .new : .old }
            let event = FileEvent(rootID: root.id, eventID: ids[index], path: url, fileID: fileID, flags: rawFlags, side: side)
            if case .dropped = continuation.yield(event) {
                continuation.finish(throwing: FileEventSourceError.streamStartFailed)
                session?.stop()
                return
            }
        }
    }

    private static func matches(_ candidate: URL, root: URL) -> Bool {
        let rootComponents = root.standardizedFileURL.pathComponents
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        return candidateComponents.count >= rootComponents.count && candidateComponents.prefix(rootComponents.count).elementsEqual(rootComponents)
    }
}

private let fileConvertFSEventCallback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
    guard let info else { return }
    Unmanaged<FSEventCallbackBox>.fromOpaque(info).takeUnretainedValue().receive(count: count, pathsPointer: paths, flags: flags, ids: ids)
}
