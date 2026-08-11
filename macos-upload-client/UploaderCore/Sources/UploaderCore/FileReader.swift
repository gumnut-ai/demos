import Foundation

/// A regular file found during enumeration.
public struct DiscoveredFile: Equatable, Sendable {
    /// POSIX-style path relative to the enumerated root, "/"-separated.
    public let relPath: String
    public let size: Int64
    /// Modification time as epoch seconds.
    public let mtime: Double

    public init(relPath: String, size: Int64, mtime: Double) {
        self.relPath = relPath
        self.size = size
        self.mtime = mtime
    }
}

public struct EnumerationFailure: Sendable {
    public let path: String
    public let message: String
}

/// Read-only enumeration and stat layer over user files. The only other user
/// file access in the app — hashing and upload-body encoding — opens
/// read-only `FileHandle`s; nothing anywhere opens a user file for writing.
public struct FileReader: Sendable {
    public init() {}

    /// Enumerates regular files under `root`, depth-first. Hidden files and
    /// directories are skipped; symbolic links are never followed. Unreadable
    /// subdirectories are reported and skipped, not fatal.
    @discardableResult
    public func enumerate(
        root: URL,
        visit: (DiscoveredFile) throws -> Void
    ) throws -> [EnumerationFailure] {
        let fileManager = FileManager.default
        let rootPath = root.path
        // The enumerator yields canonical paths (e.g. /private/var/... for a
        // /var/... root), so compare prefixes against the canonical root.
        let canonicalRootPath = Self.canonicalPath(of: rootPath)
        let resolvedRoot = URL(fileURLWithPath: canonicalRootPath, isDirectory: true)

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: rootPath, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: rootPath])
        }

        var failures: [EnumerationFailure] = []
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
        ]

        guard
            let enumerator = fileManager.enumerator(
                at: resolvedRoot,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles],
                errorHandler: { url, error in
                    failures.append(
                        EnumerationFailure(path: url.path, message: error.localizedDescription)
                    )
                    return true  // keep enumerating
                }
            )
        else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: rootPath])
        }

        for case let url as URL in enumerator {
            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: Set(keys))
            } catch {
                // An unreadable file is a failure, not a skip — callers treat
                // failure-free enumeration as proof that unseen rows are gone.
                failures.append(
                    EnumerationFailure(path: url.path, message: error.localizedDescription)
                )
                continue
            }
            guard values.isSymbolicLink != true, values.isRegularFile == true else {
                continue
            }
            guard let size = values.fileSize, let modified = values.contentModificationDate else {
                failures.append(
                    EnumerationFailure(path: url.path, message: "missing size or mtime")
                )
                continue
            }
            let filePath = url.path
            guard filePath.hasPrefix(canonicalRootPath + "/") else {
                // Outside the canonical root; skip rather than guess.
                failures.append(
                    EnumerationFailure(path: filePath, message: "outside enumerated root")
                )
                continue
            }
            let relPath = String(filePath.dropFirst(canonicalRootPath.count + 1))
            try visit(
                DiscoveredFile(
                    relPath: relPath,
                    size: Int64(size),
                    mtime: modified.timeIntervalSince1970
                )
            )
        }
        return failures
    }

    /// Convenience for tests and small trees.
    public func enumerate(root: URL) throws -> [DiscoveredFile] {
        var files: [DiscoveredFile] = []
        try enumerate(root: root) { files.append($0) }
        return files.sorted { $0.relPath < $1.relPath }
    }

    public func stat(fileAt url: URL) throws -> (size: Int64, mtime: Double) {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard let size = values.fileSize, let modified = values.contentModificationDate else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        return (Int64(size), modified.timeIntervalSince1970)
    }

    /// Reachability probe for a root (an unmounted network volume fails here).
    public func directoryExists(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// Creation and modification times, for upload metadata.
    public func fileTimes(at url: URL) throws -> (created: Date?, modified: Date) {
        let values = try url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        guard let modified = values.contentModificationDate else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        return (values.creationDate, modified)
    }

    /// Fully resolved path via realpath(3); unlike `resolvingSymlinksInPath()`
    /// it does not strip the /private prefix, so it matches enumerator output.
    static func canonicalPath(of path: String) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &buffer) != nil else { return path }
        return String(cString: buffer)
    }
}
