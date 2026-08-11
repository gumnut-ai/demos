import Foundation
import Testing

@testable import UploaderCore

@Suite struct StoreRootTests {
    @Test func addRootNormalizesAndRejectsOverlap() throws {
        let store = try Store.inMemory()
        try store.addRoot(path: "/photos/main/")

        let roots = try store.allRoots()
        #expect(roots.map(\.path) == ["/photos/main"])
        #expect(roots[0].included)

        // Identical, child, and parent roots are all rejected.
        #expect(throws: StoreError.overlappingRoot(existingPath: "/photos/main")) {
            try store.addRoot(path: "/photos/main")
        }
        #expect(throws: StoreError.overlappingRoot(existingPath: "/photos/main")) {
            try store.addRoot(path: "/photos/main/2020")
        }
        #expect(throws: StoreError.overlappingRoot(existingPath: "/photos/main")) {
            try store.addRoot(path: "/photos")
        }
        // A sibling with a shared name prefix is not overlap.
        try store.addRoot(path: "/photos/main-archive")
        #expect(try store.allRoots().count == 2)
    }

    @Test func removeRootCascades() throws {
        let store = try Store.inMemory()
        let root = try store.addRoot(path: "/photos")
        try store.recordScannedFile(
            rootId: root.id!, relPath: "a.jpg", size: 10, mtime: 1000,
            classification: .image, excluded: false, scanId: nil
        )
        try store.addExclusion(rootId: root.id!, kind: .directory, relPath: "private")

        try store.removeRoot(root.id!)
        #expect(try store.allRoots().isEmpty)
        #expect(try store.statusCounts().isEmpty)
        #expect(try store.exclusions(forRoot: root.id!).isEmpty)
    }

    @Test func includedFlagPersists() throws {
        let store = try Store.inMemory()
        let root = try store.addRoot(path: "/photos")
        try store.setRootIncluded(root.id!, included: false)
        #expect(try store.allRoots()[0].included == false)
    }
}

@Suite struct StoreFileLifecycleTests {
    private func makeStoreWithRoot() throws -> (Store, Int64) {
        let store = try Store.inMemory()
        let root = try store.addRoot(path: "/photos")
        return (store, root.id!)
    }

    @Test func newFileStartsPendingAndUnhashed() throws {
        let (store, rootId) = try makeStoreWithRoot()
        let record = try store.recordScannedFile(
            rootId: rootId, relPath: "2020/a.jpg", size: 10, mtime: 1000,
            classification: .image, excluded: false, scanId: 1
        )
        #expect(record.status == .pending)
        #expect(record.sha256 == nil)
        #expect(record.parentDir == "2020")
        #expect(record.fileName == "a.jpg")
        #expect(try store.filesNeedingHash().count == 1)
    }

    @Test func rawAndUnsupportedAreSkipped() throws {
        let (store, rootId) = try makeStoreWithRoot()
        try store.recordScannedFile(
            rootId: rootId, relPath: "shot.nef", size: 10, mtime: 1, classification: .raw,
            excluded: false, scanId: nil
        )
        try store.recordScannedFile(
            rootId: rootId, relPath: "notes.txt", size: 10, mtime: 1,
            classification: .unsupported, excluded: false, scanId: nil
        )
        let counts = try store.statusCounts()
        #expect(counts[.skippedRaw] == 1)
        #expect(counts[.skippedUnsupported] == 1)
        #expect(try store.filesNeedingHash().isEmpty)
    }

    @Test func unchangedFileKeepsHashAndSyncState() throws {
        let (store, rootId) = try makeStoreWithRoot()
        let sha = Data(repeating: 1, count: 32)
        let record = try store.recordScannedFile(
            rootId: rootId, relPath: "a.jpg", size: 10, mtime: 1000,
            classification: .image, excluded: false, scanId: 1
        )
        try store.markHashed(record.id!, sha256: sha)
        try store.markSynced(assetIdsByChecksum: [sha: "asset_1"])

        let rescanned = try store.recordScannedFile(
            rootId: rootId, relPath: "a.jpg", size: 10, mtime: 1000,
            classification: .image, excluded: false, scanId: 2
        )
        #expect(rescanned.sha256 == sha)
        #expect(rescanned.status == .synced)
        #expect(rescanned.assetId == "asset_1")
        #expect(rescanned.lastSeenScanId == 2)
    }

