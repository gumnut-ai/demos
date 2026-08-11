import Foundation

public enum SyncPhase: String, Sendable, Equatable {
    case preflight, scanning, hashing, checking, uploading, finished
}

public enum SyncEvent: Sendable, Equatable {
    case phase(SyncPhase)
    case scanProgress(discovered: Int)
    case hashProgress(hashedFiles: Int, totalFiles: Int, hashedBytes: Int64, totalBytes: Int64)
    case checkProgress(checked: Int, matched: Int)
    case uploadProgress(completed: Int, total: Int, bytesUploaded: Int64)
    /// Per-file upload lifecycle, for live "what's in flight" UI. `path` is
    /// the absolute path (for thumbnails); `bytesTotal` in progress events is
    /// the encoded request body, slightly larger than the file itself.
    case uploadFileStarted(relPath: String, path: String, bytesTotal: Int64)
    case uploadFileProgress(relPath: String, bytesSent: Int64, bytesTotal: Int64)
    case uploadFileFinished(relPath: String)
    case fileIssue(relPath: String, message: String)
}

/// Rate-limits high-frequency progress emissions (URLSession delegate
/// callbacks, per-file hash completions).
private final class EmitGate: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast

    func shouldEmit(interval: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        guard now.timeIntervalSince(last) >= interval else { return false }
        last = now
        return true
    }
}

public enum SyncEngineError: Error, Equatable {
    case noIncludedRoots
    /// Every included root was unreachable (e.g. NAS unmounted). Nothing was
    /// scanned and no state was touched.
    case noReachableRoots(skippedPaths: [String])
    case runNotFound(Int64)
}

public struct SyncEngineConfiguration: Sendable {
    public var hashConcurrency = 2
    public var uploadConcurrency = 3
    /// Files modified more recently than this are deferred to the next run —
    /// they may still be mid-copy.
    public var recentModificationGrace: TimeInterval = 30
    public var existenceBatchSize = GumnutClient.maxExistenceCheckItems
    public var scanRecordBatchSize = 500
    public var uploadBatchSize = 100
    public var maxUploadAttempts = 3
    public var retryBaseDelay: TimeInterval = 1
    public var maxRetryDelay: TimeInterval = 60
    /// Injectable clock (mid-copy deferral tests).
    public var now: @Sendable () -> Date = { Date() }
    /// Injectable hasher (call-counting tests).
    public var hashFile: @Sendable (URL) throws -> Data = { try FileHasher.sha256(contentsOf: $0) }

    public init() {}
}

public struct AnalysisResult: Sendable, Equatable {
    public let runId: Int64
    public let counters: RunCounters
    public let toUploadBytes: Int64
    /// Included roots skipped this run because they were unreachable.
    public let skippedRootPaths: [String]

    public init(
        runId: Int64, counters: RunCounters, toUploadBytes: Int64, skippedRootPaths: [String]
    ) {
        self.runId = runId
        self.counters = counters
        self.toUploadBytes = toUploadBytes
        self.skippedRootPaths = skippedRootPaths
    }
}

public struct UploadResult: Sendable, Equatable {
    public var uploaded = 0
    public var alreadyExisted = 0
    public var failed = 0
    public var skippedUnsupported = 0
    public var skippedChanged = 0
    public var bytesUploaded: Int64 = 0
    public var stoppedByQuota = false
}

