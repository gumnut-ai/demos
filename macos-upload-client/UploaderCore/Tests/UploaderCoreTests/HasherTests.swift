import CryptoKit
import Foundation
import Testing

@testable import UploaderCore

@Suite struct HasherTests {
    @Test func emptyFile() throws {
        let dir = try TempDir()
        let url = try dir.write("empty.bin", Data())
        let digest = try FileHasher.sha256(contentsOf: url)
        #expect(
            digest.hexString == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
    }

    @Test func knownVector() throws {
        let dir = try TempDir()
        let url = try dir.write("abc.txt", Data("abc".utf8))
        let digest = try FileHasher.sha256(contentsOf: url)
        #expect(
            digest.hexString == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    @Test func largeFileMatchesOneShotDigest() throws {
        let dir = try TempDir()
        var bytes = Data(count: 3 * 1024 * 1024)
        bytes.withUnsafeMutableBytes { buffer in
            for i in buffer.indices {
                buffer[i] = UInt8((i &* 31) & 0xFF)
            }
        }
        let url = try dir.write("large.bin", bytes)
        let streamed = try FileHasher.sha256(contentsOf: url, bufferSize: 64 * 1024)
        let oneShot = Data(SHA256.hash(data: bytes))
        #expect(streamed == oneShot)
    }

    @Test func progressReportsCumulativeBytes() throws {
        let dir = try TempDir()
        let url = try dir.write("file.bin", Data(repeating: 7, count: 10_000))
        var reports: [Int64] = []
        _ = try FileHasher.sha256(contentsOf: url, bufferSize: 1024) { reports.append($0) }
        #expect(reports.count == 10)
        #expect(reports == reports.sorted())
        #expect(reports.last == 10_000)
    }

    @Test func missingFileThrows() throws {
        let dir = try TempDir()
        let url = dir.url.appendingPathComponent("nope.bin")
        #expect(throws: (any Error).self) {
            try FileHasher.sha256(contentsOf: url)
        }
    }
}