    @Test func changedFileResetsHashAndSyncState() throws {
        let (store, rootId) = try makeStoreWithRoot()
        let sha = Data(repeating: 1, count: 32)
        let record = try store.recordScannedFile(
            rootId: rootId, relPath: "a.jpg", size: 10, mtime: 1000,
            classification: .image, excluded: false, scanId: 1
        )
        try store.markHashed(record.id!, sha256: sha)
        try store.markSynced(assetIdsByChecksum: [sha: "asset_1"])

        let rescanned = try store.recordScannedFile(
            rootId: rootId, relPath: "a.jpg", size: 10, mtime: 2000,
            classification: .image, excluded: false, scanId: 2
        )
        #expect(rescanned.sha256 == nil)
        #expect(rescanned.status == .pending)
        #expect(rescanned.assetId == nil)
    }

    @Test func exclusionKeepsCacheAndUnexclusionRestores() throws {
        let (store, rootId) = try makeStoreWithRoot()
        let sha = Data(repeating: 2, count: 32)
        let record = try store.recordScannedFile(
            rootId: rootId, relPath: "a.jpg", size: 10, mtime: 1000,
            classification: .image, excluded: false, scanId: 1
        )
        try store.markHashed(record.id!, sha256: sha)
        try store.markSynced(assetIdsByChecksum: [sha: "asset_1"])

        let excluded = try store.recordScannedFile(
            rootId: rootId, relPath: "a.jpg", size: 10, mtime: 1000,
            classification: .image, excluded: true, scanId: 2
        )
        #expect(excluded.status == .excluded)
        #expect(excluded.sha256 == sha)

        let restored = try store.recordScannedFile(
            rootId: rootId, relPath: "a.jpg", size: 10, mtime: 1000,
            classification: .image, excluded: false, scanId: 3
        )
        #expect(restored.status == .synced)
        #expect(restored.assetId == "asset_1")
    }

    @Test func unexcludedFileWithoutAssetReturnsToPending() throws {
        let (store, rootId) = try makeStoreWithRoot()
        try store.recordScannedFile(
            rootId: rootId, relPath: "b.jpg", size: 5, mtime: 500,
            classification: .image, excluded: true, scanId: 1
        )
        let restored = try store.recordScannedFile(
            rootId: rootId, relPath: "b.jpg", size: 5, mtime: 500,
            classification: .image, excluded: false, scanId: 2
        )
        #expect(restored.status == .pending)
    }

    @Test func erroredFileRetriesOnNextScan() throws {
        let (store, rootId) = try makeStoreWithRoot()
        let record = try store.recordScannedFile(
            rootId: rootId, relPath: "a.jpg", size: 10, mtime: 1000,
            classification: .image, excluded: false, scanId: 1
        )
        try store.markError(record.id!, message: "network dropped")

        let rescanned = try store.recordScannedFile(
            rootId: rootId, relPath: "a.jpg", size: 10, mtime: 1000,
            classification: .image, excluded: false, scanId: 2
        )
        #expect(rescanned.status == .pending)
        #expect(rescanned.errorMessage == nil)
    }

    @Test func localDuplicatesAllSyncFromOneMatch() throws {
        let (store, rootId) = try makeStoreWithRoot()
        let sha = Data(repeating: 3, count: 32)
        for relPath in ["a.jpg", "copies/a-copy.jpg"] {
            let record = try store.recordScannedFile(
                rootId: rootId, relPath: relPath, size: 10, mtime: 1000,
                classification: .image, excluded: false, scanId: 1
            )
            try store.markHashed(record.id!, sha256: sha)
        }
        try store.markSynced(assetIdsByChecksum: [sha: "asset_9"])
        let counts = try store.statusCounts()
        #expect(counts[.synced] == 2)
        #expect(try store.hashedPendingFiles().isEmpty)
    }

    @Test func markUploadedAndHashedPendingFlow() throws {
        let (store, rootId) = try makeStoreWithRoot()
        let record = try store.recordScannedFile(
            rootId: rootId, relPath: "a.jpg", size: 10, mtime: 1000,
            classification: .image, excluded: false, scanId: 1
        )
        try store.markHashed(record.id!, sha256: Data(repeating: 4, count: 32))

        let pending = try store.hashedPendingFiles()
        #expect(pending.map(\.id) == [record.id])

        try store.markUploaded(record.id!, assetId: "asset_2")
        #expect(try store.hashedPendingFiles().isEmpty)
        #expect(try store.statusCounts()[.synced] == 1)
    }
}

