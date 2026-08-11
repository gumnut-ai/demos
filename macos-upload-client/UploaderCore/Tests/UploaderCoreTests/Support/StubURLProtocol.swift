import Foundation

/// URLProtocol stub for exercising GumnutClient without a network.
///
/// Handler state is stored per *subclass*, so each serialized test suite uses
/// its own subclass (`ClientTestStub`, `EngineTestStub`) and suites can run in
/// parallel with each other without sharing handlers.
class StubURLProtocol: URLProtocol {
    struct Response {
        let status: Int
        var headers: [String: String] = [:]
        var body: Data = Data()

        static func json(_ status: Int, _ jsonString: String) -> Response {
            Response(
                status: status,
                headers: ["Content-Type": "application/json"],
                body: Data(jsonString.utf8)
            )
        }
    }

    typealias Handler = @Sendable (URLRequest, Data?) -> Response

    private static let stateLock = NSLock()
    nonisolated(unsafe) private static var handlers: [ObjectIdentifier: Handler] = [:]
    nonisolated(unsafe) private static var lastRequests: [ObjectIdentifier: URLRequest] = [:]
    nonisolated(unsafe) private static var lastBodies: [ObjectIdentifier: Data] = [:]

    class var handler: Handler? {
        get { stateLock.withLock { handlers[ObjectIdentifier(self)] } }
        set { stateLock.withLock { handlers[ObjectIdentifier(self)] = newValue } }
    }

    class var lastRequest: URLRequest? {
        stateLock.withLock { lastRequests[ObjectIdentifier(self)] }
    }

    class var lastBody: Data? {
        stateLock.withLock { lastBodies[ObjectIdentifier(self)] }
    }

    class func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [self]
        return URLSession(configuration: config)
    }

    class func reset() {
        stateLock.withLock {
            handlers[ObjectIdentifier(self)] = nil
            lastRequests[ObjectIdentifier(self)] = nil
            lastBodies[ObjectIdentifier(self)] = nil
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let key = ObjectIdentifier(type(of: self))
        let body = Self.drainBody(of: request)
        let handler = Self.stateLock.withLock {
            Self.lastRequests[key] = request
            Self.lastBodies[key] = body
            return Self.handlers[key]
        }

        guard let handler else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.unsupportedURL, userInfo: ["reason": "no stub handler"])
            )
            return
        }
        let response = handler(request, body)
        let httpResponse = HTTPURLResponse(
            url: request.url!,
            statusCode: response.status,
            httpVersion: "HTTP/1.1",
            headerFields: response.headers
        )!
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// Upload bodies arrive as a stream, not httpBody.
    private static func drainBody(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 65536
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: bufferSize)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// Dedicated stub for GumnutClientTests.
final class ClientTestStub: StubURLProtocol {}

/// Dedicated stub for SyncEngineTests.
final class EngineTestStub: StubURLProtocol {}
