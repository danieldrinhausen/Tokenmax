import Foundation

/// A per-test scripted network. Unlike `StubURLProtocol`, whose statics are
/// shared by every suite that touches it, each session here carries its own id
/// in a header and looks its script up by that id, so tests that run in
/// parallel cannot see each other's responses or request counts.
final class ScriptedURLProtocol: URLProtocol, @unchecked Sendable {
    enum Reply {
        case http(status: Int, headers: [String: String] = [:], body: String = "{}")
        case failure(URLError.Code)
    }

    final class Script: @unchecked Sendable {
        private let lock = NSLock()
        private var replies: [Reply]
        private var sent = 0
        init(_ replies: [Reply]) { self.replies = replies }

        var requestCount: Int { lock.withLock { sent } }

        /// The last reply repeats, so a test only lists what changes.
        func next() -> Reply {
            lock.withLock {
                let reply = replies[min(sent, replies.count - 1)]
                sent += 1
                return reply
            }
        }
    }

    private static let idHeader = "X-Stub-Script"
    nonisolated(unsafe) private static var scripts: [String: Script] = [:]
    private static let registry = NSLock()

    static func session(_ replies: [Reply]) -> (URLSession, Script) {
        let script = Script(replies)
        let id = UUID().uuidString
        registry.withLock { scripts[id] = script }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScriptedURLProtocol.self]
        configuration.httpAdditionalHeaders = [idHeader: id]
        return (URLSession(configuration: configuration), script)
    }

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let script = request.value(forHTTPHeaderField: Self.idHeader)
            .flatMap { id in Self.registry.withLock { Self.scripts[id] } }
        guard let script else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        switch script.next() {
        case let .failure(code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case let .http(status, headers, body):
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