@Suite struct StoreExclusionTests {
    @Test func exclusionsAreIdempotentAndScoped() throws {
        let store = try Store.inMemory()
        let root = try store.addRoot(path: "/photos")
        try store.addExclusion(rootId: root.id!, kind: .directory, relPath: "private")
        try store.addExclusion(rootId: root.id!, kind: .directory, relPath: "private")
        try store.addExclusion(rootId: root.id!, kind: .file, relPath: "top/skip.jpg")

        let exclusions = try store.exclusions(forRoot: root.id!)
        #expect(exclusions.count == 2)

        try store.removeExclusion(rootId: root.id!, kind: .file, relPath: "top/skip.jpg")
        #expect(try store.exclusions(forRoot: root.id!).count == 1)
    }

    @Test func coversMatchesSubtreesAndExactFiles() {
        let dirExclusion = Exclusion(
            id: nil, rootId: 1, kind: .directory, relPath: "private", createdAt: Date()
        )
        #expect(dirExclusion.covers(relPath: "private"))
        #expect(dirExclusion.covers(relPath: "private/a.jpg"))
        #expect(dirExclusion.covers(relPath: "private/deep/b.jpg"))
        #expect(!dirExclusion.covers(relPath: "private-other/c.jpg"))

        let fileExclusion = Exclusion(
            id: nil, rootId: 1, kind: .file, relPath: "top/skip.jpg", createdAt: Date()
        )
        #expect(fileExclusion.covers(relPath: "top/skip.jpg"))
        #expect(!fileExclusion.covers(relPath: "top/skip.jpg.bak"))
    }
}

@Suite struct StoreSettingsTests {
    @Test func serverURLDefaultsToProduction() throws {
        let store = try Store.inMemory()
        #expect(try store.serverURL() == "https://api.gumnut.ai")
        #expect(try store.libraryId() == nil)
    }

    @Test func settingDefaultConfigurationDoesNotReset() throws {
        let store = try Store.inMemory()
        let didReset = try store.updateServerConfiguration(
            serverURL: Store.defaultServerURL, libraryId: nil
        )
        #expect(!didReset)
    }

    @Test func changingServerResetsSyncStateButKeepsHashes() throws {
        let store = try Store.inMemory()
        let root = try store.addRoot(path: "/photos")
        let sha = Data(repeating: 5, count: 32)
        let record = try store.recordScannedFile(
            rootId: root.id!, relPath: "a.jpg", size: 10, mtime: 1000,
            classification: .image, excluded: false, scanId: 1
        )
        try store.markHashed(record.id!, sha256: sha)
        try store.markSynced(assetIdsByChecksum: [sha: "asset_1"])

        let didReset = try store.updateServerConfiguration(
            serverURL: "https://gumnut.example.com", libraryId: nil
        )
        #expect(didReset)
        #expect(try store.serverURL() == "https://gumnut.example.com")

        let pending = try store.hashedPendingFiles()
        #expect(pending.count == 1)
        #expect(pending[0].sha256 == sha)
        #expect(pending[0].assetId == nil)

        // Same configuration again: no reset.
        #expect(
            try !store.updateServerConfiguration(
                serverURL: "https://gumnut.example.com", libraryId: nil
            )
        )
    }

    @Test func changingLibraryAlsoResets() throws {
        let store = try Store.inMemory()
        try store.updateServerConfiguration(serverURL: Store.defaultServerURL, libraryId: "lib_a")
        let didReset = try store.updateServerConfiguration(
            serverURL: Store.defaultServerURL, libraryId: "lib_b"
        )
        #expect(didReset)
        #expect(try store.libraryId() == "lib_b")
    }

    @Test func lastCompletedAnalysisRunSurvivesUntilServerChanges() throws {
        let store = try Store.inMemory()
        #expect(try store.lastCompletedAnalysisRunId() == nil)

        try store.setLastCompletedAnalysisRunId(42)
        #expect(try store.lastCompletedAnalysisRunId() == 42)

        // Same configuration: the reviewed plan stays valid.
        try store.updateServerConfiguration(serverURL: Store.defaultServerURL, libraryId: nil)
        #expect(try store.lastCompletedAnalysisRunId() == 42)

        // New destination: the plan was reviewed against the old one.
        try store.updateServerConfiguration(
            serverURL: "https://gumnut.example.com", libraryId: nil
        )
        #expect(try store.lastCompletedAnalysisRunId() == nil)
    }
}

