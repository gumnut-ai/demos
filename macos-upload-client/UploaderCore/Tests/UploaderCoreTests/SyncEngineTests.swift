import CryptoKit
import Foundation
import Testing

@testable import UploaderCore

/// Thread-safe accumulators for stub handlers and event sinks.
final class Recorder<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Element] = []

    func append(_ element: Element) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(element)
    }

    var items: [Element] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

final class AtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    @discardableResult
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Holds a cancellable task; tolerates cancel() arriving before set().
final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<AnalysisResult, any Error>?
    private var pendingCancel = false

    func set(_ task: Task<AnalysisResult, any Error>) {
        lock.lock()
        defer { lock.unlock() }
        self.task = task
        if pendingCancel { task.cancel() }
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        if let task { task.cancel() } else { pendingCancel = true }
    }
}

private func sha256B64(_ contents: String) -> String {
    Data(SHA256.hash(data: Data(contents.utf8))).base64EncodedString()
}

private func assetJSON(id: String, checksumB64: String) -> String {
    #"{"id": "\#(id)", "file_data": {"checksum": "\#(checksumB64)"}}"#
}

/// Serialized: StubURLProtocol keeps shared mutable state.
@Suite(.serialized) struct SyncEngineTests {
    typealias CapturedCall = (path: String, request: URLRequest, body: Data?)

    struct Env {
        let dir: TempDir
        let store: Store
        let client: GumnutClient
        let root: Root
        let calls: Recorder<CapturedCall>
        let events: Recorder<SyncEvent>

        var phases: [SyncPhase] {
            events.items.compactMap {
                if case .phase(let phase) = $0 { return phase } else { return nil }
            }
        }

        func bodies(for path: String) -> [Data?] {
            calls.items.filter { $0.path == path }.map(\.body)
        }

        func engine(configure: (inout SyncEngineConfiguration) -> Void = { _ in }) -> SyncEngine {
            var config = SyncEngineConfiguration()
            config.retryBaseDelay = 0
            configure(&config)
            return SyncEngine(
                store: store, client: client, configuration: config,
                onEvent: { [events] in events.append($0) }
            )
        }
    }

    private func makeEnv() throws -> Env {
        let dir = try TempDir()
        let store = try Store.inMemory()
        let root = try store.addRoot(path: dir.url.path)
        let client = GumnutClient(
            baseURL: URL(string: "https://gumnut.example.com")!,
            apiKey: "test-key",
            session: EngineTestStub.makeSession()
        )
        return Env(
            dir: dir, store: store, client: client, root: root,
            calls: Recorder(), events: Recorder()
        )
    }

