import Foundation
import Testing

@testable import UploaderCore

@Suite struct MultipartFormDataTests {
    @Test func encodesFieldsAndFile() throws {
        let dir = try TempDir()
        let fileURL = try dir.write("photo.jpg", Data("jpegbytes".utf8))

        var form = MultipartFormData(boundary: "test-boundary")
        form.addField(name: "device_id", value: "device-1")
        form.addFile(
            name: "asset_data", fileName: "photo.jpg", contentType: "image/jpeg", fileURL: fileURL
        )

        let parts = parseMultipart(body: try form.encodedData(), boundary: "test-boundary")
        #expect(parts.count == 2)
        #expect(parts[0].name == "device_id")
        #expect(parts[0].body == Data("device-1".utf8))
        #expect(parts[1].name == "asset_data")
        #expect(parts[1].filename == "photo.jpg")
        #expect(parts[1].headers["Content-Type"] == "image/jpeg")
        #expect(parts[1].body == Data("jpegbytes".utf8))
    }

    @Test func streamedEncodingMatchesInMemoryEncoding() throws {
        let dir = try TempDir()
        let fileURL = try dir.write("clip.mov", Data(repeating: 9, count: 300_000))

        var form = MultipartFormData(boundary: "test-boundary")
        form.addField(name: "device_asset_id", value: "root:clip.mov")
        form.addFile(
            name: "asset_data", fileName: "clip.mov", contentType: "video/quicktime",
            fileURL: fileURL
        )

        let destination = dir.url.appendingPathComponent("encoded.bin")
        try form.writeEncoded(to: destination, bufferSize: 4096)
        #expect(try Data(contentsOf: destination) == (try form.encodedData()))
    }

    @Test func sanitizesHostileFilenames() {
        #expect(MultipartFormData.sanitize("a\"b.jpg") == "a_b.jpg")
        #expect(MultipartFormData.sanitize("a\r\nb.jpg") == "a__b.jpg")
        #expect(MultipartFormData.sanitize("normal.jpg") == "normal.jpg")
    }
}