@Suite struct StoreQueryTests {
    @Test func batchRecordingMatchesSingleRecording() throws {
        let store = try Store.inMemory()
        let root = try store.addRoot(path: "/photos")
        try store.recordScannedFiles(
            rootId: root.id!,
            files: [
                Store.ScannedFileInput(
                    relPath: "a.jpg", size: 1, mtime: 1, classification: .image, excluded: false
                ),
                Store.ScannedFileInput(
                    relPath: "b.nef", size: 2, mtime: 1, classification: .raw, excluded: false
                ),
                Store.ScannedFileInput(
                    relPath: "c.jpg", size: 3, mtime: 1, classification: .image, excluded: true
                ),
            ],
            scanId: nil
        )
        let counts = try store.statusCounts()
        #expect(counts[.pending] == 1)
        #expect(counts[.skippedRaw] == 1)
        #expect(counts[.excluded] == 1)
    }

    @Test func filesUnderDirectoryCoversSubtreeButNotSiblingPrefixes() throws {
        let store = try Store.inMemory()
        let root = try store.addRoot(path: "/photos")
        for relPath in ["2007/a.jpg", "2007/sub/b.jpg", "2007-extra/c.jpg", "top.jpg"] {
            try store.recordScannedFile(
                rootId: root.id!, relPath: relPath, size: 1, mtime: 1,
                classification: .image, excluded: false, scanId: nil
            )
        }

        let subtree = try store.files(underDirectory: "2007", rootId: root.id!)
        #expect(subtree.files.map(\.relPath) == ["2007/a.jpg", "2007/sub/b.jpg"])
        #expect(subtree.total == 2)

        let all = try store.files(underDirectory: "", rootId: root.id!)
        #expect(all.files.count == 4)
        #expect(all.total == 4)

        let limited = try store.files(underDirectory: "", rootId: root.id!, limit: 2)
        #expect(limited.files.count == 2)
        #expect(limited.total == 4)
    }

    @Test func hashedPendingCursorPaginationSkipsNothingAndTerminates() throws {
        let store = try Store.inMemory()
        let root = try store.addRoot(path: "/photos")
        for index in 0..<5 {
            let record = try store.recordScannedFile(
                rootId: root.id!, relPath: "f\(index).jpg", size: 10, mtime: 1,
                classification: .image, excluded: false, scanId: nil
            )
            try store.markHashed(record.id!, sha256: Data(repeating: UInt8(index), count: 32))
        }

        var seen: [String] = []
        var cursor: Store.PendingCursor?
        while true {
            let page = try store.hashedPendingFiles(after: cursor, limit: 2)
            if page.isEmpty { break }
            seen.append(contentsOf: page.map(\.relPath))
            cursor = page.last.map(Store.PendingCursor.init)
        }
        #expect(seen.count == 5)
        #expect(seen == seen.sorted())
    }

    @Test func hashedPendingFilesOrderByFolderThenName() throws {
        let store = try Store.inMemory()
        let root = try store.addRoot(path: "/photos")
        // Inserted in a deliberately non-alphabetical, non-filesystem order.
        let relPaths = [
            "zebra/z.jpg",
            "alpha/b.jpg",
            "b.jpg",  // root level
            "alpha/nested/c.jpg",
            "alpha/a.jpg",
            "a.jpg",  // root level
        ]
        for (index, relPath) in relPaths.enumerated() {
            let record = try store.recordScannedFile(
                rootId: root.id!, relPath: relPath, size: 10, mtime: 1,
                classification: .image, excluded: false, scanId: nil
            )
            try store.markHashed(record.id!, sha256: Data(repeating: UInt8(index), count: 32))
        }

        // Root-level files first (empty folder sorts first), then each folder
        // alphabetically, files alphabetical within a folder.
        #expect(
            try store.hashedPendingFiles().map(\.relPath) == [
                "a.jpg",
                "b.jpg",
                "alpha/a.jpg",
                "alpha/b.jpg",
                "alpha/nested/c.jpg",
                "zebra/z.jpg",
            ]
        )
    }

    @Test func pendingTotalsAndDuplicates() throws {
        let store = try Store.inMemory()
        let root = try store.addRoot(path: "/photos")
        let sha = Data(repeating: 9, count: 32)
        for (relPath, size) in [("a.jpg", Int64(10)), ("b.jpg", 20), ("copy-of-a.jpg", 10)] {
            let record = try store.recordScannedFile(
                rootId: root.id!, relPath: relPath, size: size, mtime: 1,
                classification: .image, excluded: false, scanId: nil
            )
            let digest = relPath == "b.jpg" ? Data(repeating: 8, count: 32) : sha
            try store.markHashed(record.id!, sha256: digest)
        }
        let totals = try store.pendingUploadTotals()
        #expect(totals.files == 3)
        #expect(totals.bytes == 40)
        #expect(try store.duplicateFileCount() == 1)
        #expect(try store.pendingHashTotals() == (0, 0))
    }

    @Test func deviceIdIsStable() throws {
        let store = try Store.inMemory()
        let first = try store.deviceId()
        #expect(try store.deviceId() == first)
        #expect(!first.isEmpty)
    }

    @Test func markSkippedUnsupportedIsPermanentStatus() throws {
        let store = try Store.inMemory()
        let root = try store.addRoot(path: "/photos")
        let record = try store.recordScannedFile(
            rootId: root.id!, relPath: "odd.jpg", size: 1, mtime: 1,
            classification: .image, excluded: false, scanId: nil
        )
        try store.markSkippedUnsupported(record.id!, message: "rejected")
        #expect(try store.statusCounts()[.skippedUnsupported] == 1)
    }
}

