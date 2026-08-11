import Foundation
import Observation
import UploaderCore

/// Main-actor view model owning the store, settings, and engine lifecycle.
@MainActor
@Observable
final class AppModel {
    private(set) var store: Store?
    private(set) var storeError: String?

    // MARK: Settings

    var apiKey: String = ""
    var serverURLString: String = Store.defaultServerURL
    var selectedLibraryId: String?
    private(set) var libraries: [GumnutLibrary] = []
    var hashConcurrency = 2
    var uploadConcurrency = 3

    enum ConnectionStatus: Equatable {
        case unknown, testing
        case ok(userId: String)
        case failed(String)
    }
    private(set) var connectionStatus: ConnectionStatus = .unknown

    // MARK: Library state

    private(set) var roots: [Root] = []
    private(set) var counts: [FileStatus: Int] = [:]
    private(set) var pendingFiles = 0
    private(set) var pendingBytes: Int64 = 0
    private(set) var runs: [RunRecord] = []
    private(set) var planTree: PlanDirectoryNode?
    private(set) var directoryFiles: [FileRecord] = []
    private(set) var directoryFilesTotal = 0
    private(set) var exclusions: [Exclusion] = []
    var selectedRootId: Int64? {
        didSet { refreshPlan() }
    }
    var selectedDirectory: String? {
        didSet { refreshDirectoryFiles() }
    }

    // MARK: Run state

    private(set) var isRunning = false
    private(set) var phase: SyncPhase?
    private(set) var statusLine = ""
    private(set) var fractionComplete: Double?
    private(set) var issues: [String] = []
    private(set) var lastAnalysis: AnalysisResult?
    private(set) var lastUpload: UploadResult?
    var alertMessage: String?

    /// One file currently in flight, for the Details popover.
    struct ActiveUpload: Identifiable, Equatable {
        let relPath: String
        let fileURL: URL
        var bytesSent: Int64 = 0
        var bytesTotal: Int64

        var id: String { relPath }
        var fileName: String { (relPath as NSString).lastPathComponent }
        var fraction: Double? {
            bytesTotal > 0 ? min(1, Double(bytesSent) / Double(bytesTotal)) : nil
        }
    }
    private(set) var activeUploads: [ActiveUpload] = []
    private(set) var uploadSpeedText: String?
    /// (time, cumulative bytes) samples over a short window for the speed
    /// readout; per-chunk deltas are too noisy to show directly.
    private var speedSamples: [(time: Date, bytes: Int64)] = []
    private var speedCumulativeBytes: Int64 = 0

    private var runTask: Task<Void, Never>?
    private var activityToken: NSObjectProtocol?
    private var liveRefreshScheduled = false

    init() {
        do {
            let supportDir = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            ).appending(path: "GumnutUploader", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(
                at: supportDir, withIntermediateDirectories: true
            )
            let store = try Store.onDisk(at: supportDir.appending(path: "state.db").path)
            self.store = store
            serverURLString = (try? store.serverURL()) ?? Store.defaultServerURL
            apiKey = KeychainStore.loadAPIKey(server: serverURLString) ?? ""
            selectedLibraryId = try? store.libraryId()
            hashConcurrency = (try? store.hashConcurrency()).flatMap { $0 } ?? 2
            uploadConcurrency = (try? store.uploadConcurrency()).flatMap { $0 } ?? 3
            refresh()
        } catch {
            storeError = "Could not open the state database: \(error.localizedDescription)"
        }
    }

    // MARK: - Refresh

    func refresh() {
        guard let store else { return }
        do {
            roots = try store.allRoots()
            if selectedRootId == nil || !roots.contains(where: { $0.id == selectedRootId }) {
                selectedRootId = roots.first?.id
            }
            counts = try store.statusCounts()
            // The upload button's promise must match what runUpload will
            // actually send: scope pending totals to the reviewed run's roots
            // when a plan exists (cached pending files under other roots are
            // not part of it).
            let planRunId =
                lastAnalysis?.runId ?? ((try? store.lastCompletedAnalysisRunId()) ?? nil)
            let planRun = planRunId.flatMap { ((try? store.run(id: $0)) ?? nil) }
            let totals = try store.pendingUploadTotals(rootIds: planRun?.rootIds)
            pendingFiles = totals.files
            pendingBytes = totals.bytes
            runs = try store.latestRuns(limit: 100)
            restoreLastAnalysisIfNeeded()
            refreshPlan()
        } catch {
            alertMessage = "Could not read local state: \(error.localizedDescription)"
        }
    }

