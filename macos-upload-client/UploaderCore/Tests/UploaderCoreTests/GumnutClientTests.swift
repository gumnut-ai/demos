import Foundation
import Testing

@testable import UploaderCore

/// Serialized: StubURLProtocol keeps shared mutable state.
@Suite(.serialized) struct GumnutClientTests {
    private func makeClient() -> GumnutClient {
        GumnutClient(
            baseURL: URL(string: "https://gumnut.example.com")!,
            apiKey: "test-key",
            session: StubURLProtocol.makeSession()
        )
    }

    @Test func currentUserSendsBearerTokenAndDecodes() async throws {
        defer { StubURLProtocol.reset() }
        StubURLProtocol.handler = { request, _ in
            .json(200, #"{"id": "intuser_1", "email": "someone@example.com"}"#)
        }

        let user = try await makeClient().currentUser()
        #expect(user == GumnutUser(id: "intuser_1", email: "someone@example.com"))

        let request = StubURLProtocol.lastRequest
        #expect(request?.url?.path() == "/api/users/me")
        #expect(request?.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
    }

    @Test func librariesDecodesBareArray() async throws {
        defer { StubURLProtocol.reset() }
        StubURLProtocol.handler = { _, _ in
            .json(
                200,
                #"[{"id": "lib_1", "name": "Main", "asset_count": 5}, {"id": "lib_2", "name": "Archive", "asset_count": 0}]"#
            )
        }

        let libraries = try await makeClient().libraries()
        #expect(libraries.map(\.id) == ["lib_1", "lib_2"])
        #expect(libraries[0].assetCount == 5)
        #expect(StubURLProtocol.lastRequest?.url?.path() == "/api/libraries")
    }

    @Test func checkExistenceSendsBase64ChecksumsAndDecodesMatches() async throws {
        defer { StubURLProtocol.reset() }
        let digestA = Data(repeating: 0xAA, count: 32)
        let digestB = Data(repeating: 0xBB, count: 32)

        StubURLProtocol.handler = { _, body in
            .json(
                200,
                #"{"assets": [{"id": "asset_1", "checksum": "\#(digestA.base64EncodedString())", "checksum_sha1": null, "device_asset_id": "d1", "device_id": "dev"}]}"#
            )
        }

        let matches = try await makeClient().checkExistence(
            sha256Digests: [digestA, digestB], libraryId: "lib_1"
        )
        #expect(matches.map(\.id) == ["asset_1"])
        #expect(matches[0].checksum == digestA.base64EncodedString())

        let sentBody = try JSONSerialization.jsonObject(
            with: StubURLProtocol.lastBody ?? Data()
        ) as? [String: Any]
        #expect(
            sentBody?["checksums"] as? [String] == [
                digestA.base64EncodedString(), digestB.base64EncodedString(),
            ]
        )
        #expect(sentBody?["library_id"] as? String == "lib_1")
        #expect(StubURLProtocol.lastRequest?.url?.path() == "/api/assets/exist")
    }

