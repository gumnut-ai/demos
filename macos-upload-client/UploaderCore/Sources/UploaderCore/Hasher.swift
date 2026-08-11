import CryptoKit
import Foundation

public enum FileHasher {
    /// Streaming SHA-256 of a file's contents; constant memory regardless of
    /// file size. `progress` receives cumulative bytes read.
    public static func sha256(
        contentsOf url: URL,
        bufferSize: Int = 1 << 20,
        progress: ((Int64) -> Void)? = nil
    ) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        var totalRead: Int64 = 0
        while true {
            let chunk = try autoreleasepool {
                try handle.read(upToCount: bufferSize)
            }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            totalRead += Int64(chunk.count)
            progress?(totalRead)
        }
        return Data(hasher.finalize())
    }
}