    /// The reviewed plan survives restarts: the pending files live in the
    /// database, so an analysis run that completed before the app quit can
    /// still be uploaded without re-analyzing. The store clears the saved run
    /// id whenever the server or library changes.
    private func restoreLastAnalysisIfNeeded() {
        guard lastAnalysis == nil, let store,
            let runId = try? store.lastCompletedAnalysisRunId(),
            let run = try? store.run(id: runId)
        else { return }
        lastAnalysis = AnalysisResult(
            runId: runId,
            counters: run.counters,
            toUploadBytes: pendingBytes,
            skippedRootPaths: []
        )
    }

    private func refreshPlan() {
        guard let store, let rootId = selectedRootId,
            let root = roots.first(where: { $0.id == rootId })
        else {
            planTree = nil
            exclusions = []
            directoryFiles = []
            return
        }
        do {
            let rows = try store.directoryStatistics(rootId: rootId)
            let rootName = (root.path as NSString).lastPathComponent
            planTree = rows.isEmpty ? nil : PlanTree.build(from: rows, rootName: rootName)
            exclusions = try store.exclusions(forRoot: rootId)
            refreshDirectoryFiles()
        } catch {
            alertMessage = "Could not build the plan: \(error.localizedDescription)"
        }
    }

    private func refreshDirectoryFiles() {
        guard let store, let rootId = selectedRootId, let directory = selectedDirectory else {
            directoryFiles = []
            directoryFilesTotal = 0
            return
        }
        let result =
            (try? store.files(underDirectory: directory, rootId: rootId))
            ?? (files: [], total: 0)
        directoryFiles = result.files
        directoryFilesTotal = result.total
    }

    // MARK: - Roots