@Suite struct StoreRunTests {
    @Test func runLifecycleRoundTripsCounters() throws {
        let store = try Store.inMemory()
        let run = try store.beginRun(rootIds: [1, 2])
        #expect(run.outcome == .running)
        #expect(run.rootIds == [1, 2])

        var counters = RunCounters()
        counters.filesDiscovered = 140_000
        counters.uploaded = 42
        counters.bytesUploaded = 5_000_000_000
        try store.finishRun(run.id!, outcome: .completed, counters: counters)

        let latest = try store.latestRuns()
        #expect(latest.count == 1)
        #expect(latest[0].outcome == .completed)
        #expect(latest[0].counters == counters)
        #expect(latest[0].finishedAt != nil)
    }

    @Test func parentDirectoryHelper() {
        #expect(Store.parentDirectory(of: "a.jpg") == "")
        #expect(Store.parentDirectory(of: "x/a.jpg") == "x")
        #expect(Store.parentDirectory(of: "x/y/a.jpg") == "x/y")
    }

    @Test func updateRootPathPersistsAndGuardsCollisions() throws {
        let store = try Store.inMemory()
        let a = try store.addRoot(path: "/photos/a")
        _ = try store.addRoot(path: "/photos/b")

        #expect(try store.updateRootPath(a.id!, path: "/photos/a-moved/") == true)
        #expect(try store.allRoots().map(\.path) == ["/photos/a-moved", "/photos/b"])

        // Overlap with another root leaves the row unchanged.
        #expect(try store.updateRootPath(a.id!, path: "/photos/b") == false)
        #expect(try store.updateRootPath(a.id!, path: "/photos/b/sub") == false)
        #expect(try store.allRoots().map(\.path) == ["/photos/a-moved", "/photos/b"])

        // Unchanged path is a successful no-op.
        #expect(try store.updateRootPath(a.id!, path: "/photos/a-moved") == true)
    }

    @Test func addRootRejectsSymlinkAliasOfExistingRoot() throws {
        let store = try Store.inMemory()
        let dir = try TempDir()
        let real = dir.url.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let alias = dir.url.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)

        try store.addRoot(path: real.path)
        #expect(throws: StoreError.self) {
            try store.addRoot(path: alias.path)
        }
    }

    @Test func pruneVanishedFilesScopesToRootAndHonorsMarkSeen() throws {
        let store = try Store.inMemory()
        let rootA = try store.addRoot(path: "/photos/a")
        let rootB = try store.addRoot(path: "/photos/b")
        func record(_ rootId: Int64, _ relPath: String, scanId: Int64?) throws {
            try store.recordScannedFile(
                rootId: rootId, relPath: relPath, size: 1, mtime: 1,
                classification: .image, excluded: false, scanId: scanId
            )
        }
        try record(rootA.id!, "seen.jpg", scanId: 7)
        try record(rootA.id!, "deferred.jpg", scanId: 6)
        try record(rootA.id!, "vanished.jpg", scanId: nil)
        try record(rootB.id!, "other-root.jpg", scanId: 1)
        try store.markSeen(rootId: rootA.id!, relPaths: ["deferred.jpg"], scanId: 7)

        let pruned = try store.pruneVanishedFiles(rootId: rootA.id!, scanId: 7)

        #expect(pruned == 1)
        let remainingA = try store.files(underDirectory: "", rootId: rootA.id!)
        #expect(remainingA.files.map(\.relPath) == ["deferred.jpg", "seen.jpg"])
        let remainingB = try store.files(underDirectory: "", rootId: rootB.id!)
        #expect(remainingB.files.map(\.relPath) == ["other-root.jpg"])
    }
}
