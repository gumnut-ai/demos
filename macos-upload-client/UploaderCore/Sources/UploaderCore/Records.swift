import Foundation
import GRDB

/// A user-selected top-level folder.
public struct Root: Codable, Identifiable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "roots"

    public var id: Int64?
    /// Stable identifier used to derive `device_asset_id`s; survives path edits.
    public var uuid: String
    /// Standardized absolute path, no trailing slash. For display and overlap checks.
    public var path: String
    /// Security-scoped bookmark; nil when running unsandboxed (tests, CLI).
    public var bookmark: Data?
    /// Whether this root participates in the next scan.
    public var included: Bool
    public var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, uuid, path, bookmark, included
        case createdAt = "created_at"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// One row per discovered media/RAW file under a root.
public struct FileRecord: Codable, Identifiable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "files"

    public var id: Int64?
    public var rootId: Int64
    /// POSIX-style path relative to the root, "/"-separated.
    public var relPath: String
    /// Directory portion of `relPath` ("" at root level); enables tree aggregation in SQL.
    public var parentDir: String
    public var fileName: String
    public var size: Int64
    /// Modification time as epoch seconds. Compared exactly against fresh stats:
    /// same (size, mtime) means the cached sha256 is still valid.
    public var mtime: Double
    /// SHA-256 of the file contents (32 bytes), or nil when (re)hashing is needed.
    public var sha256: Data?
    public var hashedAt: Date?
    public var status: FileStatus
    /// Server asset ID once matched or uploaded. Only meaningful for the
    /// server + library it was recorded against (see Store.updateServerConfiguration).
    public var assetId: String?
    public var syncedAt: Date?
    public var errorMessage: String?
    public var lastSeenScanId: Int64?

    enum CodingKeys: String, CodingKey {
        case id
        case rootId = "root_id"
        case relPath = "rel_path"
        case parentDir = "parent_dir"
        case fileName = "file_name"
        case size, mtime, sha256, status
        case hashedAt = "hashed_at"
        case assetId = "asset_id"
        case syncedAt = "synced_at"
        case errorMessage = "error_message"
        case lastSeenScanId = "last_seen_scan_id"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// A persisted user choice to exclude a file or directory subtree.
public struct Exclusion: Codable, Identifiable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "exclusions"

    public enum Kind: String, Codable, Sendable {
        case directory = "dir"
        case file
    }

    public var id: Int64?
    public var rootId: Int64
    public var kind: Kind
    public var relPath: String
    public var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, kind
        case rootId = "root_id"
        case relPath = "rel_path"
        case createdAt = "created_at"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    /// Whether this exclusion covers the given relative path.
    public func covers(relPath candidate: String) -> Bool {
        switch kind {
        case .file:
            return candidate == relPath
        case .directory:
            return candidate == relPath || candidate.hasPrefix(relPath + "/")
        }
    }
}

/// One row per sync run.
public struct RunRecord: Codable, Identifiable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "runs"

    public var id: Int64?
    public var startedAt: Date
    public var finishedAt: Date?
    public var outcome: RunOutcome
    /// JSON array of participating root IDs.
    public var rootIdsJSON: String
    /// JSON-encoded RunCounters.
    public var countersJSON: String

    enum CodingKeys: String, CodingKey {
        case id, outcome
        case startedAt = "started_at"
        case finishedAt = "finished_at"
        case rootIdsJSON = "root_ids_json"
        case countersJSON = "counters_json"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public var rootIds: [Int64] {
        (try? JSONDecoder().decode([Int64].self, from: Data(rootIdsJSON.utf8))) ?? []
    }

    public var counters: RunCounters {
        (try? JSONDecoder().decode(RunCounters.self, from: Data(countersJSON.utf8))) ?? RunCounters()
    }
}
