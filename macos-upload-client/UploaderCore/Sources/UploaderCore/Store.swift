import Foundation
import GRDB

public enum StoreError: Error, Equatable {
    /// The new root equals, contains, or is contained by an existing root.
    case overlappingRoot(existingPath: String)
    case recordNotFound
}

/// Embedded SQLite state store. Everything here is a rebuildable cache except
/// the root list and exclusions, which are user-authored.
public final class Store: Sendable {
    public static let defaultServerURL = "https://api.gumnut.ai"

    enum SettingsKey {
        static let serverURL = "server_url"
        static let libraryId = "library_id"
        static let deviceId = "device_id"
        static let lastAnalysisRunId = "last_analysis_run_id"
        static let hashConcurrency = "hash_concurrency"
        static let uploadConcurrency = "upload_concurrency"
    }

    private let writer: any DatabaseWriter

    /// On-disk store (WAL mode, concurrent reads).
    public static func onDisk(at path: String) throws -> Store {
        try Store(writer: DatabasePool(path: path))
    }

    /// In-memory store for tests.
    public static func inMemory() throws -> Store {
        try Store(writer: DatabaseQueue())
    }

    private init(writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "roots") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("uuid", .text).notNull()
                t.column("path", .text).notNull().unique()
                t.column("bookmark", .blob)
                t.column("included", .boolean).notNull().defaults(to: true)
                t.column("created_at", .datetime).notNull()
            }
            try db.create(table: "files") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("root_id", .integer).notNull()
                    .references("roots", onDelete: .cascade)
                t.column("rel_path", .text).notNull()
                t.column("parent_dir", .text).notNull()
                t.column("file_name", .text).notNull()
                t.column("size", .integer).notNull()
                t.column("mtime", .double).notNull()
                t.column("sha256", .blob)
                t.column("hashed_at", .datetime)
                t.column("status", .text).notNull()
                t.column("asset_id", .text)
                t.column("synced_at", .datetime)
                t.column("error_message", .text)
                t.column("last_seen_scan_id", .integer)
                t.uniqueKey(["root_id", "rel_path"])
            }
            try db.create(index: "ix_files_sha256", on: "files", columns: ["sha256"])
            try db.create(index: "ix_files_root_status", on: "files", columns: ["root_id", "status"])
            try db.create(index: "ix_files_root_parent", on: "files", columns: ["root_id", "parent_dir"])
            try db.create(table: "exclusions") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("root_id", .integer).notNull()
                    .references("roots", onDelete: .cascade)
                t.column("kind", .text).notNull()
                t.column("rel_path", .text).notNull()
                t.column("created_at", .datetime).notNull()
                t.uniqueKey(["root_id", "kind", "rel_path"])
            }
            try db.create(table: "runs") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("started_at", .datetime).notNull()
                t.column("finished_at", .datetime)
                t.column("outcome", .text).notNull()
                t.column("root_ids_json", .text).notNull()
                t.column("counters_json", .text).notNull()
            }
            try db.create(table: "settings") { t in
                t.column("key", .text).primaryKey()
                t.column("value", .text).notNull()
            }
        }
        migrator.registerMigration("v2-folder-order-index") { db in
            // Back the folder-then-file-name upload ordering. The index's
            // implicit trailing rowid makes its key order exactly
            // (root_id, parent_dir, file_name, id) — the keyset-pagination
            // sort in hashedPendingFiles — so paging is a range scan rather
            // than a full re-sort per batch. Supersedes ix_files_root_parent,
            // which it covers as a prefix.
            try db.execute(sql: "DROP INDEX IF EXISTS ix_files_root_parent")
            try db.create(
                index: "ix_files_root_parent_name", on: "files",
                columns: ["root_id", "parent_dir", "file_name"]
            )
        }
        return migrator
    }

    // MARK: - Roots

    /// Adds a root after normalizing and canonicalizing the path (symlinks
    /// resolved, so an aliased spelling of an existing root cannot slip past
    /// the check) and rejecting overlap with existing roots, so no file can
    /// ever be tracked under two identities.
    @discardableResult
    public func addRoot(path rawPath: String, bookmark: Data? = nil) throws -> Root {
        let path = FileReader.canonicalPath(of: Self.normalize(path: rawPath))
        return try writer.write { db in
            let existingPaths = try String.fetchAll(db, sql: "SELECT path FROM roots")
            for existing in existingPaths {
                if path == existing
                    || path.hasPrefix(existing + "/")
                    || existing.hasPrefix(path + "/")
                {
                    throw StoreError.overlappingRoot(existingPath: existing)
                }
            }
            var root = Root(
                id: nil,
                uuid: UUID().uuidString,
                path: path,
                bookmark: bookmark,
                included: true,
                createdAt: Date()
            )
            try root.insert(db)
            return root
        }
    }

    public func allRoots() throws -> [Root] {
        try writer.read { db in
            try Root.order(Column("path")).fetchAll(db)
        }
    }

    /// Updates a root's stored path after its security-scoped bookmark
    /// resolved somewhere else (folder moved or renamed, volume remounted).
    /// File rows are unaffected — rel_paths stay anchored to the root. The
    /// same overlap rule as `addRoot` applies; a collision with another
    /// root's path leaves the row unchanged and returns false.
    @discardableResult
    public func updateRootPath(_ rootId: Int64, path rawPath: String) throws -> Bool {
        let path = FileReader.canonicalPath(of: Self.normalize(path: rawPath))
        return try writer.write { db in
            let current = try String.fetchOne(
                db, sql: "SELECT path FROM roots WHERE id = ?", arguments: [rootId]
            )
            guard current != path else { return true }
            let others = try String.fetchAll(
                db, sql: "SELECT path FROM roots WHERE id <> ?", arguments: [rootId]
            )
            for other in others {
                if path == other
                    || path.hasPrefix(other + "/")
                    || other.hasPrefix(path + "/")
                {
                    return false
                }
            }
            try db.execute(
                sql: "UPDATE roots SET path = ? WHERE id = ?",
                arguments: [path, rootId]
            )
            return true
        }
    }

    /// Refreshes a root's security-scoped bookmark (e.g. after staleness).
    public func updateRootBookmark(_ rootId: Int64, bookmark: Data) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE roots SET bookmark = ? WHERE id = ?",
                arguments: [bookmark, rootId]
            )
        }
    }

    public func setRootIncluded(_ rootId: Int64, included: Bool) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE roots SET included = ? WHERE id = ?",
                arguments: [included, rootId]
            )
        }
    }

    /// Removes the root and (via cascade) its file rows and exclusions.
    /// Database rows only — never touches the filesystem.
    public func removeRoot(_ rootId: Int64) throws {
        _ = try writer.write { db in
            try Root.deleteOne(db, key: rootId)
        }
    }

    private static func normalize(path: String) -> String {
        var path = (path as NSString).standardizingPath
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    // MARK: - Scan results

    /// One file's scan result, for batch recording.
    public struct ScannedFileInput: Sendable {
        public let relPath: String
        public let size: Int64
        public let mtime: Double
        public let classification: MediaClassification
        public let excluded: Bool

        public init(
            relPath: String, size: Int64, mtime: Double,
            classification: MediaClassification, excluded: Bool
        ) {
            self.relPath = relPath
            self.size = size
            self.mtime = mtime
            self.classification = classification
            self.excluded = excluded
        }
    }

    /// Records one stat'ed file. Hash-cache semantics:
    /// - new file: starts in its classification's initial status, unhashed
    /// - same (size, mtime): cached sha256 and sync state are kept
    /// - changed (size, mtime): sha256 and sync state are reset for re-hashing
    /// - `excluded` overrides status while set, without discarding the cache
    /// - a previously errored file returns to `pending` for a fresh attempt
    @discardableResult
    public func recordScannedFile(
        rootId: Int64,
        relPath: String,
        size: Int64,
        mtime: Double,
        classification: MediaClassification,
        excluded: Bool,
        scanId: Int64?
    ) throws -> FileRecord {
        try writer.write { db in
            try Self.upsertScannedFile(
                db,
                rootId: rootId,
                input: ScannedFileInput(
                    relPath: relPath, size: size, mtime: mtime,
                    classification: classification, excluded: excluded
                ),
                scanId: scanId
            )
        }
    }

    /// Batch variant: one transaction for a whole scan buffer, which is what
    /// keeps scans of very large trees fast.
    public func recordScannedFiles(
        rootId: Int64, files: [ScannedFileInput], scanId: Int64?
    ) throws {
        guard !files.isEmpty else { return }
        try writer.write { db in
            for input in files {
                _ = try Self.upsertScannedFile(db, rootId: rootId, input: input, scanId: scanId)
            }
        }
    }

    private static func upsertScannedFile(
        _ db: Database, rootId: Int64, input: ScannedFileInput, scanId: Int64?
    ) throws -> FileRecord {
        let parentDir = Self.parentDirectory(of: input.relPath)
        let fileName = String(input.relPath.split(separator: "/").last ?? Substring(input.relPath))

        guard
            var record = try FileRecord
                .filter(Column("root_id") == rootId && Column("rel_path") == input.relPath)
                .fetchOne(db)
        else {
            var record = FileRecord(
                id: nil,
                rootId: rootId,
                relPath: input.relPath,
                parentDir: parentDir,
                fileName: fileName,
                size: input.size,
                mtime: input.mtime,
                sha256: nil,
                hashedAt: nil,
                status: input.excluded ? .excluded : input.classification.initialStatus,
                assetId: nil,
                syncedAt: nil,
                errorMessage: nil,
                lastSeenScanId: scanId
            )
            try record.insert(db)
            return record
        }

        let contentUnchanged = record.size == input.size && record.mtime == input.mtime
        record.size = input.size
        record.mtime = input.mtime
        record.lastSeenScanId = scanId

        if !contentUnchanged {
            record.sha256 = nil
            record.hashedAt = nil
            record.assetId = nil
            record.syncedAt = nil
            record.errorMessage = nil
            record.status = input.excluded ? .excluded : input.classification.initialStatus
        } else if input.excluded {
            record.status = .excluded
        } else {
            switch record.status {
            case .excluded:
                // Un-excluded: resume from what the cache still knows.
                record.status =
                    record.assetId != nil ? .synced : input.classification.initialStatus
            case .error:
                record.status = .pending
                record.errorMessage = nil
            default:
                break
            }
        }
        try record.update(db)
        return record
    }

    static func parentDirectory(of relPath: String) -> String {
        guard let idx = relPath.lastIndex(of: "/") else { return "" }
        return String(relPath[relPath.startIndex..<idx])
    }

    /// Stamps existing rows as seen by the given scan without touching their
    /// cached state — for files the scan visited but deliberately did not
    /// re-record (mid-copy deferrals), so `pruneVanishedFiles` never deletes
    /// a file that is still on disk.
    public func markSeen(rootId: Int64, relPaths: [String], scanId: Int64) throws {
        guard !relPaths.isEmpty else { return }
        try writer.write { db in
            // Chunked to stay under SQLite's bound-parameter limit.
            var index = 0
            while index < relPaths.count {
                let chunk = Array(relPaths[index..<min(index + 500, relPaths.count)])
                index += chunk.count
                let placeholders = repeatElement("?", count: chunk.count)
                    .joined(separator: ", ")
                try db.execute(
                    sql: """
                        UPDATE files SET last_seen_scan_id = ?
                        WHERE root_id = ? AND rel_path IN (\(placeholders))
                        """,
                    arguments: Self.statementArguments([scanId, rootId], chunk)
                )
            }
        }
    }

    /// Deletes rows a completed, failure-free scan of `rootId` did not see —
    /// those files are gone from disk (deleted, moved, or renamed). Callers
    /// must not pass roots that were skipped or partially enumerated: an
    /// unreachable or unreadable tree is not a deletion (unreachable ≠
    /// deleted).
    @discardableResult
    public func pruneVanishedFiles(rootId: Int64, scanId: Int64) throws -> Int {
        try writer.write { db in
            try db.execute(
                sql: """
                    DELETE FROM files
                    WHERE root_id = ? AND (last_seen_scan_id IS NULL OR last_seen_scan_id <> ?)
                    """,
                arguments: [rootId, scanId]
            )
            return db.changesCount
        }
    }

    // MARK: - Hashing

    public func filesNeedingHash(rootIds: [Int64]? = nil, limit: Int = 500) throws -> [FileRecord] {
        try writer.read { db in
            try Self.scoped(Self.needsHashRequest, to: rootIds)
                .order(Column("id"))
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Remaining hash work, for progress totals.
    public func pendingHashTotals(rootIds: [Int64]? = nil) throws -> (files: Int, bytes: Int64) {
        try writer.read { db in
            let request = Self.scoped(Self.needsHashRequest, to: rootIds)
            let files = try request.fetchCount(db)
            let bytes = try request.select(sum(Column("size")), as: Int64.self).fetchOne(db) ?? 0
            return (files, bytes)
        }
    }

    private static let needsHashRequest = FileRecord
        .filter(Column("status") == FileStatus.pending.rawValue && Column("sha256") == nil)

    private static let hashedPendingRequest = FileRecord
        .filter(Column("status") == FileStatus.pending.rawValue && Column("sha256") != nil)

    private static func scoped(
        _ request: QueryInterfaceRequest<FileRecord>, to rootIds: [Int64]?
    ) -> QueryInterfaceRequest<FileRecord> {
        guard let rootIds else { return request }
        return request.filter(rootIds.contains(Column("root_id")))
    }

    /// Drops a row's cached hash and destination state so the next analysis
    /// re-hashes it — for a file whose bytes changed while its (size, mtime)
    /// stayed identical, which the stat-keyed hash cache cannot detect.
    public func invalidateCachedHash(_ fileId: Int64) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                    UPDATE files SET sha256 = NULL, hashed_at = NULL,
                        asset_id = NULL, synced_at = NULL, status = ?, error_message = NULL
                    WHERE id = ?
                    """,
                arguments: [FileStatus.pending.rawValue, fileId]
            )
        }
    }

    public func markHashed(_ fileId: Int64, sha256: Data) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE files SET sha256 = ?, hashed_at = ? WHERE id = ?",
                arguments: [sha256, Date(), fileId]
            )
        }
    }

    // MARK: - Sync state

    /// A keyset-pagination cursor over `hashedPendingFiles`, matching its
    /// sort order (root, folder, file name). `id` is the unique tiebreaker
    /// that keeps the order total so paging never repeats or skips a row.
    public struct PendingCursor: Sendable, Equatable {
        let rootId: Int64
        let parentDir: String
        let fileName: String
        let id: Int64

        public init(_ file: FileRecord) {
            rootId = file.rootId
            parentDir = file.parentDir
            fileName = file.fileName
            id = file.id!
        }
    }

    /// Hashed files awaiting an existence check or upload, ordered by folder
    /// then file name (grouped per root) so uploads proceed in a predictable
    /// alphabetical order rather than filesystem-enumeration order. Page with
    /// `after`: the keyset cursor advances strictly, so files that stay
    /// pending are not re-returned within one pass and loops always terminate.
    /// The order is index-backed (`ix_files_root_parent_name`), keeping the
    /// full paging sweep linear over large libraries.
    public func hashedPendingFiles(
        rootIds: [Int64]? = nil, after cursor: PendingCursor? = nil, limit: Int = 5000
    ) throws -> [FileRecord] {
        try writer.read { db in
            var request = Self.scoped(Self.hashedPendingRequest, to: rootIds)
            if let cursor {
                // Row-value keyset comparison over the full sort key.
                request = request.filter(
                    sql: "(root_id, parent_dir, file_name, id) > (?, ?, ?, ?)",
                    arguments: [cursor.rootId, cursor.parentDir, cursor.fileName, cursor.id]
                )
            }
            return try request
                .order(
                    Column("root_id"), Column("parent_dir"),
                    Column("file_name"), Column("id")
                )
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Pending upload work (hashed, still pending), for plan totals.
    public func pendingUploadTotals(rootIds: [Int64]? = nil) throws -> (files: Int, bytes: Int64) {
        try writer.read { db in
            let request = Self.scoped(Self.hashedPendingRequest, to: rootIds)
            let files = try request.fetchCount(db)
            let bytes = try request.select(sum(Column("size")), as: Int64.self).fetchOne(db) ?? 0
            return (files, bytes)
        }
    }

    /// Files sharing identical bytes with another file (beyond the first
    /// copy), within the given roots.
    public func duplicateFileCount(rootIds: [Int64]? = nil) throws -> Int {
        try writer.read { db in
            let request = Self.scoped(FileRecord.filter(Column("sha256") != nil), to: rootIds)
            let total = try request.fetchCount(db)
            let distinct =
                try request.select(Column("sha256"), as: Data.self).distinct().fetchCount(db)
            return total - distinct
        }
    }

    /// Marks every pending file whose checksum matched an existing server
    /// asset. Local duplicates (same bytes at several paths) all resolve to
    /// the same asset ID.
    public func markSynced(assetIdsByChecksum: [Data: String]) throws {
        guard !assetIdsByChecksum.isEmpty else { return }
        try writer.write { db in
            let now = Date()
            for (checksum, assetId) in assetIdsByChecksum {
                try db.execute(
                    sql: """
                        UPDATE files SET status = ?, asset_id = ?, synced_at = ?, error_message = NULL
                        WHERE sha256 = ? AND status = ?
                        """,
                    arguments: [
                        FileStatus.synced.rawValue, assetId, now,
                        checksum, FileStatus.pending.rawValue,
                    ]
                )
            }
        }
    }

    public func markUploaded(_ fileId: Int64, assetId: String) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                    UPDATE files SET status = ?, asset_id = ?, synced_at = ?, error_message = NULL
                    WHERE id = ?
                    """,
                arguments: [FileStatus.synced.rawValue, assetId, Date(), fileId]
            )
        }
    }

    /// Permanent skip: the server rejected the format (422).
    public func markSkippedUnsupported(_ fileId: Int64, message: String? = nil) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE files SET status = ?, error_message = ? WHERE id = ?",
                arguments: [FileStatus.skippedUnsupported.rawValue, message, fileId]
            )
        }
    }

    public func markError(_ fileId: Int64, message: String) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE files SET status = ?, error_message = ? WHERE id = ?",
                arguments: [FileStatus.error.rawValue, message, fileId]
            )
        }
    }

    public func statusCounts(rootIds: [Int64]? = nil) throws -> [FileStatus: Int] {
        if let rootIds, rootIds.isEmpty { return [:] }
        return try writer.read { db in
            // One GROUP BY pass, not a COUNT per status — this runs on the
            // UI's live-refresh tick, where per-status table scans add up.
            var sql = "SELECT status, COUNT(*) AS n FROM files"
            var arguments: [any DatabaseValueConvertible] = []
            if let rootIds {
                let placeholders = repeatElement("?", count: rootIds.count)
                    .joined(separator: ", ")
                sql += " WHERE root_id IN (\(placeholders))"
                arguments = rootIds
            }
            sql += " GROUP BY status"
            var counts: [FileStatus: Int] = [:]
            let rows = try Row.fetchAll(
                db, sql: sql, arguments: Self.statementArguments(arguments, [])
            )
            for row in rows {
                guard let status = FileStatus(rawValue: row["status"]) else { continue }
                counts[status] = row["n"]
            }
            return counts
        }
    }

    // MARK: - Plan queries

    /// Per-directory, per-status aggregate for building the review tree in
    /// one query regardless of library size.
    public struct DirectoryStatusRow: Sendable, Equatable {
        public let parentDir: String
        public let status: FileStatus
        public let count: Int
        public let bytes: Int64

        public init(parentDir: String, status: FileStatus, count: Int, bytes: Int64) {
            self.parentDir = parentDir
            self.status = status
            self.count = count
            self.bytes = bytes
        }
    }

    public func directoryStatistics(rootId: Int64) throws -> [DirectoryStatusRow] {
        try writer.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT parent_dir, status, COUNT(*) AS n, COALESCE(SUM(size), 0) AS bytes
                    FROM files WHERE root_id = ?
                    GROUP BY parent_dir, status
                    """,
                arguments: [rootId]
            )
            return rows.compactMap { row in
                guard let status = FileStatus(rawValue: row["status"]) else { return nil }
                return DirectoryStatusRow(
                    parentDir: row["parent_dir"], status: status,
                    count: row["n"], bytes: row["bytes"]
                )
            }
        }
    }

    /// Files in a directory and everything beneath it, ordered by path.
    /// `limit` keeps a selection of a huge root from flooding the UI; `total`
    /// is the true subtree count so callers can say what was cut off.
    /// Prefix matching uses substr, not LIKE — paths may contain % and _.
    public func files(
        underDirectory parentDir: String, rootId: Int64, limit: Int = 2000
    ) throws -> (files: [FileRecord], total: Int) {
        try writer.read { db in
            let condition: String
            let arguments: StatementArguments
            if parentDir.isEmpty {
                condition = "root_id = ?"
                arguments = [rootId]
            } else {
                let prefix = parentDir + "/"
                condition = "root_id = ? AND (parent_dir = ? OR substr(parent_dir, 1, ?) = ?)"
                arguments = [rootId, parentDir, prefix.unicodeScalars.count, prefix]
            }
            let total =
                try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM files WHERE \(condition)",
                    arguments: arguments
                ) ?? 0
            let files = try FileRecord.fetchAll(
                db,
                sql: "SELECT * FROM files WHERE \(condition) ORDER BY rel_path LIMIT \(limit)",
                arguments: arguments
            )
            return (files, total)
        }
    }

    // MARK: - Exclusions

    public func addExclusion(rootId: Int64, kind: Exclusion.Kind, relPath: String) throws {
        try writer.write { db in
            var exclusion = Exclusion(
                id: nil, rootId: rootId, kind: kind, relPath: relPath, createdAt: Date()
            )
            try exclusion.insert(db, onConflict: .ignore)
        }
    }

    public func removeExclusion(rootId: Int64, kind: Exclusion.Kind, relPath: String) throws {
        try writer.write { db in
            try db.execute(
                sql: "DELETE FROM exclusions WHERE root_id = ? AND kind = ? AND rel_path = ?",
                arguments: [rootId, kind.rawValue, relPath]
            )
        }
    }

    /// Toggles an exclusion at review time, updating covered rows' statuses
    /// immediately so the plan reflects the change without a re-scan.
    /// Un-excluding restores each row from what the cache still knows, unless
    /// another (nested) exclusion still covers it.
    public func setExcluded(
        rootId: Int64, kind: Exclusion.Kind, relPath: String, excluded: Bool
    ) throws {
        if excluded {
            try addExclusion(rootId: rootId, kind: kind, relPath: relPath)
            try writer.write { db in
                try db.execute(
                    sql: """
                        UPDATE files SET status = ?
                        WHERE root_id = ? AND \(Self.coveredPredicate(kind: kind))
                        """,
                    arguments: Self.statementArguments(
                        [FileStatus.excluded.rawValue, rootId],
                        Self.coveredArguments(kind: kind, relPath: relPath)
                    )
                )
            }
        } else {
            try removeExclusion(rootId: rootId, kind: kind, relPath: relPath)
            let remaining = try exclusions(forRoot: rootId)
            try writer.write { db in
                let covered = try FileRecord.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM files
                        WHERE root_id = ? AND status = ? AND \(Self.coveredPredicate(kind: kind))
                        """,
                    arguments: Self.statementArguments(
                        [rootId, FileStatus.excluded.rawValue],
                        Self.coveredArguments(kind: kind, relPath: relPath)
                    )
                )
                for record in covered {
                    guard !remaining.contains(where: { $0.covers(relPath: record.relPath) })
                    else { continue }
                    let restored: FileStatus =
                        record.assetId != nil
                        ? .synced
                        : FileClassifier.classify(fileName: record.fileName).initialStatus
                    try db.execute(
                        sql: "UPDATE files SET status = ? WHERE id = ?",
                        arguments: [restored.rawValue, record.id]
                    )
                }
            }
        }
    }

    /// substr comparison instead of LIKE: paths may contain LIKE wildcards.
    private static func coveredPredicate(kind: Exclusion.Kind) -> String {
        switch kind {
        case .file: "rel_path = ?"
        case .directory: "substr(rel_path, 1, ?) = ?"
        }
    }

    private static func statementArguments(
        _ head: [any DatabaseValueConvertible], _ tail: [any DatabaseValueConvertible]
    ) -> StatementArguments {
        StatementArguments((head + tail).map { $0 as (any DatabaseValueConvertible)? })
    }

    private static func coveredArguments(kind: Exclusion.Kind, relPath: String) -> [any DatabaseValueConvertible] {
        switch kind {
        case .file: [relPath]
        // substr counts code points, and macOS paths are NFD-decomposed —
        // so count unicode scalars, not graphemes or bytes.
        case .directory: [relPath.unicodeScalars.count + 1, relPath + "/"]
        }
    }

    public func exclusions(forRoot rootId: Int64) throws -> [Exclusion] {
        try writer.read { db in
            try Exclusion
                .filter(Column("root_id") == rootId)
                .order(Column("rel_path"))
                .fetchAll(db)
        }
    }

    // MARK: - Runs

    public func beginRun(rootIds: [Int64]) throws -> RunRecord {
        try writer.write { db in
            var run = RunRecord(
                id: nil,
                startedAt: Date(),
                finishedAt: nil,
                outcome: .running,
                rootIdsJSON: Self.encodeJSON(rootIds),
                countersJSON: Self.encodeJSON(RunCounters())
            )
            try run.insert(db)
            return run
        }
    }

    /// Narrows a run's recorded root set (e.g. after a root vanished
    /// mid-scan), so upload scoping reflects what was actually analyzed.
    public func updateRunRootIds(_ runId: Int64, rootIds: [Int64]) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE runs SET root_ids_json = ? WHERE id = ?",
                arguments: [Self.encodeJSON(rootIds), runId]
            )
        }
    }

    public func finishRun(_ runId: Int64, outcome: RunOutcome, counters: RunCounters) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE runs SET finished_at = ?, outcome = ?, counters_json = ? WHERE id = ?",
                arguments: [Date(), outcome.rawValue, Self.encodeJSON(counters), runId]
            )
        }
    }

    public func latestRuns(limit: Int = 50) throws -> [RunRecord] {
        try writer.read { db in
            try RunRecord.order(Column("id").desc).limit(limit).fetchAll(db)
        }
    }

    public func run(id: Int64) throws -> RunRecord? {
        try writer.read { db in
            try RunRecord.fetchOne(db, key: id)
        }
    }

    private static func encodeJSON(_ value: some Encodable) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Settings

    public func setting(_ key: String) throws -> String? {
        try writer.read { db in
            try String.fetchOne(
                db, sql: "SELECT value FROM settings WHERE key = ?", arguments: [key]
            )
        }
    }

    public func setSetting(_ key: String, to value: String?) throws {
        try writer.write { db in
            if let value {
                try db.execute(
                    sql: "INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                    arguments: [key, value]
                )
            } else {
                try db.execute(sql: "DELETE FROM settings WHERE key = ?", arguments: [key])
            }
        }
    }

    public func serverURL() throws -> String {
        try setting(SettingsKey.serverURL) ?? Self.defaultServerURL
    }

    public func hashConcurrency() throws -> Int? {
        try setting(SettingsKey.hashConcurrency).flatMap(Int.init)
    }

    public func setHashConcurrency(_ value: Int) throws {
        try setSetting(SettingsKey.hashConcurrency, to: String(value))
    }

    public func uploadConcurrency() throws -> Int? {
        try setting(SettingsKey.uploadConcurrency).flatMap(Int.init)
    }

    public func setUploadConcurrency(_ value: Int) throws {
        try setSetting(SettingsKey.uploadConcurrency, to: String(value))
    }

    /// The most recent analysis run that finished cleanly — the run an upload
    /// may continue from, surviving app restarts. Cleared when the server or
    /// library changes, because that plan was reviewed against the old
    /// destination.
    public func lastCompletedAnalysisRunId() throws -> Int64? {
        try setting(SettingsKey.lastAnalysisRunId).flatMap(Int64.init)
    }

    public func setLastCompletedAnalysisRunId(_ id: Int64?) throws {
        try setSetting(SettingsKey.lastAnalysisRunId, to: id.map(String.init))
    }

    /// Stable per-install identifier sent as `device_id`; created on first use.
    public func deviceId() throws -> String {
        try writer.write { db in
            if let existing = try String.fetchOne(
                db, sql: "SELECT value FROM settings WHERE key = ?",
                arguments: [SettingsKey.deviceId]
            ) {
                return existing
            }
            let created = UUID().uuidString
            try db.execute(
                sql: "INSERT INTO settings (key, value) VALUES (?, ?)",
                arguments: [SettingsKey.deviceId, created]
            )
            return created
        }
    }

    public func libraryId() throws -> String? {
        try setting(SettingsKey.libraryId)
    }

    /// Applies a server/library change. Sync state (`synced` status, asset IDs)
    /// is only meaningful against one server + library, so changing either
    /// resets it — hashes are server-independent and always kept. Returns
    /// whether a reset happened.
    @discardableResult
    public func updateServerConfiguration(serverURL: String, libraryId: String?) throws -> Bool {
        let currentServer = try self.serverURL()
        let currentLibrary = try self.libraryId()
        let changed = serverURL != currentServer || libraryId != currentLibrary

        if changed {
            try writer.write { db in
                // Destination-specific fields are cleared on EVERY row that
                // holds one — an excluded (or errored) row keeps its status
                // but must not carry the old destination's asset id, or
                // un-excluding it later would restore it straight to synced.
                try db.execute(
                    sql: """
                        UPDATE files SET
                            status = CASE WHEN status = ? THEN ? ELSE status END,
                            asset_id = NULL, synced_at = NULL
                        WHERE status = ? OR asset_id IS NOT NULL
                        """,
                    arguments: [
                        FileStatus.synced.rawValue, FileStatus.pending.rawValue,
                        FileStatus.synced.rawValue,
                    ]
                )
            }
            try setLastCompletedAnalysisRunId(nil)
        }
        try setSetting(SettingsKey.serverURL, to: serverURL)
        try setSetting(SettingsKey.libraryId, to: libraryId)
        return changed
    }
}
