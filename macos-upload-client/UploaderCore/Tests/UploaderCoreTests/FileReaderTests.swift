import Foundation
import Testing

@testable import UploaderCore

@Suite struct FileClassifierTests {
    @Test func classifiesByExtensionCaseInsensitively() {
        #expect(FileClassifier.classify(fileName: "IMG_0001.JPG") == .image)
        #expect(FileClassifier.classify(fileName: "photo.heic") == .image)
        #expect(FileClassifier.classify(fileName: "clip.MOV") == .video)
        #expect(FileClassifier.classify(fileName: "clip.mkv") == .video)
        #expect(FileClassifier.classify(fileName: "shot.NEF") == .raw)
        #expect(FileClassifier.classify(fileName: "shot.dng") == .raw)
        #expect(FileClassifier.classify(fileName: "notes.txt") == .unsupported)
        #expect(FileClassifier.classify(fileName: "sidecar.xmp") == .unsupported)
        #expect(FileClassifier.classify(fileName: "no-extension") == .unsupported)
    }

    @Test func initialStatuses() {
        #expect(MediaClassification.image.initialStatus == .pending)
        #expect(MediaClassification.video.initialStatus == .pending)
        #expect(MediaClassification.raw.initialStatus == .skippedRaw)
        #expect(MediaClassification.unsupported.initialStatus == .skippedUnsupported)
    }
}

@Suite struct FileReaderTests {
    @Test func enumeratesRegularFilesSkippingHiddenAndSymlinks() throws {
        let dir = try TempDir()
        try dir.write("a.jpg", Data("aaa".utf8))
        try dir.write("sub/b.NEF", Data("bbbb".utf8))
        try dir.write("sub/deep/c.mov", Data("ccccc".utf8))
        try dir.write("note.txt", Data("n".utf8))
        try dir.write(".hidden.jpg", Data("h".utf8))
        try dir.write(".hiddendir/x.jpg", Data("x".utf8))

        // A symlink pointing outside the root must not be followed.
        let outside = try TempDir()
        let target = try outside.write("outside.jpg", Data("ooo".utf8))
        try FileManager.default.createSymbolicLink(
            at: dir.url.appendingPathComponent("link.jpg"), withDestinationURL: target
        )

        let files = try FileReader().enumerate(root: dir.url)
        #expect(files.map(\.relPath) == ["a.jpg", "note.txt", "sub/b.NEF", "sub/deep/c.mov"])
        #expect(files.map(\.size) == [3, 1, 4, 5])
        #expect(files.allSatisfy { $0.mtime > 0 })
    }

    @Test func statMatchesEnumeration() throws {
        let dir = try TempDir()
        let url = try dir.write("a.jpg", Data("aaa".utf8))
        let files = try FileReader().enumerate(root: dir.url)
        let stat = try FileReader().stat(fileAt: url)
        #expect(files.count == 1)
        #expect(files[0].size == stat.size)
        #expect(files[0].mtime == stat.mtime)
    }

    @Test func unreadableSubdirectoryIsReportedNotFatal() throws {
        let dir = try TempDir()
        try dir.write("ok.jpg", Data("ok".utf8))
        try dir.write("locked/secret.jpg", Data("s".utf8))
        let locked = dir.url.appendingPathComponent("locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: locked.path
            )
        }

        var visited: [DiscoveredFile] = []
        let failures = try FileReader().enumerate(root: dir.url) { visited.append($0) }
        #expect(visited.map(\.relPath) == ["ok.jpg"])
        #expect(!failures.isEmpty)
    }

    @Test func missingRootThrows() throws {
        let dir = try TempDir()
        let missing = dir.url.appendingPathComponent("does-not-exist")
        #expect(throws: (any Error).self) {
            try FileReader().enumerate(root: missing)
        }
    }
}