    @Test func checkExistenceRejectsOversizedBatchesClientSide() async throws {
        let digests = Array(repeating: Data(repeating: 1, count: 32), count: 5001)
        await #expect(throws: GumnutClientError.tooManyChecksums(count: 5001, max: 5000)) {
            try await makeClient().checkExistence(sha256Digests: digests)
        }
    }

    @Test func uploadSendsMultipartAndDistinguishesCreated() async throws {
        defer { StubURLProtocol.reset() }
        let dir = try TempDir()
        let fileURL = try dir.write("IMG_0001.JPG", Data("fake-jpeg-bytes".utf8))

        let assetJSON = #"""
            {"id": "asset_7", "mime_type": "image/jpeg", "original_file_name": "IMG_0001.JPG",
             "file_data": {"checksum": "c2hhMjU2", "checksum_sha1": null, "file_size_bytes": 15}}
            """#
        StubURLProtocol.handler = { _, _ in .json(201, assetJSON) }

        let client = makeClient()
        let (outcome, asset) = try await client.uploadAsset(
            fileURL: fileURL,
            deviceAssetId: "root-uuid:IMG_0001.JPG",
            deviceId: "install-uuid",
            fileCreatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            fileModifiedAt: Date(timeIntervalSince1970: 1_700_000_100),
            libraryId: "lib_1"
        )
        #expect(outcome == .created)
        #expect(asset.id == "asset_7")
        #expect(asset.fileData?.checksum == "c2hhMjU2")

        let request = StubURLProtocol.lastRequest
        #expect(request?.url?.path() == "/api/assets")
        let contentType = request?.value(forHTTPHeaderField: "Content-Type") ?? ""
        #expect(contentType.hasPrefix("multipart/form-data; boundary="))

        let boundary = String(contentType.dropFirst("multipart/form-data; boundary=".count))
        let parts = parseMultipart(body: StubURLProtocol.lastBody ?? Data(), boundary: boundary)
        let byName = Dictionary(
            uniqueKeysWithValues: parts.compactMap { part in part.name.map { ($0, part) } }
        )
        #expect(byName["device_asset_id"]?.body == Data("root-uuid:IMG_0001.JPG".utf8))
        #expect(byName["device_id"]?.body == Data("install-uuid".utf8))
        #expect(byName["library_id"]?.body == Data("lib_1".utf8))
        #expect(byName["file_created_at"].map { String(decoding: $0.body, as: UTF8.self) }?.contains("T") == true)
        #expect(byName["asset_data"]?.filename == "IMG_0001.JPG")
        #expect(byName["asset_data"]?.headers["Content-Type"] == "image/jpeg")
        #expect(byName["asset_data"]?.body == Data("fake-jpeg-bytes".utf8))
    }

    @Test func uploadTreats200AsAlreadyExisted() async throws {
        defer { StubURLProtocol.reset() }
        let dir = try TempDir()
        let fileURL = try dir.write("dup.jpg", Data("same-bytes".utf8))

        StubURLProtocol.handler = { _, _ in
            .json(200, #"{"id": "asset_existing", "file_data": {"checksum": "eA=="}}"#)
        }

        let (outcome, asset) = try await makeClient().uploadAsset(
            fileURL: fileURL,
            deviceAssetId: "d", deviceId: "i",
            fileCreatedAt: Date(), fileModifiedAt: Date()
        )
        #expect(outcome == .alreadyExisted)
        #expect(asset.id == "asset_existing")
    }

    @Test func errorMapping() async throws {
        defer { StubURLProtocol.reset() }
        let dir = try TempDir()
        let fileURL = try dir.write("f.jpg", Data("x".utf8))
        let client = makeClient()

        func upload() async throws {
            _ = try await client.uploadAsset(
                fileURL: fileURL, deviceAssetId: "d", deviceId: "i",
                fileCreatedAt: Date(), fileModifiedAt: Date()
            )
        }

        StubURLProtocol.handler = { _, _ in
            .json(422, #"{"detail": "File must be an image or video"}"#)
        }
        await #expect(
            throws: GumnutClientError.invalidRequest(
                statusCode: 422, message: "File must be an image or video"
            )
        ) { try await upload() }

        StubURLProtocol.handler = { _, _ in
            StubURLProtocol.Response(status: 429, headers: ["Retry-After": "7"])
        }
        await #expect(throws: GumnutClientError.rateLimited(retryAfter: 7)) {
            try await upload()
        }

        StubURLProtocol.handler = { _, _ in
            .json(507, #"{"detail": "Storage limit exceeded"}"#)
        }
        await #expect(
            throws: GumnutClientError.storageQuotaExceeded(message: "Storage limit exceeded")
        ) { try await upload() }

        StubURLProtocol.handler = { _, _ in
            StubURLProtocol.Response(
                status: 502,
                headers: ["Retry-After": "15", "Content-Type": "application/json"],
                body: Data(#"{"error_code": "transient_storage_error"}"#.utf8)
            )
        }
        await #expect(
            throws: GumnutClientError.transientServer(
                statusCode: 502, retryAfter: 15, message: "transient_storage_error"
            )
        ) { try await upload() }

        StubURLProtocol.handler = { _, _ in .json(401, #"{"detail": "Invalid API key"}"#) }
        await #expect(
            throws: GumnutClientError.unauthorized(statusCode: 401, message: "Invalid API key")
        ) {
            try await client.currentUser()
        }

        // A WAF answers 403 with an HTML block page, not API JSON — that is
        // an edge block on the request's content, not a credential failure.
        StubURLProtocol.handler = { _, _ in
            StubURLProtocol.Response(
                status: 403,
                headers: ["Content-Type": "text/html"],
                body: Data(
                    "<!DOCTYPE html><html><body>Blocked. Request ID: abc123DEF</body></html>"
                        .utf8)
            )
        }
        await #expect(
            throws: GumnutClientError.edgeBlocked(statusCode: 403, requestId: "abc123DEF")
        ) { try await upload() }
    }

    @Test func errorMessageExtraction() {
        #expect(
            GumnutClient.errorMessage(from: Data(#"{"detail": "boom"}"#.utf8)) == "boom"
        )
        #expect(
            GumnutClient.errorMessage(
                from: Data(#"{"detail": [{"msg": "bad field", "loc": ["x"]}]}"#.utf8)
            ) == "bad field"
        )
        #expect(
            GumnutClient.errorMessage(from: Data(#"{"error_code": "code_x"}"#.utf8)) == "code_x"
        )
        #expect(GumnutClient.errorMessage(from: Data()) == nil)
    }
}