    /// Routes the stub server; unrouted paths 404.
    private func installRoutes(
        _ env: Env,
        exist: @escaping @Sendable (Data?) -> StubURLProtocol.Response = { _ in
            .json(200, #"{"assets": []}"#)
        },
        upload: @escaping @Sendable (URLRequest, Data?) -> StubURLProtocol.Response = { _, _ in
            .json(500, "{}")
        }
    ) {
        let calls = env.calls
        EngineTestStub.handler = { request, body in
            let path = request.url?.path() ?? ""
            calls.append((path: path, request: request, body: body))
            switch path {
            case "/api/users/me":
                return .json(200, #"{"id": "intuser_1"}"#)
            case "/api/assets/exist":
                return exist(body)
            case "/api/assets":
                return upload(request, body)
            default:
                return .json(404, #"{"detail": "not found"}"#)
            }
        }
    }

    /// Writes a file whose mtime is safely in the past (not "mid-copy").
    @discardableResult
    private func writeAged(
        _ dir: TempDir, _ relPath: String, _ contents: String, age: TimeInterval = 3600
    ) throws -> URL {
        let url = try dir.write(relPath, Data(contents.utf8))
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path
        )
        return url
    }

    // MARK: - Analysis

    @Test func analysisClassifiesChecksAndDefers() async throws {
        defer { EngineTestStub.reset() }
        let env = try makeEnv()
        try writeAged(env.dir, "a.jpg", "aaa")
        try writeAged(env.dir, "sub/b.jpg", "bbbb")
        try writeAged(env.dir, "c.nef", "raw-bytes")
        try writeAged(env.dir, "d.txt", "not media")
        try writeAged(env.dir, "skipdir/e.jpg", "eeeee")
        try env.dir.write("fresh.jpg", Data("just-copied".utf8))  // mtime = now → deferred
        try env.store.addExclusion(rootId: env.root.id!, kind: .directory, relPath: "skipdir")

        installRoutes(env) { _ in
            .json(
                200,
                #"{"assets": [{"id": "asset_a", "checksum": "\#(sha256B64("aaa"))", "device_asset_id": "x", "device_id": "y"}]}"#
            )
        }

        let result = try await env.engine().runAnalysis()

        #expect(result.counters.filesDiscovered == 5)
        #expect(result.counters.mediaFiles == 3)
        #expect(result.counters.deferredRecentlyModified == 1)
        #expect(result.counters.alreadySynced == 1)
        #expect(result.counters.toUpload == 1)
        #expect(result.counters.skippedRaw == 1)
        #expect(result.counters.skippedUnsupported == 1)
        #expect(result.counters.excluded == 1)
        #expect(result.counters.errors == 0)
        #expect(result.toUploadBytes == 4)
        #expect(result.skippedRootPaths.isEmpty)

        // Matched file recorded with its server asset id.
        let counts = try env.store.statusCounts()
        #expect(counts[.synced] == 1)
        #expect(counts[.pending] == 1)

        // The existence check sent exactly the two media checksums.
        let existBodies = env.bodies(for: "/api/assets/exist")
        #expect(existBodies.count == 1)
        let sent = try JSONSerialization.jsonObject(with: existBodies[0] ?? Data()) as? [String: Any]
        let sentChecksums = Set(sent?["checksums"] as? [String] ?? [])
        #expect(sentChecksums == Set([sha256B64("aaa"), sha256B64("bbbb")]))

        #expect(env.phases == [.preflight, .scanning, .hashing, .checking, .finished])
        #expect(try env.store.latestRuns()[0].outcome == .completed)
    }

    @Test func completedAnalysisIsRecordedForLaterUpload() async throws {
        defer { EngineTestStub.reset() }
        let env = try makeEnv()
        try writeAged(env.dir, "a.jpg", "aaa")
        installRoutes(env)

        #expect(try env.store.lastCompletedAnalysisRunId() == nil)
        let result = try await env.engine().runAnalysis()
        #expect(try env.store.lastCompletedAnalysisRunId() == result.runId)

        // A failed analysis never clobbers the reviewed plan's run.
        installRoutes(env, exist: { _ in .json(500, "{}") })
        await #expect(throws: (any Error).self) {
            _ = try await env.engine().runAnalysis()
        }
        #expect(try env.store.lastCompletedAnalysisRunId() == result.runId)
    }

    @Test func secondAnalysisRehashesNothing() async throws {
        defer { EngineTestStub.reset() }
        let env = try makeEnv()
        try writeAged(env.dir, "a.jpg", "aaa")
        try writeAged(env.dir, "sub/b.jpg", "bbbb")
        installRoutes(env) { _ in
            .json(
                200,
                #"{"assets": [{"id": "asset_a", "checksum": "\#(sha256B64("aaa"))", "device_asset_id": "x", "device_id": "y"}]}"#
            )
        }

        let hashCalls = AtomicCounter()
        func engine() -> SyncEngine {
            env.engine { config in
                let inner = config.hashFile
                config.hashFile = { url in
                    hashCalls.increment()
                    return try inner(url)
                }
            }
        }

        _ = try await engine().runAnalysis()
        #expect(hashCalls.count == 2)

        let second = try await engine().runAnalysis()
        #expect(hashCalls.count == 2)  // cache hit: nothing re-read
        #expect(second.counters.alreadySynced == 1)
        #expect(second.counters.toUpload == 1)
    }

    @Test func deletedFileIsPrunedOnNextAnalysis() async throws {
        defer { EngineTestStub.reset() }
        let env = try makeEnv()
        let doomed = try writeAged(env.dir, "a.jpg", "aaa")
        try writeAged(env.dir, "sub/b.jpg", "bbbb")
        installRoutes(env)

        _ = try await env.engine().runAnalysis()
        #expect(try env.store.statusCounts()[.pending] == 2)

        try FileManager.default.removeItem(at: doomed)
        let second = try await env.engine().runAnalysis()

        #expect(second.counters.filesDiscovered == 1)
        #expect(try env.store.statusCounts()[.pending] == 1)
        #expect(try env.store.hashedPendingFiles().map(\.relPath) == ["sub/b.jpg"])
    }

    @Test func deferredFileSurvivesPruneOnNextAnalysis() async throws {
        defer { EngineTestStub.reset() }
        let env = try makeEnv()
        let url = try writeAged(env.dir, "a.jpg", "aaa")
        installRoutes(env)

        _ = try await env.engine().runAnalysis()
        #expect(try env.store.statusCounts()[.pending] == 1)

        // The file is edited moments before the next run: deferred as
        // possibly mid-copy, but it was seen — its row must not be pruned.
        try Data("aaa-changed".utf8).write(to: url)
        let second = try await env.engine().runAnalysis()

        #expect(second.counters.deferredRecentlyModified == 1)
        #expect(try env.store.hashedPendingFiles().map(\.relPath) == ["a.jpg"])
    }

    @Test(.disabled(if: geteuid() == 0, "permission bits don't bind root"))
    func enumerationFailureSkipsPruning() async throws {
        defer { EngineTestStub.reset() }
        let env = try makeEnv()
        let doomed = try writeAged(env.dir, "a.jpg", "aaa")
        try writeAged(env.dir, "locked/b.jpg", "bbbb")
        installRoutes(env)

        _ = try await env.engine().runAnalysis()
        #expect(try env.store.statusCounts()[.pending] == 2)

        // With an unreadable subtree the scan is known incomplete, so even a
        // genuinely deleted file must keep its row until a clean scan.
        let lockedDir = env.dir.url.appendingPathComponent("locked")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: lockedDir.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: lockedDir.path
            )
        }
        try FileManager.default.removeItem(at: doomed)

