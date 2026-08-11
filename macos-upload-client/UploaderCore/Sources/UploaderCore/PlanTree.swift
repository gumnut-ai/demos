import Foundation

/// One directory in the review tree, with subtree-aggregated statistics.
/// `id` is the directory's path relative to the root ("" for the root itself).
public struct PlanDirectoryNode: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    /// nil for directories with no subdirectories (OutlineGroup convention).
    public let children: [PlanDirectoryNode]?
    /// Subtree totals (this directory and everything below it).
    public let counts: [FileStatus: Int]
    public let pendingBytes: Int64

    public var totalFiles: Int {
        counts.values.reduce(0, +)
    }

    public func count(_ status: FileStatus) -> Int {
        counts[status] ?? 0
    }
}

/// Builds the review tree from one aggregated store query. Only directories
/// become nodes — individual files are listed separately per selected
/// directory — so the tree stays small even for very large libraries.
public enum PlanTree {
    public static func build(
        from rows: [Store.DirectoryStatusRow], rootName: String
    ) -> PlanDirectoryNode {
        var counts: [String: [FileStatus: Int]] = ["": [:]]
        var pendingBytes: [String: Int64] = [:]
        var childPaths: [String: Set<String>] = [:]

        for row in rows {
            let chain = pathChain(row.parentDir)
            for dir in chain {
                counts[dir, default: [:]][row.status, default: 0] += row.count
                if row.status == .pending {
                    pendingBytes[dir, default: 0] += row.bytes
                }
            }
            var parent = ""
            for dir in chain.dropFirst() {
                childPaths[parent, default: []].insert(dir)
                parent = dir
            }
        }

        func node(path: String, name: String) -> PlanDirectoryNode {
            let children = childPaths[path]?
                .sorted()
                .map { node(path: $0, name: lastSegment($0)) }
            return PlanDirectoryNode(
                id: path,
                name: name,
                children: (children?.isEmpty ?? true) ? nil : children,
                counts: counts[path] ?? [:],
                pendingBytes: pendingBytes[path] ?? 0
            )
        }
        return node(path: "", name: rootName)
    }

    /// "a/b/c" → ["", "a", "a/b", "a/b/c"]; "" → [""].
    static func pathChain(_ dir: String) -> [String] {
        guard !dir.isEmpty else { return [""] }
        var chain = [""]
        var current = ""
        for segment in dir.split(separator: "/") {
            current = current.isEmpty ? String(segment) : current + "/" + segment
            chain.append(current)
        }
        return chain
    }

    static func lastSegment(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}
