import Foundation
import Testing

@testable import UploaderCore

@Suite struct PlanTreeTests {
    @Test func buildsHierarchyWithSubtreeRollups() {
        let rows: [Store.DirectoryStatusRow] = [
            .init(parentDir: "", status: .pending, count: 2, bytes: 100),
            .init(parentDir: "a", status: .pending, count: 1, bytes: 50),
            .init(parentDir: "a", status: .synced, count: 3, bytes: 999),
            .init(parentDir: "a/b", status: .skippedRaw, count: 1, bytes: 10),
            .init(parentDir: "c", status: .excluded, count: 4, bytes: 0),
        ]
        let root = PlanTree.build(from: rows, rootName: "Photos")

        #expect(root.name == "Photos")
        #expect(root.count(.pending) == 3)
        #expect(root.count(.synced) == 3)
        #expect(root.count(.skippedRaw) == 1)
        #expect(root.count(.excluded) == 4)
        #expect(root.pendingBytes == 150)
        #expect(root.totalFiles == 11)

        let children = root.children ?? []
        #expect(children.map(\.name) == ["a", "c"])

        let a = children[0]
        #expect(a.id == "a")
        #expect(a.count(.pending) == 1)
        #expect(a.count(.synced) == 3)
        #expect(a.count(.skippedRaw) == 1)  // rolled up from a/b
        #expect(a.pendingBytes == 50)
        #expect(a.children?.map(\.id) == ["a/b"])
        #expect(a.children?[0].children == nil)

        let c = children[1]
        #expect(c.count(.excluded) == 4)
        #expect(c.children == nil)
    }

    @Test func deepPathsCreateIntermediateNodes() {
        let rows: [Store.DirectoryStatusRow] = [
            .init(parentDir: "x/y/z", status: .pending, count: 1, bytes: 5)
        ]
        let root = PlanTree.build(from: rows, rootName: "R")
        let x = root.children?[0]
        let y = x?.children?[0]
        let z = y?.children?[0]
        #expect(x?.id == "x")
        #expect(y?.id == "x/y")
        #expect(z?.id == "x/y/z")
        // Intermediate directories with no direct files still roll up.
        #expect(x?.count(.pending) == 1)
        #expect(y?.pendingBytes == 5)
    }

    @Test func pathChainHandlesEdges() {
        #expect(PlanTree.pathChain("") == [""])
        #expect(PlanTree.pathChain("a") == ["", "a"])
        #expect(PlanTree.pathChain("a/b/c") == ["", "a", "a/b", "a/b/c"])
    }
}

@Suite struct StoreExclusionToggleTests {
    private func makeFixture() throws -> (Store, Int64) {
        let store = try Store.inMemory()
        let root = try store.addRoot(path: "/photos")
        let rootId = root.id!
        let files: [(String, MediaClassification)] = [
            ("a.jpg", .image),
            ("sub/b.jpg", .image),
            ("sub/c.nef", .raw),
            ("sub/deep/d.jpg", .image),
        ]
        for (relPath, classification) in files {
            try store.recordScannedFile(
                rootId: rootId, relPath: relPath, size: 10, mtime: 1,
                classification: classification, excluded: false, scanId: nil
            )
        }
        // b.jpg is synced with a known asset.
        let b = try store.recordScannedFile(
            rootId: rootId, relPath: "sub/b.jpg", size: 10, mtime: 1,
            classification: .image, excluded: false, scanId: nil
        )
        try store.markHashed(b.id!, sha256: Data(repeating: 1, count: 32))
        try store.markSynced(assetIdsByChecksum: [Data(repeating: 1, count: 32): "asset_b"])
        return (store, rootId)
    }

    @Test func excludingDirectoryCoversSubtreeImmediately() throws {
        let (store, rootId) = try makeFixture()
        try store.setExcluded(rootId: rootId, kind: .directory, relPath: "sub", excluded: true)

        let counts = try store.statusCounts()
        #expect(counts[.excluded] == 3)
        #expect(counts[.pending] == 1)  // a.jpg untouched
        #expect(counts[.synced] == nil)
    }

    @Test func unexcludingRestoresFromCacheRespectingNestedExclusions() throws {
        let (store, rootId) = try makeFixture()
        try store.setExcluded(rootId: rootId, kind: .directory, relPath: "sub", excluded: true)
        try store.setExcluded(
            rootId: rootId, kind: .directory, relPath: "sub/deep", excluded: true
        )
        try store.setExcluded(rootId: rootId, kind: .directory, relPath: "sub", excluded: false)

        let counts = try store.statusCounts()
        // b.jpg back to synced (asset known), c.nef back to skippedRaw,
        // d.jpg still excluded under sub/deep.
        #expect(counts[.synced] == 1)
        #expect(counts[.skippedRaw] == 1)
        #expect(counts[.excluded] == 1)
        #expect(counts[.pending] == 1)
    }

    @Test func fileExclusionIsExact() throws {
        let (store, rootId) = try makeFixture()
        try store.setExcluded(rootId: rootId, kind: .file, relPath: "a.jpg", excluded: true)
        #expect(try store.statusCounts()[.excluded] == 1)

        try store.setExcluded(rootId: rootId, kind: .file, relPath: "a.jpg", excluded: false)
        #expect(try store.statusCounts()[.excluded] == nil)
        #expect(try store.statusCounts()[.pending] == 2)
    }

    @Test func directoryStatisticsGroupByDirAndStatus() throws {
        let (store, _) = try makeFixture()
        let rows = try store.directoryStatistics(rootId: 1)
        let byKey = Dictionary(
            uniqueKeysWithValues: rows.map { ("\($0.parentDir)|\($0.status.rawValue)", $0) }
        )
        #expect(byKey["|pending"]?.count == 1)
        #expect(byKey["sub|synced"]?.count == 1)
        #expect(byKey["sub|skipped_raw"]?.count == 1)
        #expect(byKey["sub/deep|pending"]?.count == 1)
    }
}
