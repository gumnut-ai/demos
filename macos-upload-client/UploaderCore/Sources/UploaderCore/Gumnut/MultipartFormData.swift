import CryptoKit
import Foundation

/// Minimal multipart/form-data encoder. File contents are streamed in chunks,
/// never loaded into memory, so encoding a multi-gigabyte video needs constant
/// memory (and staging disk space equal to the file's size).
public struct MultipartFormData: Sendable {
    enum Segment: Sendable {
        case data(Data)
        case file(URL)
    }

    public let boundary: String
    private var segments: [Segment] = []

    public init(boundary: String = "gumnut-uploader-\(UUID().uuidString)") {
        self.boundary = boundary
    }

    public var contentType: String {
        "multipart/form-data; boundary=\(boundary)"
    }

    public mutating func addField(name: String, value: String) {
        var part = "--\(boundary)\r\n"
        part += "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n"
        part += "\(value)\r\n"
        segments.append(.data(Data(part.utf8)))
    }

    public mutating func addFile(
        name: String,
        fileName: String,
        contentType: String,
        fileURL: URL
    ) {
        var header = "--\(boundary)\r\n"
        header += "Content-Disposition: form-data; name=\"\(name)\"; "
        header += "filename=\"\(Self.sanitize(fileName))\"\r\n"
        header += "Content-Type: \(contentType)\r\n\r\n"
        segments.append(.data(Data(header.utf8)))
        segments.append(.file(fileURL))
        segments.append(.data(Data("\r\n".utf8)))
    }

    private var terminator: Data {
        Data("--\(boundary)--\r\n".utf8)
    }

    /// Streams the encoded body to `destination` (a staging file inside the
    /// app's own container — user files are never written). Returns the
    /// SHA-256 of the file-segment bytes as staged, so callers can verify the
    /// body contains exactly the content they analyzed — the file may have
    /// changed between their integrity checks and this read.
    @discardableResult
    public func writeEncoded(to destination: URL, bufferSize: Int = 1 << 20) throws -> Data {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        var fileHasher = SHA256()
        for segment in segments {
            switch segment {
            case .data(let data):
                try output.write(contentsOf: data)
            case .file(let url):
                let input = try FileHandle(forReadingFrom: url)
                defer { try? input.close() }
                while true {
                    let chunk = try autoreleasepool { try input.read(upToCount: bufferSize) }
                    guard let chunk, !chunk.isEmpty else { break }
                    fileHasher.update(data: chunk)
                    try output.write(contentsOf: chunk)
                }
            }
        }
        try output.write(contentsOf: terminator)
        return Data(fileHasher.finalize())
    }

    /// In-memory encoding for small bodies and tests.
    public func encodedData() throws -> Data {
        var body = Data()
        for segment in segments {
            switch segment {
            case .data(let data):
                body.append(data)
            case .file(let url):
                body.append(try Data(contentsOf: url))
            }
        }
        body.append(terminator)
        return body
    }

    /// Quotes and CRLF characters in a filename would corrupt the part header.
    static func sanitize(_ fileName: String) -> String {
        fileName
            .replacingOccurrences(of: "\"", with: "_")
            .replacingOccurrences(of: "\r", with: "_")
            .replacingOccurrences(of: "\n", with: "_")
    }
}
