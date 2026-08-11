import Foundation
import UniformTypeIdentifiers

/// Hand-rolled client for the Gumnut Photos API.
///
/// Deliberately additive-only: the endpoints below (validate key, list
/// libraries, bulk existence check, upload) are the client's entire surface.
/// Trash, delete, and update endpoints are not implemented, so no code path
/// in this app can call them.
public struct GumnutClient: Sendable {
    /// Server-enforced ceiling on checksums per existence-check request.
    public static let maxExistenceCheckItems = 5000

    public let baseURL: URL
    private let apiKey: String
    private let session: URLSession

    /// Multi-megabyte uploads stall over HTTP/3 on some server edges and
    /// networks (small requests succeed, large bodies time out), and the
    /// shared session auto-upgrades to h3 once an Alt-Svc header teaches it.
    /// There is no public switch to disable h3 — but an ephemeral
    /// configuration has no Alt-Svc cache and stays on HTTP/2.
    public static let defaultSession = URLSession(configuration: .ephemeral)

    public init(
        baseURL: URL = URL(string: Store.defaultServerURL)!,
        apiKey: String,
        session: URLSession = GumnutClient.defaultSession
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
    }

    // MARK: - Endpoints

    /// Validates the API key ("Test connection").
    public func currentUser() async throws -> GumnutUser {
        let request = makeRequest(path: "/api/users/me", method: "GET")
        return try await send(request)
    }

    public func libraries() async throws -> [GumnutLibrary] {
        let request = makeRequest(path: "/api/libraries", method: "GET")
        return try await send(request)
    }