/// Orchestrates one sync operation over the store, file reader, and API
/// client. `runAnalysis` covers preflight → scan → hash → check and stops at
/// the review gate; `runUpload` sends what is still pending after the user's
/// review. Create a fresh instance per operation.
///
/// Every phase persists through the store as it goes, so cancellation or a
/// crash never loses work — the next run resumes from cached state.
public actor SyncEngine {
    private let store: Store
    private let reader: FileReader
    private let client: GumnutClient
    private let config: SyncEngineConfiguration
    private let onEvent: (@Sendable (SyncEvent) -> Void)?

    // Hash-phase progress.
    private var hashedFilesCount = 0
    private var hashedBytesCount: Int64 = 0
    private var totalHashFiles = 0
    private var totalHashBytes: Int64 = 0
    private let hashProgressGate = EmitGate()

    // Upload-phase state.
    private var uploadResult = UploadResult()
    private var uploadTotalFiles = 0
    private var stopUploads = false
    private var fatalUploadError: GumnutClientError?

    public init(
        store: Store,
        reader: FileReader = FileReader(),
        client: GumnutClient,
        configuration: SyncEngineConfiguration = SyncEngineConfiguration(),
        onEvent: (@Sendable (SyncEvent) -> Void)? = nil
    ) {
        self.store = store
        self.reader = reader
        self.client = client
        self.config = configuration
        self.onEvent = onEvent
    }

    private nonisolated func emit(_ event: SyncEvent) {
        onEvent?(event)
    }

    // MARK: - Analysis (preflight → scan → hash → check)

    public func runAnalysis() async throws -> AnalysisResult {
        emit(.phase(.preflight))
        let included = try store.allRoots().filter(\.included)
        guard !included.isEmpty else { throw SyncEngineError.noIncludedRoots }

        var reachable: [Root] = []
        var skippedPaths: [String] = []
        for root in included {
            if reader.directoryExists(atPath: root.path) {
                reachable.append(root)
            } else {
                skippedPaths.append(root.path)
            }
        }
        guard !reachable.isEmpty else {
            throw SyncEngineError.noReachableRoots(skippedPaths: skippedPaths)
        }

        // Validates the API key before any work.
        _ = try await client.currentUser()
        let libraryId = try store.libraryId()

        let run = try store.beginRun(rootIds: reachable.compactMap(\.id))
        let runId = run.id!
        do {
            var tally = ScanTally()
            var stillReachable: [Root] = []
            emit(.phase(.scanning))
            for root in reachable {
                do {
                    let (rootTally, enumerationComplete) = try scan(
                        root: root, runId: runId, previouslyDiscovered: tally.discovered
                    )
                    tally.merge(rootTally)
                    stillReachable.append(root)
                    // Rows this scan did not see are files no longer under the
                    // root (deleted, moved, or renamed); drop them so the plan
                    // stops counting ghosts. Only after a failure-free
                    // enumeration — an unreadable subtree must not read as
                    // deletion, and unreachable roots never get here at all.
                    if enumerationComplete {
                        try store.pruneVanishedFiles(rootId: root.id!, scanId: runId)
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // Only an unmount/vanish counts as unreachable — a store
                    // failure must fail the run, not masquerade as one.
                    guard !reader.directoryExists(atPath: root.path) else { throw error }
                    skippedPaths.append(root.path)
                    emit(.fileIssue(relPath: root.path, message: "root became unreachable; skipped"))
                }
            }
            let rootIds = stillReachable.compactMap(\.id)
            // A root that vanished mid-scan was not analyzed: narrow the run's
            // recorded set so a later upload of this plan cannot include it.
            if stillReachable.count != reachable.count {
                try store.updateRunRootIds(runId, rootIds: rootIds)
            }

            try await hashPhase(roots: stillReachable)
            try Task.checkCancellation()
            try await checkPhase(rootIds: rootIds, libraryId: libraryId)
            try Task.checkCancellation()

            let counts = try store.statusCounts(rootIds: rootIds)
            let uploadTotals = try store.pendingUploadTotals(rootIds: rootIds)
            var counters = RunCounters()
            counters.filesDiscovered = tally.discovered
            counters.mediaFiles = tally.media
            counters.deferredRecentlyModified = tally.deferred
            counters.alreadySynced = counts[.synced] ?? 0
            counters.toUpload = uploadTotals.files
            counters.skippedRaw = counts[.skippedRaw] ?? 0
            counters.skippedUnsupported = counts[.skippedUnsupported] ?? 0
            counters.excluded = counts[.excluded] ?? 0
            counters.errors = counts[.error] ?? 0
            counters.duplicateLocalFiles = try store.duplicateFileCount(rootIds: rootIds)

            try store.finishRun(runId, outcome: .completed, counters: counters)
            try store.setLastCompletedAnalysisRunId(runId)
            emit(.phase(.finished))
            return AnalysisResult(
                runId: runId,
                counters: counters,
                toUploadBytes: uploadTotals.bytes,
                skippedRootPaths: skippedPaths
            )
        } catch is CancellationError {
            try? store.finishRun(runId, outcome: .cancelled, counters: RunCounters())
            throw CancellationError()
        } catch {
            try? store.finishRun(runId, outcome: .failed, counters: RunCounters())
            throw error
        }
    }

    private struct ScanTally {
        var discovered = 0
        var media = 0
        var deferred = 0

        mutating func merge(_ other: ScanTally) {
            discovered += other.discovered
            media += other.media
            deferred += other.deferred
        }
    }

    /// Nonisolated so the enumeration closure only touches local state (the
    /// store and event sink are Sendable).
    private nonisolated func scan(
        root: Root, runId: Int64, previouslyDiscovered: Int
    ) throws -> (tally: ScanTally, enumerationComplete: Bool) {
        let exclusions = try store.exclusions(forRoot: root.id!)
        var tally = ScanTally()
        var buffer: [Store.ScannedFileInput] = []
        var deferredPaths: [String] = []

        func flush() throws {
            try store.recordScannedFiles(rootId: root.id!, files: buffer, scanId: runId)
            buffer.removeAll(keepingCapacity: true)
            emit(.scanProgress(discovered: previouslyDiscovered + tally.discovered))
        }

        let failures = try reader.enumerate(
            root: URL(fileURLWithPath: root.path, isDirectory: true)
        ) { file in
            try Task.checkCancellation()

            // Recently modified files may still be mid-copy; pick them up
            // next run. (A future mtime — clock skew — is recorded normally
            // rather than deferred forever.)
            let age = config.now().timeIntervalSince1970 - file.mtime
            if age >= 0 && age < config.recentModificationGrace {
                tally.deferred += 1
                deferredPaths.append(file.relPath)
                return
            }

            let fileName = (file.relPath as NSString).lastPathComponent
            let classification = FileClassifier.classify(fileName: fileName)
            let excluded = exclusions.contains { $0.covers(relPath: file.relPath) }

            tally.discovered += 1
            if classification == .image || classification == .video {
                tally.media += 1
            }
            buffer.append(
                Store.ScannedFileInput(
                    relPath: file.relPath, size: file.size, mtime: file.mtime,
                    classification: classification, excluded: excluded
                )
            )
            if buffer.count >= config.scanRecordBatchSize {
                try flush()
            }
        }
        try flush()
        // Deferred files were seen — only their re-recording is postponed —
        // so stamp them to keep them out of pruning's reach.
        try store.markSeen(rootId: root.id!, relPaths: deferredPaths, scanId: runId)
        for failure in failures {
            emit(.fileIssue(relPath: failure.path, message: failure.message))
        }
        return (tally, failures.isEmpty)
    }

    // MARK: - Hash phase

    private func hashPhase(roots: [Root]) async throws {
        let rootIds = roots.compactMap(\.id)
        let rootsById = Dictionary(
            uniqueKeysWithValues: roots.compactMap { root in root.id.map { ($0, root) } }
        )
        let totals = try store.pendingHashTotals(rootIds: rootIds)
        guard totals.files > 0 else { return }

        emit(.phase(.hashing))
        hashedFilesCount = 0
        hashedBytesCount = 0
        totalHashFiles = totals.files
        totalHashBytes = totals.bytes

        while true {
            try Task.checkCancellation()
            let batch = try store.filesNeedingHash(rootIds: rootIds, limit: 500)
            guard !batch.isEmpty else { break }

            try await withThrowingTaskGroup(of: Void.self) { group in
                var iterator = batch.makeIterator()
                func addNext() {
                    guard !Task.isCancelled,
                        let file = iterator.next(),
                        let root = rootsById[file.rootId]
                    else { return }
                    let store = self.store
                    let config = self.config
                    group.addTask {
                        guard !Task.isCancelled else { return }
                        let url = URL(fileURLWithPath: root.path).appending(path: file.relPath)
                        do {
                            let sha256 = try config.hashFile(url)
                            try store.markHashed(file.id!, sha256: sha256)
                            await self.noteHashed(bytes: file.size)
                        } catch is CancellationError {
                            // Leave unhashed; the next run picks it up.
                        } catch {
                            try? store.markError(
                                file.id!, message: "hashing failed: \(error.localizedDescription)"
                            )
                            self.emit(
                                .fileIssue(
                                    relPath: file.relPath,
                                    message: "hashing failed: \(error.localizedDescription)"
                                )
                            )
                        }
                    }
                }
                for _ in 0..<max(1, config.hashConcurrency) {
                    addNext()
                }
                while try await group.next() != nil {
                    addNext()
                }
            }
        }
        emit(
            .hashProgress(
                hashedFiles: hashedFilesCount, totalFiles: totalHashFiles,
                hashedBytes: hashedBytesCount, totalBytes: totalHashBytes
            )
        )
    }

    private func noteHashed(bytes: Int64) {
        hashedFilesCount += 1
        hashedBytesCount += bytes
        // Hashing many small local files can finish thousands per second;
        // forward at most a few events per second. hashPhase emits the final
        // totals unconditionally once its loop drains.
        guard hashProgressGate.shouldEmit(interval: 0.25) else { return }
        emit(
            .hashProgress(
                hashedFiles: hashedFilesCount, totalFiles: totalHashFiles,
                hashedBytes: hashedBytesCount, totalBytes: totalHashBytes
            )
        )
    }

    // MARK: - Check phase

    private func checkPhase(rootIds: [Int64], libraryId: String?) async throws {
        emit(.phase(.checking))
        var cursor: Store.PendingCursor?
        var checked = 0
        var matched = 0
        while true {
            try Task.checkCancellation()
            let batch = try store.hashedPendingFiles(
                rootIds: rootIds, after: cursor, limit: config.existenceBatchSize
            )
            guard !batch.isEmpty else { break }
            cursor = batch.last.map(Store.PendingCursor.init)

            let digests = Array(Set(batch.compactMap(\.sha256)))
            let matches = try await client.checkExistence(
                sha256Digests: digests, libraryId: libraryId
            )
            var assetIdsByChecksum: [Data: String] = [:]
            for match in matches {
                if let digest = Data(base64Encoded: match.checksum) {
                    assetIdsByChecksum[digest] = match.id
                }
            }
            try store.markSynced(assetIdsByChecksum: assetIdsByChecksum)

            checked += batch.count
            matched += batch.count { file in
                file.sha256.map { assetIdsByChecksum[$0] != nil } ?? false
            }
            emit(.checkProgress(checked: checked, matched: matched))
        }
    }

    // MARK: - Upload phase

    /// Uploads everything still pending after review, continuing the given
    /// analysis run's record. Files whose bytes changed since analysis are
    /// skipped and reset for the next run — never uploaded blind.
    public func runUpload(continuing runId: Int64) async throws -> UploadResult {
        guard let run = try store.run(id: runId) else {
            throw SyncEngineError.runNotFound(runId)
        }
        // The reviewed plan is authoritative: upload exactly the roots the
        // analysis covered, not whatever is included in the sidebar now — a
        // root toggled on after review must not upload unreviewed files, and
        // one toggled off must not silently drop reviewed ones.
        let runRootIds = Set(run.rootIds)
        let runRoots = try store.allRoots().filter { root in
            root.id.map(runRootIds.contains) ?? false
        }
        var roots: [Root] = []
        for root in runRoots {
            if reader.directoryExists(atPath: root.path) {
                roots.append(root)
            } else {
                emit(
                    .fileIssue(
                        relPath: root.path,
                        message: "root became unreachable; its reviewed files were not uploaded"
                    )
                )
            }
        }
        guard !roots.isEmpty else {
            throw SyncEngineError.noReachableRoots(skippedPaths: runRoots.map(\.path))
        }
        let rootIds = roots.compactMap(\.id)
        let rootsById = Dictionary(
            uniqueKeysWithValues: roots.compactMap { root in root.id.map { ($0, root) } }
        )
        let deviceId = try store.deviceId()
        let libraryId = try store.libraryId()

        uploadResult = UploadResult()
        stopUploads = false
        fatalUploadError = nil
        uploadTotalFiles = try store.pendingUploadTotals(rootIds: rootIds).files
        emit(.phase(.uploading))

        do {
            var cursor: Store.PendingCursor?
            while !stopUploads {
                try Task.checkCancellation()
                let batch = try store.hashedPendingFiles(
                    rootIds: rootIds, after: cursor, limit: config.uploadBatchSize
                )
                guard !batch.isEmpty else { break }
                cursor = batch.last.map(Store.PendingCursor.init)

                await withTaskGroup(of: Void.self) { group in
                    var iterator = batch.makeIterator()
                    func addNext() {
                        guard !Task.isCancelled,
                            let file = iterator.next(),
                            let root = rootsById[file.rootId]
                        else { return }
                        group.addTask {
                            await self.performUpload(
                                file: file, root: root, deviceId: deviceId, libraryId: libraryId
                            )
                        }
                    }
                    for _ in 0..<max(1, config.uploadConcurrency) {
                        addNext()
                    }
                    while await group.next() != nil {
                        addNext()
                    }
                }
            }
            try Task.checkCancellation()

            // The generic catch below records the .failed finish.
            if let fatalUploadError {
                throw fatalUploadError
            }
            try finishUploadRun(run: run, runId: runId, rootIds: rootIds, outcome: .completed)
            emit(.phase(.finished))
            return uploadResult
        } catch is CancellationError {
            try? finishUploadRun(run: run, runId: runId, rootIds: rootIds, outcome: .cancelled)
            throw CancellationError()
        } catch {
            try? finishUploadRun(run: run, runId: runId, rootIds: rootIds, outcome: .failed)
            throw error
        }
    }

    private func finishUploadRun(
        run: RunRecord, runId: Int64, rootIds: [Int64], outcome: RunOutcome
    ) throws {
        var counters = run.counters
        counters.uploaded += uploadResult.uploaded + uploadResult.alreadyExisted
        counters.bytesUploaded += uploadResult.bytesUploaded
        counters.toUpload = (try? store.pendingUploadTotals(rootIds: rootIds).files) ?? 0
        counters.errors = (try? store.statusCounts(rootIds: rootIds)[.error]) ?? 0
        try store.finishRun(runId, outcome: outcome, counters: counters)
    }

    private func performUpload(
        file: FileRecord, root: Root, deviceId: String, libraryId: String?
    ) async {
        guard !stopUploads, !Task.isCancelled else { return }
        let fileURL = URL(fileURLWithPath: root.path).appending(path: file.relPath)

        // The plan was built from a stat; refuse to upload bytes that no
        // longer match it.
        let current: (size: Int64, mtime: Double)
        do {
            current = try reader.stat(fileAt: fileURL)
        } catch {
            try? store.markError(file.id!, message: "unreadable before upload")
            uploadResult.failed += 1
            emit(.fileIssue(relPath: file.relPath, message: "unreadable before upload"))
            return
        }
        guard current.size == file.size, current.mtime == file.mtime else {
            _ = try? store.recordScannedFile(
                rootId: file.rootId, relPath: file.relPath,
                size: current.size, mtime: current.mtime,
                classification: FileClassifier.classify(fileName: file.fileName),
                excluded: false, scanId: nil
            )
            uploadResult.skippedChanged += 1
            emit(
                .fileIssue(
                    relPath: file.relPath, message: "changed since analysis; re-analyze to upload"
                )
            )
            return
        }

        let times = try? reader.fileTimes(at: fileURL)
        let modified = times?.modified ?? Date(timeIntervalSince1970: file.mtime)
        let created = times?.created ?? modified

        emit(.uploadFileStarted(relPath: file.relPath, path: fileURL.path, bytesTotal: file.size))
        defer { emit(.uploadFileFinished(relPath: file.relPath)) }
        // URLSession reports every body chunk; forward at most a few per
        // second (plus the final one) so the UI isn't flooded.
        let relPath = file.relPath
        let progressGate = EmitGate()
        let onProgress: @Sendable (Int64, Int64) -> Void = { sent, total in
            if sent >= total || progressGate.shouldEmit(interval: 0.25) {
                self.emit(
                    .uploadFileProgress(relPath: relPath, bytesSent: sent, bytesTotal: total)
                )
            }
        }

        do {
            let (outcome, asset) = try await Self.uploadWithRetry(
                client: client, fileURL: fileURL, fileName: file.fileName,
                deviceAssetId: "\(root.uuid):\(file.relPath)", deviceId: deviceId,
                createdAt: created, modifiedAt: modified, libraryId: libraryId, config: config,
                onProgress: onProgress
            )
            if let serverChecksum = asset.fileData?.checksum,
                let localDigest = file.sha256,
                serverChecksum != localDigest.base64EncodedString()
            {
                try? store.markError(file.id!, message: "server checksum mismatch after upload")
                uploadResult.failed += 1
                emit(
                    .fileIssue(
                        relPath: file.relPath, message: "server checksum mismatch after upload"
                    )
                )
                return
            }
            try? store.markUploaded(file.id!, assetId: asset.id)
            if outcome == .created {
                uploadResult.uploaded += 1
            } else {
                uploadResult.alreadyExisted += 1
            }
            uploadResult.bytesUploaded += file.size
            emit(
                .uploadProgress(
                    completed: uploadResult.uploaded + uploadResult.alreadyExisted,
                    total: uploadTotalFiles,
                    bytesUploaded: uploadResult.bytesUploaded
                )
            )
        } catch let error as GumnutClientError {
            switch error {
            case .storageQuotaExceeded:
                // Leave the file pending; it can upload once space exists.
                stopUploads = true
                uploadResult.stoppedByQuota = true
                emit(
                    .fileIssue(
                        relPath: file.relPath, message: "storage quota exceeded; upload stopped"
                    )
                )
            case .unauthorized(let statusCode, let message):
                stopUploads = true
                fatalUploadError = error
                emit(
                    .fileIssue(
                        relPath: file.relPath,
                        message: "refused as unauthorized (HTTP \(statusCode)): "
                            + (message ?? "no detail")
                    )
                )
            case .edgeBlocked(let statusCode, let requestId):
                // The server's firewall objected to this file's bytes; the
                // run continues — other files are unaffected.
                let detail =
                    "blocked by the server's firewall (HTTP \(statusCode), "
                    + "request id \(requestId ?? "unknown"))"
                try? store.markError(file.id!, message: detail)
                uploadResult.failed += 1
                emit(.fileIssue(relPath: file.relPath, message: detail))
            case .invalidRequest(let statusCode, let message) where statusCode == 422:
                try? store.markSkippedUnsupported(file.id!, message: message)
                uploadResult.skippedUnsupported += 1
                emit(
                    .fileIssue(
                        relPath: file.relPath,
                        message: "rejected as unsupported: \(message ?? "422")"
                    )
                )
            default:
                try? store.markError(file.id!, message: "upload failed: \(error)")
                uploadResult.failed += 1
                emit(.fileIssue(relPath: file.relPath, message: "upload failed: \(error)"))
            }
        } catch is CancellationError {
            // Leave pending.
        } catch {
            try? store.markError(
                file.id!, message: "upload failed: \(error.localizedDescription)"
            )
            uploadResult.failed += 1
            emit(
                .fileIssue(
                    relPath: file.relPath,
                    message: "upload failed: \(error.localizedDescription)"
                )
            )
        }
    }

    private static func uploadWithRetry(
        client: GumnutClient, fileURL: URL, fileName: String,
        deviceAssetId: String, deviceId: String,
        createdAt: Date, modifiedAt: Date, libraryId: String?,
        config: SyncEngineConfiguration,
        onProgress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async throws -> (outcome: UploadOutcome, asset: GumnutAsset) {
        var attempt = 0
        while true {
            attempt += 1
            do {
                return try await client.uploadAsset(
                    fileURL: fileURL, fileName: fileName,
                    deviceAssetId: deviceAssetId, deviceId: deviceId,
                    fileCreatedAt: createdAt, fileModifiedAt: modifiedAt, libraryId: libraryId,
                    onProgress: onProgress
                )
            } catch {
                guard attempt < config.maxUploadAttempts,
                    let delay = retryDelay(for: error, attempt: attempt, config: config)
                else { throw error }
                try await Task.sleep(for: .seconds(delay))
            }
        }
    }

    /// Retry-eligible errors: rate limiting and transient server/network
    /// failures, honoring Retry-After when present. Everything else is final.
    private static func retryDelay(
        for error: Error, attempt: Int, config: SyncEngineConfiguration
    ) -> TimeInterval? {
        let backoff = config.retryBaseDelay * pow(2, Double(attempt - 1))
        switch error {
        case let clientError as GumnutClientError:
            switch clientError {
            case .rateLimited(let retryAfter), .transientServer(_, let retryAfter, _):
                return min(retryAfter ?? backoff, config.maxRetryDelay)
            default:
                return nil
            }
        case is URLError:
            return min(backoff, config.maxRetryDelay)
        default:
            return nil
        }
    }
}
