import Foundation

/// A deterministic URL-loading tripwire: it records and rejects requests before any socket is opened.
final class NetworkDenyHarness: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var attemptedURLs: [URL] = []

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NetworkDenyHarness.self]
        return URLSession(configuration: configuration)
    }

    static func reset() {
        lock.lock()
        attemptedURLs.removeAll()
        lock.unlock()
    }

    static func attempts() -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        return attemptedURLs
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url else { return false }
        return url.scheme == "http" || url.scheme == "https"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let url = request.url {
            Self.lock.lock()
            Self.attemptedURLs.append(url)
            Self.lock.unlock()
        }
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}
