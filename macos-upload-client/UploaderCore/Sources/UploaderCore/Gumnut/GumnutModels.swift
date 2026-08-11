import Foundation

public struct GumnutUser: Decodable, Equatable, Sendable {
    public let id: String
    public let email: String?
}

public struct GumnutLibrary: Decodable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let assetCount: Int?
}

/// Lightweight asset shape returned by the bulk existence check.
public struct GumnutAssetLite: Decodable, Equatable, Sendable {
    public let id: String
    /// Base64-encoded SHA-256 of the asset's original bytes.
    public let checksum: String
    public let checksumSha1: String?
    public let deviceAssetId: String?
    public let deviceId: String?
}

public struct GumnutFileData: Decodable, Equatable, Sendable {
    /// Base64-encoded SHA-256; compare against the local digest to verify an
    /// upload end-to-end.
    public let checksum: String?
    public let checksumSha1: String?
    public let fileSizeBytes: Int64?
}

public struct GumnutAsset: Decodable, Equatable, Sendable {
    public let id: String
    public let mimeType: String?
    public let originalFileName: String?
    public let fileData: GumnutFileData?
}

public enum UploadOutcome: Equatable, Sendable {
    /// 201 — the server stored a new asset.
    case created
    /// 200 — identical bytes already existed; the returned asset is the
    /// pre-existing one. Uploads are idempotent, so this is success.
    case alreadyExisted
}

public enum GumnutClientError: Error, Equatable {
    case unauthorized(statusCode: Int, message: String?)
    /// An edge firewall (WAF) answered with an HTML block page instead of the
    /// API — triggered by request content, not credentials. Per-file, not
    /// fatal: other files upload fine.
    case edgeBlocked(statusCode: Int, requestId: String?)
    /// 4xx that will not succeed on retry (422 unsupported format, etc.).
    case invalidRequest(statusCode: Int, message: String?)
    case rateLimited(retryAfter: TimeInterval?)
    /// 507 — the account's storage quota is exhausted; stop the run.
    case storageQuotaExceeded(message: String?)
    /// 502/503/504 — retryable per the API contract; honor retryAfter.
    case transientServer(statusCode: Int, retryAfter: TimeInterval?, message: String?)
    case server(statusCode: Int, message: String?)
    case invalidResponse(String)
    case tooManyChecksums(count: Int, max: Int)
    /// The staged upload body's file bytes hash differently than the caller's
    /// expected digest — the file changed between analysis and staging. The
    /// body was never sent.
    case stagedFileChanged
}