    func addRoot(url: URL) {
        guard let store else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let bookmark = try url.bookmarkData(
                options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil
            )
            let root = try store.addRoot(path: url.path, bookmark: bookmark)
            selectedRootId = root.id
            refresh()
        } catch StoreError.overlappingRoot(let existingPath) {
            alertMessage =
                "That folder overlaps the already-added folder \(existingPath). "
                + "Nested folders would track the same files twice."
        } catch {
            alertMessage = "Could not add folder: \(error.localizedDescription)"
        }
    }

    /// Removes only the app's records for this root — never files on disk.
    func removeRoot(_ rootId: Int64) {
        guard let store else { return }
        do {
            try store.removeRoot(rootId)
            if selectedRootId == rootId { selectedRootId = nil }
            refresh()
        } catch {
            alertMessage = "Could not remove folder: \(error.localizedDescription)"
        }
    }

    func setRootIncluded(_ rootId: Int64, included: Bool) {
        guard let store else { return }
        try? store.setRootIncluded(rootId, included: included)
        refresh()
    }

    // MARK: - Exclusions

    func isDirectoryExcluded(_ relPath: String) -> Bool {
        exclusions.contains { $0.kind == .directory && $0.relPath == relPath }
    }

    func isFileExcluded(_ relPath: String) -> Bool {
        exclusions.contains { $0.kind == .file && $0.relPath == relPath }
    }

    func setExcluded(kind: Exclusion.Kind, relPath: String, excluded: Bool) {
        guard let store, let rootId = selectedRootId else { return }
        do {
            try store.setExcluded(
                rootId: rootId, kind: kind, relPath: relPath, excluded: excluded
            )
            refresh()
        } catch {
            alertMessage = "Could not update exclusion: \(error.localizedDescription)"
        }
    }

    // MARK: - Settings

    func saveAPIKey() {
        if !KeychainStore.saveAPIKey(apiKey, server: serverURLString) {
            alertMessage = "Could not save the API key to the keychain."
        }
        connectionStatus = .unknown
    }

    /// Validates and applies a server URL + target library. The applied
    /// values (`serverURLString`, `selectedLibraryId`) — what runs actually
    /// use — only ever change here, together with the store's sync-state
    /// reset, so an edited-but-unapplied destination can never be uploaded
    /// to against the old destination's sync state.
    func applyServerSettings(serverURL candidate: String, libraryId: String?) {
        guard let store else { return }
        let normalized = Self.normalizeServerURL(candidate)
        guard let url = URL(string: normalized),
            url.scheme == "https" || url.scheme == "http"
        else {
            alertMessage = "The server URL must be a valid http(s) URL."
            return
        }
        // A library id is only meaningful on the server it was listed from;
        // changing servers drops it until the user picks one from the new
        // server's list.
        let library = normalized == serverURLString ? libraryId : nil
        do {
            let didReset = try store.updateServerConfiguration(
                serverURL: normalized, libraryId: library
            )
            serverURLString = normalized
            selectedLibraryId = library
            // Every server has its own API key: switch to the new server's
            // saved key, or to none (the app returns to setup) if it has
            // never been entered.
            apiKey = KeychainStore.loadAPIKey(server: normalized) ?? ""
            libraries = []
            if didReset {
                // The reviewed plan belonged to the old destination.
                lastAnalysis = nil
                lastUpload = nil
                alertMessage =
                    "Server or library changed. Sync state was reset (file hashes kept) — "
                    + "run Analyze to rebuild it against the new destination."
            }
            connectionStatus = .unknown
            refresh()
        } catch {
            alertMessage = "Could not save server settings: \(error.localizedDescription)"
        }
    }

    /// Trims whitespace and trailing slashes so equivalent spellings of a
    /// server URL share one settings value and one keychain slot.
    static func normalizeServerURL(_ raw: String) -> String {
        var url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while url.count > 1 && url.hasSuffix("/") {
            url.removeLast()
        }
        return url
    }

    func savePerformanceSettings() {
        guard let store else { return }
        try? store.setHashConcurrency(hashConcurrency)
        try? store.setUploadConcurrency(uploadConcurrency)
    }

    func testConnection() async {
        guard let client = makeClient() else {
            connectionStatus = .failed("Enter a server URL and API key first.")
            return
        }
        connectionStatus = .testing
        do {
            let user = try await client.currentUser()
            do {
                libraries = try await client.libraries()
            } catch {
                // The key works but the picker would be silently empty — say
                // why, instead of looking like an account with no libraries.
                alertMessage =
                    "Connected, but the library list could not be loaded: "
                    + Self.describe(error)
            }
            connectionStatus = .ok(userId: user.id)
        } catch {
            connectionStatus = .failed(Self.describe(error))
        }
    }

    private func makeClient() -> GumnutClient? {
        guard let url = URL(string: serverURLString), !apiKey.isEmpty else { return nil }
        return GumnutClient(baseURL: url, apiKey: apiKey)
    }

    // MARK: - Runs

    var canAnalyze: Bool {
        !isRunning && store != nil && !apiKey.isEmpty && roots.contains(where: \.included)
    }

    var canUpload: Bool {
        !isRunning && lastAnalysis != nil && pendingFiles > 0
    }

    func analyze() {
        startRun { engine in
            let result = try await engine.runAnalysis()
            await MainActor.run {
                self.lastAnalysis = result
                for path in result.skippedRootPaths {
                    self.issues.append("Skipped unreachable folder: \(path)")
                }
            }
        }
    }

    func upload() {
        guard let runId = lastAnalysis?.runId else {
            alertMessage = "Run Analyze first — uploads always follow a reviewed plan."
            return
        }
        // The upload covers the run's recorded roots regardless of the live
        // included flags, so sandbox access must too — a root unchecked after
        // review would otherwise be unreadable and silently dropped.
        let runRootIds = ((try? store?.run(id: runId))?.map(\.rootIds)).map(Set.init)
        startRun(accessing: { root in
            runRootIds.map { root.id.map($0.contains) ?? false } ?? root.included
        }) { engine in
            let result = try await engine.runUpload(continuing: runId)
            await MainActor.run {
                self.lastUpload = result
                if result.stoppedByQuota {
                    self.alertMessage =
                        "The Gumnut storage quota is full. Uploaded what fit; "
                        + "the rest stays queued for a later run."
                }
            }
        }
    }

    func cancel() {
        runTask?.cancel()
    }

    private func startRun(
        accessing selection: ((Root) -> Bool)? = nil,
        _ operation: @escaping @Sendable (SyncEngine) async throws -> Void
    ) {
        guard !isRunning, let store else { return }
        guard let client = makeClient() else {
            alertMessage = "Set the server URL and API key in Settings first."
            return
        }
        isRunning = true
        issues = []
        statusLine = "Starting…"
        fractionComplete = nil
        activeUploads = []
        uploadSpeedText = nil
        speedSamples = []
        speedCumulativeBytes = 0

        var config = SyncEngineConfiguration()
        config.hashConcurrency = hashConcurrency
        config.uploadConcurrency = uploadConcurrency
        let engine = SyncEngine(store: store, client: client, configuration: config) { event in
            Task { @MainActor [weak self] in self?.handle(event) }
        }

        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Syncing photos to Gumnut"
        )
        let accessedURLs = startAccessingRoots(selection ?? { $0.included })

        runTask = Task {
            do {
                try await operation(engine)
            } catch is CancellationError {
                self.statusLine = "Cancelled — progress is saved."
            } catch {
                self.alertMessage = Self.describe(error)
                self.statusLine = "Stopped."
            }
            for url in accessedURLs {
                url.stopAccessingSecurityScopedResource()
            }
            if let token = self.activityToken {
                ProcessInfo.processInfo.endActivity(token)
                self.activityToken = nil
            }
            self.isRunning = false
            self.activeUploads = []
            self.uploadSpeedText = nil
            self.refresh()
        }
    }

    /// Resolves security-scoped bookmarks for the selected roots, refreshing
    /// any stale ones. Returns the URLs that must be released after the run.
    private func startAccessingRoots(_ selection: (Root) -> Bool) -> [URL] {
        var accessed: [URL] = []
        for root in roots where selection(root) {
            guard let bookmark = root.bookmark else { continue }
            var isStale = false
            guard
                let url = try? URL(
                    resolvingBookmarkData: bookmark, options: .withSecurityScope,
                    relativeTo: nil, bookmarkDataIsStale: &isStale
                )
            else {
                issues.append("Could not restore access to \(root.path); re-add the folder.")
                continue
            }
            if url.startAccessingSecurityScopedResource() {
                accessed.append(url)
            }
            // The bookmark tracks moves, renames, and remounts; keep the
            // stored path pointing where it actually resolved so preflight
            // probes the real location instead of a stale one. (updateRootPath
            // canonicalizes and no-ops when unchanged or colliding.)
            if url.path != root.path, let id = root.id {
                let updated = (try? store?.updateRootPath(id, path: url.path)) ?? false
                if updated != true {
                    issues.append(
                        "Folder moved to \(url.path), which overlaps another added "
                            + "folder — remove and re-add it."
                    )
                }
            }
            if isStale, let id = root.id,
                let fresh = try? url.bookmarkData(
                    options: .withSecurityScope, includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
            {
                try? store?.updateRootBookmark(id, bookmark: fresh)
            }
        }
        return accessed
    }

    /// Aggregate upload speed over the last ~5 seconds of byte deltas.
    private func recordSpeedSample(delta: Int64) {
        speedCumulativeBytes += delta
        let now = Date()
        speedSamples.append((time: now, bytes: speedCumulativeBytes))
        speedSamples.removeAll { now.timeIntervalSince($0.time) > 5 }
        guard let first = speedSamples.first else { return }
        let window = now.timeIntervalSince(first.time)
        guard window >= 0.5 else { return }
        let bytesPerSecond = Double(speedCumulativeBytes - first.bytes) / window
        uploadSpeedText = Self.bytesText(Int64(bytesPerSecond)) + "/s"
    }

    /// Progress events arrive per file; requerying the store that often would
    /// swamp the main thread. Coalesce to at most one refresh per interval —
    /// the end-of-run refresh covers whatever lands after the last one.
    private func scheduleLiveRefresh() {
        guard !liveRefreshScheduled else { return }
        liveRefreshScheduled = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(750))
            liveRefreshScheduled = false
            if isRunning { refresh() }
        }
    }

    private func handle(_ event: SyncEvent) {
        switch event {
        case .phase(let phase):
            self.phase = phase
            statusLine = Self.phaseDescription(phase)
            if phase != .hashing && phase != .uploading {
                fractionComplete = nil
            }
        case .scanProgress(let discovered):
            statusLine = "Scanning — \(Self.pluralize(discovered, "file")) found"
            scheduleLiveRefresh()
        case .hashProgress(let files, let totalFiles, let bytes, let totalBytes):
            fractionComplete = totalBytes > 0 ? Double(bytes) / Double(totalBytes) : nil
            statusLine =
                "Hashing \(files.formatted()) of \(Self.pluralize(totalFiles, "file")) "
                + "(\(Self.bytesText(bytes)) of \(Self.bytesText(totalBytes)))"
        case .checkProgress(let checked, let matched):
            statusLine =
                "Checking against Gumnut — \(matched.formatted()) of "
                + "\(checked.formatted()) already there"
            scheduleLiveRefresh()
        case .uploadProgress(let completed, let total, let bytes):
            fractionComplete = total > 0 ? Double(completed) / Double(total) : nil
            statusLine =
                "Uploading \(completed.formatted()) of \(total.formatted()) "
                + "(\(Self.bytesText(bytes)))"
            scheduleLiveRefresh()
        case .uploadFileStarted(let relPath, let path, let bytesTotal):
            activeUploads.append(
                ActiveUpload(
                    relPath: relPath, fileURL: URL(fileURLWithPath: path), bytesTotal: bytesTotal
                )
            )
        case .uploadFileProgress(let relPath, let bytesSent, let bytesTotal):
            if let index = activeUploads.firstIndex(where: { $0.relPath == relPath }) {
                // A retried upload restarts its byte count; don't let the
                // negative delta corrupt the speed window.
                let delta = bytesSent - activeUploads[index].bytesSent
                if delta > 0 { recordSpeedSample(delta: delta) }
                activeUploads[index].bytesSent = bytesSent
                activeUploads[index].bytesTotal = bytesTotal
            }
        case .uploadFileFinished(let relPath):
            activeUploads.removeAll { $0.relPath == relPath }
        case .fileIssue(let relPath, let message):
            issues.append("\(relPath): \(message)")
            if issues.count > 200 {
                issues.removeFirst(issues.count - 200)
            }
        }
    }

    // MARK: - Formatting

    static func phaseDescription(_ phase: SyncPhase) -> String {
        switch phase {
        case .preflight: "Checking folders and connection…"
        case .scanning: "Scanning folders…"
        case .hashing: "Hashing files…"
        case .checking: "Checking what Gumnut already has…"
        case .uploading: "Uploading…"
        case .finished: "Done."
        }
    }

    static func bytesText(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }

    /// "1 error" / "2 errors" — keeps an interpolated count grammatical at the
    /// singular boundary. `plural` defaults to `singular + "s"`.
    static func pluralize(_ count: Int, _ singular: String, _ plural: String? = nil) -> String {
        let noun = count == 1 ? singular : (plural ?? singular + "s")
        return "\(count.formatted()) \(noun)"
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case let engineError as SyncEngineError:
            switch engineError {
            case .noIncludedRoots:
                return "No folders are included in the scan. Add or check a folder first."
            case .noReachableRoots(let paths):
                return "No included folder is reachable right now (is the volume mounted?): "
                    + paths.joined(separator: ", ")
            case .unreachableRunRoots(let paths):
                return "Some folders from the reviewed plan aren't reachable right now "
                    + "(is the volume mounted?): " + paths.joined(separator: ", ")
                    + ". Nothing was uploaded — reconnect the volume or run Analyze again."
            case .runNotFound:
                return "The analysis this upload was based on is gone. Run Analyze again."
            }
        case let clientError as GumnutClientError:
            switch clientError {
            case .unauthorized(let statusCode, let message):
                return "Refused as unauthorized (HTTP \(statusCode)): "
                    + (message ?? "no detail")
                    + " — if this points at the API key, check it in Settings."
            case .edgeBlocked(_, let requestId):
                return "The server's web application firewall blocked the request "
                    + "(request ID \(requestId ?? "unknown")). This is a server-side "
                    + "firewall rule, not an API key problem."
            case .storageQuotaExceeded:
                return "The Gumnut storage quota is full."
            case .rateLimited:
                return "The server is rate limiting; try again shortly."
            default:
                return "Server error: \(clientError)"
            }
        default:
            return error.localizedDescription
        }
    }
}
