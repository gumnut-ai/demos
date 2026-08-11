import Foundation

/// A throwaway directory, removed when the instance goes away.
final class TempDir {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("uploader-core-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    /// Writes a file at a relative path, creating intermediate directories.
    @discardableResult
    func write(_ relPath: String, _ contents: Data) throws -> URL {
        let fileURL = url.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try contents.write(to: fileURL)
        return fileURL
    }
}

extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    /// Splits on a delimiter, like String.components(separatedBy:).
    func components(separatedBy delimiter: Data) -> [Data] {
        var parts: [Data] = []
        var searchStart = startIndex
        while let range = self[searchStart...].firstRange(of: delimiter) {
            parts.append(self[searchStart..<range.lowerBound])
            searchStart = range.upperBound
        }
        parts.append(self[searchStart...])
        return parts
    }
}

struct MultipartPart {
    let headers: [String: String]
    let body: Data

    var name: String? {
        disposition(parameter: "name")
    }

    var filename: String? {
        disposition(parameter: "filename")
    }

    private func disposition(parameter: String) -> String? {
        guard let disposition = headers["Content-Disposition"] else { return nil }
        for piece in disposition.components(separatedBy: "; ") {
            if piece.hasPrefix("\(parameter)=") {
                return piece
                    .dropFirst(parameter.count + 1)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return nil
    }
}

/// Parses a multipart/form-data body for assertions.
func parseMultipart(body: Data, boundary: String) -> [MultipartPart] {
    let delimiter = Data("--\(boundary)\r\n".utf8)
    let terminator = Data("--\(boundary)--".utf8)
    var parts: [MultipartPart] = []

    for chunk in body.components(separatedBy: delimiter).dropFirst() {
        var chunk = chunk
        if let terminatorRange = chunk.firstRange(of: terminator) {
            chunk = chunk[chunk.startIndex..<terminatorRange.lowerBound]
        }
        guard let headerEnd = chunk.firstRange(of: Data("\r\n\r\n".utf8)) else { continue }
        let headerData = chunk[chunk.startIndex..<headerEnd.lowerBound]
        var partBody = chunk[headerEnd.upperBound...]
        if partBody.suffix(2).elementsEqual(Data("\r\n".utf8)) {
            partBody = partBody.dropLast(2)
        }
        var headers: [String: String] = [:]
        for line in String(decoding: headerData, as: UTF8.self).components(separatedBy: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colon])
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        parts.append(MultipartPart(headers: headers, body: Data(partBody)))
    }
    return parts
}