    /// Asks which of the given SHA-256 digests already exist in the library.
    /// Returns only the matches; absent digests need uploading.
    public func checkExistence(
        sha256Digests: [Data],
        libraryId: String? = nil
    ) async throws -> [GumnutAssetLite] {
        guard sha256Digests.count <= Self.maxExistenceCheckItems else {
            throw GumnutClientError.tooManyChecksums(
                count: sha256Digests.count, max: Self.maxExistenceCheckItems
            )
        }
        var body: [String: Any] = [
            "checksums": sha256Digests.map { $0.base64EncodedString() }
        ]
        if let libraryId {
            body["library_id"] = libraryId
        }
        var request = makeRequest(path: "/api/assets/exist", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        struct ExistenceResponse: Decodable {
            let assets: [GumnutAssetLite]
        }
        let response: ExistenceResponse = try await send(request)
        return response.assets
    }

    /// Uploads one file. `200 .alreadyExisted` (identical bytes already in the
    /// library) is as much a success as `201 .created`. `onProgress` reports
    /// (bytesSent, bytesTotal) of the encoded body, from URLSession's queue.
    public func uploadAsset(
        fileURL: URL,
        fileName: String? = nil,
        deviceAssetId: String,
        deviceId: String,
        fileCreatedAt: Date,
        fileModifiedAt: Date,
        libraryId: String? = nil,
        onProgress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async throws -> (outcome: UploadOutcome, asset: GumnutAsset) {
        let name = fileName ?? fileURL.lastPathComponent

        var form = MultipartFormData()
        form.addField(name: "device_asset_id", value: deviceAssetId)
        form.addField(name: "device_id", value: deviceId)
        form.addField(name: "file_created_at", value: fileCreatedAt.formatted(Self.iso8601))
        form.addField(name: "file_modified_at", value: fileModifiedAt.formatted(Self.iso8601))
        if let libraryId {
            form.addField(name: "library_id", value: libraryId)
        }
        form.addFile(
            name: "asset_data",
            fileName: name,
            contentType: Self.mimeType(forFileName: name),
            fileURL: fileURL
        )

        // Stage the encoded body in the app's temporary directory (inside the
        // sandbox container). Removed after the request; user files are never
        // written or deleted.
        let bodyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-body-\(UUID().uuidString)")
        try form.writeEncoded(to: bodyURL)
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        var request = makeRequest(path: "/api/assets", method: "POST")
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")

        let (data, urlResponse) = try await session.upload(
            for: request, fromFile: bodyURL,
            delegate: onProgress.map { UploadProgressReporter(onProgress: $0) }
        )
        guard let http = urlResponse as? HTTPURLResponse else {
            throw GumnutClientError.invalidResponse("non-HTTP response")
        }
        switch http.statusCode {
        case 201:
            return (.created, try Self.decode(GumnutAsset.self, from: data))
        case 200:
            return (.alreadyExisted, try Self.decode(GumnutAsset.self, from: data))
        default:
            throw Self.error(from: http, data: data)
        }
    }

    // MARK: - Request plumbing

    private func makeRequest(path: String, method: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, urlResponse) = try await session.data(for: request)
        guard let http = urlResponse as? HTTPURLResponse else {
            throw GumnutClientError.invalidResponse("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.error(from: http, data: data)
        }
        return try Self.decode(T.self, from: data)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw GumnutClientError.invalidResponse("decoding failed: \(error)")
        }
    }

    private static func error(from response: HTTPURLResponse, data: Data) -> GumnutClientError {
        let message = errorMessage(from: data)
        let retryAfter = (response.value(forHTTPHeaderField: "Retry-After"))
            .flatMap(TimeInterval.init)
        switch response.statusCode {
        case 401, 403:
            // The hosting edge's WAF answers with an HTML block page; the API
            // itself always answers JSON. Telling them apart matters — a WAF
            // block is about the file's bytes, not the credentials.
            if Self.isHTMLBlockPage(data) {
                return .edgeBlocked(
                    statusCode: response.statusCode,
                    requestId: Self.blockPageRequestId(data)
                )
            }
            return .unauthorized(statusCode: response.statusCode, message: message)
        case 400..<500 where response.statusCode != 429:
            return .invalidRequest(statusCode: response.statusCode, message: message)
        case 429:
            return .rateLimited(retryAfter: retryAfter)
        case 507:
            return .storageQuotaExceeded(message: message)
        case 502, 503, 504:
            return .transientServer(
                statusCode: response.statusCode, retryAfter: retryAfter, message: message
            )
        default:
            return .server(statusCode: response.statusCode, message: message)
        }
    }

    /// Extracts a human-readable message from an API error body
    /// (`{"detail": ...}` as a string or validation array, or `error_code`).
    static func errorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return data.isEmpty ? nil : String(data: data, encoding: .utf8)
        }
        if let detail = object["detail"] as? String {
            return detail
        }
        if let details = object["detail"] as? [[String: Any]] {
            let messages = details.compactMap { $0["msg"] as? String }
            if !messages.isEmpty {
                return messages.joined(separator: "; ")
            }
        }
        if let message = object["message"] as? String {
            return message
        }
        if let code = object["error_code"] as? String {
            return code
        }
        return nil
    }

    /// True when an error body is an HTML page rather than API JSON.
    static func isHTMLBlockPage(_ data: Data) -> Bool {
        guard let prefix = String(data: data.prefix(512), encoding: .utf8) else { return false }
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.hasPrefix("<!doctype") || trimmed.hasPrefix("<html")
    }

    /// Pulls the support reference (e.g. "Request ID: abc123") off a block page.
    static func blockPageRequestId(_ data: Data) -> String? {
        guard let html = String(data: data, encoding: .utf8),
            let match = html.firstMatch(of: /Request ID:\s*([A-Za-z0-9-]+)/)
        else { return nil }
        return String(match.1)
    }

    static func mimeType(forFileName name: String) -> String {
        let ext = (name as NSString).pathExtension
        return UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
    }

    private static let iso8601 = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
}

/// Per-task delegate surfacing upload byte counts. URLSession calls it on its
/// own queue; safe because the only state is an immutable Sendable closure.
private final class UploadProgressReporter: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Int64, Int64) -> Void

    init(onProgress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        didSendBodyData bytesSent: Int64, totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        onProgress(totalBytesSent, totalBytesExpectedToSend)
    }
}