        _ = try await env.engine().runAnalysis()
        #expect(try env.store.statusCounts()[.pending] == 2)
    }

    @Test func existenceCheckPagesThroughBatches() async throws {
        defer { EngineTestStub.reset() }
        let env = try makeEnv()
        try writeAged(env.dir, "a.jpg", "aaa")
        try writeAged(env.dir, "b.jpg", "bbbb")
        try writeAged(env.dir, "c.jpg", "ccccc")
        // Only the middle page's checksum matches, so a file leaves the
        // pending set between pages and the cursor must still not skip.
        installRoutes(env) { body in
            let sent = (try? JSONSerialization.jsonObject(with: body ?? Data())) as? [String: Any]
            let checksums = sent?["checksums"] as? [String] ?? []
            guard checksums.contains(sha256B64("bbbb")) else {
                return .json(200, #"{"assets": []}"#)
            }
            return .json(
                200,
                #"{"assets": [{"id": "asset_b", "checksum": "\#(sha256B64("bbbb"))", "device_asset_id": "x", "device_id": "y"}]}"#
            )
        }

        let result = try await env.engine { $0.existenceBatchSize = 1 }.runAnalysis()

        let sentBatches = try env.bodies(for: "/api/assets/exist").map { body in
            let sent = try JSONSerialization.jsonObject(with: body ?? Data()) as? [String: Any]
            return Set(sent?["checksums"] as? [String] ?? [])
        }
        #expect(sentBatches.count == 3)
        #expect(sentBatches.allSatisfy { $0.count == 1 })
        #expect(
            sentBatches.reduce(into: Set<String>()) { $0.formUnion($1) }
                == Set([sha256B64("aaa"), sha256B64("bbbb"), sha256B64("ccccc")])
        )
        #expect(result.counters.alreadySynced == 1)
        #expect(result.counters.toUpload == 2)
    }

    @Test func unreachableRootIsSkippedWithoutStateChanges() async throws {
        defer { EngineTestStub.reset() }
        let env = try makeEnv()
        try writeAged(env.dir, "a.jpg", "aaa")
        let missingPath = env.dir.url.path + "-does-not-exist"
        try env.store.addRoot(path: missingPath)
        installRoutes(env)

        let result = try await env.engine().runAnalysis()
        #expect(result.skippedRootPaths == [missingPath])
        #expect(result.counters.filesDiscovered == 1)
        #expect(try env.store.statusCounts()[.error] == nil)
    }

    @Test func allRootsUnreachableThrowsWithoutTouchingAnything() async throws {
        // Preflight fails before any network call, so no stub routes needed.
        let store = try Store.inMemory()
        let missing = "/nonexistent-root-\(UUID().uuidString)"
        try store.addRoot(path: missing)

        let client = GumnutClient(
            baseURL: URL(string: "https://gumnut.example.com")!,
            apiKey: "k", session: EngineTestStub.makeSession()
        )
        let engine = SyncEngine(store: store, client: client)
        await #expect(throws: SyncEngineError.noReachableRoots(skippedPaths: [missing])) {
            try await engine.runAnalysis()
        }
        #expect(try store.latestRuns().isEmpty)
    }

    // MARK: - Upload

    @Test func uploadSendsPendingFilesAndMergesRunCounters() async throws {
        defer { EngineTestStub.reset() }
        let env = try makeEnv()
        try writeAged(env.dir, "sub/b.jpg", "bbbb")
        installRoutes(env) { _ in
            .json(200, #"{"assets": []}"#)
        } upload: { _, _ in
            .json(201, assetJSON(id: "asset_b", checksumB64: sha256B64("bbbb")))
        }

        let engine = env.engine()
        let analysis = try await engine.runAnalysis()
        let result = try await engine.runUpload(continuing: analysis.runId)

        #expect(result.uploaded == 1)
        #expect(result.failed == 0)
        #expect(result.bytesUploaded == 4)
        #expect(!result.stoppedByQuota)

        let counts = try env.store.statusCounts()
        #expect(counts[.synced] == 1)
        #expect(counts[.pending] == nil)

        // Multipart identity fields: stable per-root/path asset id, per-install device id.
        let uploadCalls = env.calls.items.filter { $0.path == "/api/assets" }
        #expect(uploadCalls.count == 1)
        let contentType = uploadCalls[0].request.value(forHTTPHeaderField: "Content-Type") ?? ""
        let boundary = String(contentType.dropFirst("multipart/form-data; boundary=".count))
        let parts = parseMultipart(body: uploadCalls[0].body ?? Data(), boundary: boundary)
        let byName = Dictionary(
            uniqueKeysWithValues: parts.compactMap { part in part.name.map { ($0, part) } }
        )
        let expectedDeviceAssetId = "\(env.root.uuid):sub/b.jpg"
        #expect(byName["device_asset_id"]?.body == Data(expectedDeviceAssetId.utf8))
        #expect(byName["device_id"]?.body == Data(try env.store.deviceId().utf8))
        #expect(byName["asset_data"]?.body == Data("bbbb".utf8))

        let run = try #require(try env.store.run(id: analysis.runId))
        #expect(run.outcome == .completed)
        #expect(run.counters.uploaded == 1)
        #expect(run.counters.bytesUploaded == 4)
        #expect(run.counters.toUpload == 0)
    }

    @Test func uploadOnlyCoversRootsRecordedByTheAnalysis() async throws {
        defer { EngineTestStub.reset() }
        let env = try makeEnv()
        try writeAged(env.dir, "a.jpg", "aaa")
        installRoutes(env) { _ in
            .json(200, #"{"assets": []}"#)
        } upload: { _, _ in
            .json(201, assetJSON(id: "asset_a", checksumB64: sha256B64("aaa")))
        }

        let engine = env.engine()
        let analysis = try await engine.runAnalysis()

        // A second root — included, reachable, with a cached hashed-pending
        // file — appears after the review. The plan didn't cover it, so the
        // upload must not touch it.
        let otherDir = try TempDir()
        try otherDir.write("late.jpg", Data("zzzz".utf8))
        let other = try env.store.addRoot(path: otherDir.url.path)
        let record = try env.store.recordScannedFile(
            rootId: other.id!, relPath: "late.jpg", size: 4, mtime: 1,
            classification: .image, excluded: false, scanId: nil
        )
        try env.store.markHashed(
            record.id!, sha256: Data(SHA256.hash(data: Data("zzzz".utf8)))
        )
        // And the analyzed root is unchecked after review: its reviewed files
        // must still upload — the plan, not the live flags, is the scope.
        try env.store.setRootIncluded(env.root.id!, included: false)

        let result = try await engine.runUpload(continuing: analysis.runId)

        #expect(result.uploaded == 1)
        #expect(env.bodies(for: "/api/assets").count == 1)
        #expect(
            try env.store.hashedPendingFiles(rootIds: [other.id!]).map(\.relPath)
                == ["late.jpg"]
        )
    }

    @Test func uploadThrowsWhenRunRootsAreUnreachable() async throws {
        defer { EngineTestStub.reset() }
        let env = try makeEnv()
        try writeAged(env.dir, "a.jpg", "aaa")
        installRoutes(env)

        let engine = env.engine()
        let analysis = try await engine.runAnalysis()

        // The volume unmounts between review and clicking Upload: the run
        // must fail loudly, not complete with zero uploads.
        try FileManager.default.removeItem(at: env.dir.url)
        await #expect(
            throws: SyncEngineError.noReachableRoots(skippedPaths: [env.root.path])
        ) {
            _ = try await engine.runUpload(continuing: analysis.runId)
        }
    }

    @Test func uploadEmitsPerFileLifecycleEvents() async throws {
        defer { EngineTestStub.reset() }
        let env = try makeEnv()
        try writeAged(env.dir, "sub/b.jpg", "bbbb")
        installRoutes(env) { _ in
            .json(200, #"{"assets": []}"#)
        } upload: { _, _ in
            .json(201, assetJSON(id: "asset_b", checksumB64: sha256B64("bbbb")))
        }

        let engine = env.engine()
        let analysis = try await engine.runAnalysis()
        _ = try await engine.runUpload(continuing: analysis.runId)

        let events = env.events.items
        let startedIndex = try #require(
            events.firstIndex {
                if case .uploadFileStarted(let relPath, let path, let bytesTotal) = $0 {
                    return relPath == "sub/b.jpg" && path.hasSuffix("/sub/b.jpg")
                        && bytesTotal == 4
                }
                return false
            }
        )
        let finishedIndex = try #require(
            events.firstIndex {
                if case .uploadFileFinished(let relPath) = $0 { return relPath == "sub/b.jpg" }
                return false
            }
        )
        #expect(startedIndex < finishedIndex)
    }

    @Test func uploadFirewallBlockMarksErrorAndContinues() async throws {
        defer { EngineTestStub.reset() }
        let env = try makeEnv()
        try writeAged(env.dir, "a.jpg", "aaa")
        try writeAged(env.dir, "b.jpg", "bbbb")
        installRoutes(env) { _ in
            .json(200, #"{"assets": []}"#)
        } upload: { _, body in
            // The WAF objects to a.jpg's bytes; b.jpg passes.
            if let body, body.range(of: Data("a.jpg".utf8)) != nil {
                return StubURLProtocol.Response(
                    status: 403,
                    headers: ["Content-Type": "text/html"],
                    body: Data("<html>Blocked. Request ID: waf42</html>".utf8)
                )
            }
            return .json(201, assetJSON(id: "asset_b", checksumB64: sha256B64("bbbb")))
        }

        let engine = env.engine()
        let analysis = try await engine.runAnalysis()
        let result = try await engine.runUpload(continuing: analysis.runId)

        #expect(result.uploaded == 1)
        #expect(result.failed == 1)

        let counts = try env.store.statusCounts()
        #expect(counts[.synced] == 1)
        #expect(counts[.error] == 1)
        #expect(
            env.events.items.contains(
                .fileIssue(
                    relPath: "a.jpg",
                    message: "blocked by the server's firewall (HTTP 403, request id waf42)"
                )
            )
        )
    }

    @Test func uploadChecksumMismatchBecomesError() async throws {
        defer { EngineTestStub.reset() }
        let env = try makeEnv()
        try writeAged(env.dir, "b.jpg", "bbbb")
        installRoutes(env) { _ in
            .json(200, #"{"assets": []}"#)
        } upload: { _, _ in
            .json(201, assetJSON(id: "asset_b", checksumB64: sha256B64("corrupted")))
        }

        let engine = env.engine()
        let analysis = try await engine.runAnalysis()
        let result = try await engine.runUpload(continuing: analysis.runId)

        #expect(result.uploaded == 0)
        #expect(result.failed == 1)
        #expect(try env.store.statusCounts()[.error] == 1)
    }

    @Test func upload422MarksPermanentlyUnsupported() async throws {
        defer { EngineTestStub.reset() }
        let env = try makeEnv()
        try writeAged(env.dir, "weird.jpg", "not-actually-jpeg")
        installRoutes(env) { _ in
            .json(200, #"{"assets": []}"#)
        } upload: { _, _ in
            .json(422, #"{"detail": "File must be an image or video"}"#)
        }

        let engine = env.engine()
        let analysis = try await engine.runAnalysis()
        let result = try await engine.runUpload(continuing: analysis.runId)

        #expect(result.skippedUnsupported == 1)
        #expect(result.failed == 0)
        #expect(try env.store.statusCounts()[.skippedUnsupported] == 1)
    }

    @Test func uploadQuotaStopsRunAndLeavesFilesPending() async throws {
        defer { EngineTestStub.reset() }
        let env = try makeEnv()
        try writeAged(env.dir, "b.jpg", "bbbb")
        installRoutes(env) { _ in
            .json(200, #"{"assets": []}"#)
        } upload: { _, _ in
            .json(507, #"{"detail": "Storage limit exceeded"}"#)
        }

        let engine = env.engine()
        let analysis = try await engine.runAnalysis()
        let result = try await engine.runUpload(continuing: analysis.runId)

        #expect(result.stoppedByQuota)
        #expect(result.uploaded == 0)
        #expect(result.failed == 0)
        // Still pending: uploads once space exists, no data forgotten.
        #expect(try env.store.statusCounts()[.pending] == 1)
    }

    @Test func uploadUnauthorizedStopsRunAndLeavesFilesPending() async throws {
        defer { EngineTestStub.reset() }
        let env = try makeEnv()
        try writeAged(env.dir, "a.jpg", "aaa")
        try writeAged(env.dir, "b.jpg", "bbbb")
        installRoutes(env) { _ in
            .json(200, #"{"assets": []}"#)
        } upload: { _, _ in
            .json(401, #"{"detail": "bad key"}"#)
        }

        let engine = env.engine { $0.uploadConcurrency = 1 }
        let analysis = try await engine.runAnalysis()
        await #expect(throws: GumnutClientError.unauthorized(statusCode: 401, message: "bad key")) {
            _ = try await engine.runUpload(continuing: analysis.runId)
        }

        // Fatal stop: the second file is never attempted, and neither file is
        // marked error — they stay pending for a run with working credentials.
        #expect(env.calls.items.count { $0.path == "/api/assets" } == 1)
        let counts = try env.store.statusCounts()
        #expect(counts[.pending] == 2)
        #expect(counts[.error] == nil)
        #expect(try #require(try env.store.run(id: analysis.runId)).outcome == .failed)
    }

    @Test func uploadRetryExhaustionMarksFileError() async throws {
        defer { EngineTestStub.reset() }
        let env = try makeEnv()
        try writeAged(env.dir, "b.jpg", "bbbb")
        let attempts = AtomicCounter()
        installRoutes(env) { _ in
            .json(200, #"{"assets": []}"#)
        } upload: { _, _ in
            attempts.increment()
            return .json(502, #"{"error_code": "transient_storage_error"}"#)
        }

        let engine = env.engine()
        let analysis = try await engine.runAnalysis()
        let result = try await engine.runUpload(continuing: analysis.runId)

        // Exactly maxUploadAttempts tries, then the final error sticks.
        #expect(attempts.count == 3)
        #expect(result.uploaded == 0)
        #expect(result.failed == 1)
        #expect(try env.store.statusCounts()[.error] == 1)
    }

    @Test func uploadRetriesTransientErrorsThenSucceeds() async throws {
        defer { EngineTestStub.reset() }
        let env = try makeEnv()
        try writeAged(env.dir, "b.jpg", "bbbb")
        let attempts = AtomicCounter()
        installRoutes(env) { _ in
            .json(200, #"{"assets": []}"#)
        } upload: { _, _ in
            if attempts.increment() == 1 {
                return .json(502, #"{"error_code": "transient_storage_error"}"#)
            }
            return .json(201, assetJSON(id: "asset_b", checksumB64: sha256B64("bbbb")))
        }

        let engine = env.engine()
        let analysis = try await engine.runAnalysis()
        let result = try await engine.runUpload(continuing: analysis.runId)

        #expect(attempts.count == 2)
        #expect(result.uploaded == 1)
        #expect(result.failed == 0)
    }

    @Test func fileModifiedAfterAnalysisIsNeverUploadedBlind() async throws {
        defer { EngineTestStub.reset() }
        let env = try makeEnv()
        let url = try writeAged(env.dir, "b.jpg", "bbbb")
        installRoutes(env) { _ in
            .json(200, #"{"assets": []}"#)
        } upload: { _, _ in
            .json(201, assetJSON(id: "asset_b", checksumB64: sha256B64("bbbb")))
        }

        let engine = env.engine()
        let analysis = try await engine.runAnalysis()

        // The file changes between review and upload.
        try Data("bbbb-changed".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: url.path
        )

        let result = try await engine.runUpload(continuing: analysis.runId)
        #expect(result.uploaded == 0)
        #expect(result.skippedChanged == 1)
        #expect(env.calls.items.filter { $0.path == "/api/assets" }.isEmpty)
        // Reset for re-analysis: unhashed and pending again.
        #expect(try env.store.filesNeedingHash().count == 1)
    }

    // MARK: - Cancellation

    @Test func cancellationDuringHashingPersistsPartialProgress() async throws {
        defer { EngineTestStub.reset() }
        let env = try makeEnv()
        for index in 0..<12 {
            try writeAged(env.dir, "file-\(index).jpg", "contents-\(index)")
        }
        installRoutes(env)

        let hashCalls = AtomicCounter()
        let taskBox = TaskBox()
        let engine = env.engine { config in
            config.hashConcurrency = 2
            config.hashFile = { url in
                if hashCalls.increment() == 3 { taskBox.cancel() }
                Thread.sleep(forTimeInterval: 0.01)
                return try FileHasher.sha256(contentsOf: url)
            }
        }

        let task = Task { try await engine.runAnalysis() }
        taskBox.set(task)
        await #expect(throws: CancellationError.self) {
            try await task.value
        }

        #expect(try env.store.latestRuns()[0].outcome == .cancelled)
        let counts = try env.store.statusCounts()
        // Progress persisted, but the run did not finish all 12 files.
        #expect((counts[.pending] ?? 0) == 12)
        #expect(try env.store.filesNeedingHash().count > 0)
        #expect(try env.store.filesNeedingHash().count < 12)
    }
}
