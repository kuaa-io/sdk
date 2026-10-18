import Foundation
import Kuaa
import XCTest

#if canImport(Network)
    import Network
#endif

/// The requests a fake transport was sent.
final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    func append(_ request: URLRequest) {
        lock.withLock { requests.append(request) }
    }

    var seen: [URLRequest] {
        lock.withLock { requests }
    }
}

typealias Answer = @Sendable (URLRequest) -> (status: Int, headers: [String: String], body: Any?)

func client(_ answer: @escaping Answer) -> (KuaaClient, Recorder) {
    let recorder = Recorder()
    let transport: KuaaTransport = { request in
        recorder.append(request)
        let (status, headers, body) = answer(request)
        let data = try body.map { try JSONSerialization.data(withJSONObject: $0) } ?? Data()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        return (data, response)
    }
    let kuaa = KuaaClient(apiKey: "kuaa_test_abc_secret", baseURL: URL(string: "http://kuaa.test/")!, transport: transport)
    return (kuaa, recorder)
}

func kase() -> [String: Any] {
    [
    "id": "case_1", "external_reference": "pedido-1", "kind": "KYC", "status": "open", "status_market": "PROCESSING",
    "livemode": false, "custom_status": NSNull(), "current_state": "collect_identity", "workflow_definition_id": NSNull(),
    "policy_version_id": NSNull(), "parent_case_id": NSNull(), "child_group": NSNull(),
    "parties": [["id": "party_1", "kind": "PERSON", "primary": true, "identity_id": NSNull(), "cpf": "12345678909"]],
    "relationships": [Any](), "created_at": "2027-01-15T08:00:00Z", "updated_at": "2027-01-15T08:00:00Z",
    ]
}

func summary(_ id: String) -> [String: Any] {
    [
        "id": id, "external_reference": "ref-\(id)", "kind": "KYC", "status": "open", "status_market": "PROCESSING",
        "livemode": false, "current_state": "start", "workflow_definition_id": NSNull(), "workflow_version_id": NSNull(),
        "policy_version_id": NSNull(), "created_at": "2027-01-15T08:00:00Z", "updated_at": "2027-01-15T08:00:00Z",
    ]
}

func queryItem(_ request: URLRequest, _ name: String) -> String? {
    URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
}

final class KuaaTests: XCTestCase {
    func testACallCarriesTheKeyAndUnwrapsTheData() async throws {
        let (kuaa, recorder) = client { _ in
            (200, ["Kuaa-Livemode": "false", "Kuaa-Environment": "sandbox", "X-Request-ID": "req_1"], ["data": kase()])
        }
        let got = try await kuaa.cases.get("case_1")
        XCTAssertEqual(got.id, "case_1")
        XCTAssertEqual(got.status, .open)
        XCTAssertEqual(got.parties[0].cpf, "12345678909")
        let seen = recorder.seen[0]
        XCTAssertEqual(seen.httpMethod, "GET")
        XCTAssertEqual(seen.url?.path, "/v1/cases/case_1")
        XCTAssertEqual(seen.value(forHTTPHeaderField: "Authorization"), "Bearer kuaa_test_abc_secret")
        XCTAssertEqual(seen.value(forHTTPHeaderField: "User-Agent"), "kuaa-swift/\(KuaaClient.version)")
        let last = try XCTUnwrap(kuaa.lastResponse)
        XCTAssertEqual(last.status, 200)
        XCTAssertEqual(last.livemode, false)
        XCTAssertEqual(last.environment, "sandbox")
        XCTAssertFalse(last.idempotentReplayed)
        XCTAssertEqual(last.requestId, "req_1")
    }

    func testAWriteSendsItsBodyAndIdempotencyKey() async throws {
        let (kuaa, recorder) = client { _ in (200, ["Idempotent-Replayed": "true"], ["data": kase(), "meta": ["created": false]]) }
        let got = try await kuaa.cases.create(CaseRequest(externalReference: "pedido-1", kind: .kyc), idempotencyKey: "pedido-1")
        XCTAssertEqual(got.externalReference, "pedido-1")
        let seen = recorder.seen[0]
        XCTAssertEqual(seen.httpMethod, "POST")
        XCTAssertEqual(seen.url?.path, "/v1/cases")
        XCTAssertEqual(seen.value(forHTTPHeaderField: "Idempotency-Key"), "pedido-1")
        XCTAssertEqual(seen.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(seen.httpBody)) as? [String: String])
        // The optional fields, left nil, are not sent.
        XCTAssertEqual(body, ["external_reference": "pedido-1", "kind": "KYC"])
        XCTAssertEqual(kuaa.lastResponse?.idempotentReplayed, true)
    }

    func testANestedBodyIsWrittenWhole() async throws {
        let (kuaa, recorder) = client { _ in (201, [:], ["data": kase()]) }
        _ = try await kuaa.cases.create(
            CaseRequest(externalReference: "pedido-1", kind: .kyc, parties: [CaseRequestParty(kind: .person, cpf: "123.456.789-09", primary: true)])
        )
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(recorder.seen[0].httpBody)) as? [String: Any])
        let parties = try XCTUnwrap(body["parties"] as? [[String: Any]])
        XCTAssertEqual(parties.count, 1)
        XCTAssertEqual(parties[0]["kind"] as? String, "PERSON")
        XCTAssertEqual(parties[0]["cpf"] as? String, "123.456.789-09")
        XCTAssertEqual(parties[0]["primary"] as? Bool, true)
    }

    func testIteratingWalksEveryPageByCursor() async throws {
        let (kuaa, recorder) = client { request in
            let cursor = queryItem(request, "cursor") ?? ""
            let (id, next): (String, String?) = cursor == "" ? ("case_1", "c2") : cursor == "c2" ? ("case_2", "c3") : ("case_3", nil)
            let meta: [String: Any] = ["next_cursor": next as Any? ?? NSNull(), "has_more": next != nil, "limit": 1]
            return (200, [:], ["data": ["livemode": false, "cases": [summary(id)]], "meta": meta])
        }
        var ids: [String] = []
        for try await each in kuaa.cases.listIter(limit: 1, status: "open") {
            ids.append(each.id)
        }
        XCTAssertEqual(ids, ["case_1", "case_2", "case_3"])
        XCTAssertEqual(recorder.seen.count, 3)
        for request in recorder.seen {
            XCTAssertEqual(queryItem(request, "limit"), "1")
            XCTAssertEqual(queryItem(request, "status"), "open")
        }
    }

    func testARefusalIsATypedError() async throws {
        let (kuaa, _) = client { request in
            if request.url?.path == "/v1/cases" {
                let problem: [String: Any] = [
                    "code": "validation_failed", "message": "The input has invalid fields.", "fields": ["kind": ["must be KYC, KYB or AGE"]],
                ]
                return (422, [:], ["error": problem])
            }
            return (429, ["Retry-After": "7"], ["error": ["code": "rate_limited", "message": "Too many requests."]])
        }
        do {
            _ = try await kuaa.cases.create(CaseRequest(externalReference: "x", kind: .kyc))
            XCTFail("a 422 was not refused")
        } catch let refused as KuaaError {
            XCTAssertEqual(refused.status, 422)
            XCTAssertEqual(refused.code, "validation_failed")
            XCTAssertEqual(refused.fields["kind"], ["must be KYC, KYB or AGE"])
        }
        do {
            _ = try await kuaa.cases.get("case_1")
            XCTFail("a 429 was not refused")
        } catch let limited as KuaaError {
            XCTAssertEqual(limited.status, 429)
            XCTAssertEqual(limited.code, "rate_limited")
            XCTAssertEqual(limited.retryAfter, 7)
        }
    }

    func testACaptureIsSentAsMultipart() async throws {
        let (kuaa, recorder) = client { _ in
            let document: [String: Any] = [
                "id": "doc_1", "capture": "document", "party_id": "party_1", "status": "received", "artifact_id": NSNull(),
                "created_at": "2027-01-15T08:00:00Z",
            ]
            return (201, [:], ["data": ["documents": [document]]])
        }
        let form = CaptureForm(
            file: [
                FilePart(filename: "frente.jpg", data: Data([0xFF, 0xD8, 0x20, 0x66]), contentType: "image/jpeg"),
                FilePart(filename: "verso.jpg", data: Data("verso".utf8), contentType: "image/jpeg"),
            ],
            kind: .document, documentType: .cnh, side: .front
        )
        let got = try await kuaa.caseMedia.create("case_1", form, idempotencyKey: "captura-1")
        XCTAssertEqual(got.documents[0].id, "doc_1")
        let seen = recorder.seen[0]
        XCTAssertEqual(seen.url?.path, "/v1/cases/case_1/media")
        XCTAssertEqual(seen.value(forHTTPHeaderField: "Idempotency-Key"), "captura-1")
        let type = try XCTUnwrap(seen.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertTrue(type.hasPrefix("multipart/form-data; boundary="))
        let boundary = String(type.dropFirst("multipart/form-data; boundary=".count))
        let body = try XCTUnwrap(seen.httpBody)
        func contains(_ text: String) -> Bool { body.range(of: Data(text.utf8)) != nil }
        XCTAssertTrue(contains("Content-Disposition: form-data; name=\"kind\"\r\n\r\ndocument\r\n"))
        let file = Data("Content-Disposition: form-data; name=\"file\"; filename=\"frente.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".utf8)
            + Data([0xFF, 0xD8, 0x20, 0x66]) + Data("\r\n".utf8)
        XCTAssertNotNil(body.range(of: file))
        XCTAssertTrue(contains("filename=\"verso.jpg\""))
        XCTAssertFalse(contains("name=\"party_id\""))
        XCTAssertTrue(body.suffix(boundary.count + 6) == Data("--\(boundary)--\r\n".utf8))
    }

    func testAListQueryRepeatsItsName() async throws {
        let (kuaa, recorder) = client { _ in (200, [:], ["data": ["case_id": "case_1", "tags": [Any]()]]) }
        let got = try await kuaa.caseTags.delete("case_1", tag: ["prioridade", "revisar"])
        XCTAssertEqual(got.caseID, "case_1")
        XCTAssertEqual(recorder.seen[0].httpMethod, "DELETE")
        XCTAssertEqual(recorder.seen[0].url?.query, "tag=prioridade&tag=revisar")
    }

    #if canImport(CryptoKit)
        /// The vectors are generated once, in Go, by sdk/generator, and every
        /// SDK checks its verification against them.
        func testTheWebhookVectors() throws {
            let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("webhook-vectors.json")
            let vectors = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            XCTAssertEqual(vectors["tolerance_seconds"] as? Double, webhookTolerance)
            let all = try XCTUnwrap(vectors["vectors"] as? [[String: Any]])
            XCTAssertFalse(all.isEmpty)
            for vector in all {
                let name = try XCTUnwrap(vector["name"] as? String)
                let headers = try XCTUnwrap(vector["headers"] as? [String: [String]])
                let body = Data(try XCTUnwrap(vector["body"] as? String).utf8)
                let secret = try XCTUnwrap(vector["secret"] as? String)
                let now = Date(timeIntervalSince1970: try XCTUnwrap(vector["now"] as? Double))
                guard vector["valid"] as? Bool == true else {
                    XCTAssertThrowsError(try verifyWebhook(secret: secret, headers: headers, body: body, now: now), name) {
                        XCTAssertEqual($0 as? WebhookVerificationError, .invalidSignature, name)
                    }
                    continue
                }
                let event = try verifyWebhook(secret: secret, headers: headers, body: body, now: now)
                let want = try XCTUnwrap(vector["event"] as? [String: Any])
                XCTAssertEqual(event.specversion.rawValue, "1.0", name)
                XCTAssertEqual(event.id, want["id"] as? String, name)
                XCTAssertEqual(event.type.rawValue, want["type"] as? String, name)
                XCTAssertEqual(event.source, want["source"] as? String, name)
                XCTAssertEqual(event.subject, want["subject"] as? String, name)
                XCTAssertEqual(event.data.caseID, want["case_id"] as? String, name)
                XCTAssertEqual(event.data.status, want["status"] as? String, name)
                XCTAssertEqual(event.data.environment.rawValue, want["environment"] as? String, name)
                XCTAssertEqual(event.data.livemode, want["livemode"] as? Bool, name)
            }
        }
    #endif

    #if canImport(Network)
        func testTheRealHTTPSendsAndReadsThroughURLSession() async throws {
            let server = try EchoServer()
            let port = try await server.start()
            defer { server.stop() }
            let base = URL(string: "http://127.0.0.1:\(port)")!
            let kuaa = KuaaClient(apiKey: "kuaa_test_abc_secret", baseURL: base)
            let tags = try await kuaa.caseTags.create("case 1/2", CaseTagsRequest(tags: ["prioridade"]), idempotencyKey: "tag-1")
            XCTAssertEqual(tags.tags[0].name, "prioridade")
            XCTAssertEqual(tags.tags[0].slug, "tag-1")
            XCTAssertEqual(tags.tags[0].createdAt, "POST /v1/cases/case%201%2F2/tags")
            XCTAssertEqual(kuaa.lastResponse?.livemode, false)
            do {
                _ = try await KuaaClient(apiKey: "kuaa_test_other", baseURL: base).cases.get("case_1")
                XCTFail("a 401 was not refused")
            } catch let refused as KuaaError {
                XCTAssertEqual(refused.status, 401)
                XCTAssertEqual(refused.code, "unauthenticated")
                XCTAssertEqual(refused.retryAfter, 3)
                XCTAssertEqual(refused.requestId, "req_401")
            }
        }
    #endif
}

#if canImport(Network)
    /// Answers what it was sent as a case's tags; a request without the test
    /// key is refused with a 401, Retry-After 3 and a request id.
    final class EchoServer: @unchecked Sendable {
        private let listener: NWListener
        private let queue = DispatchQueue(label: "kuaa.echo")
        private var started = false

        init() throws {
            listener = try NWListener(using: .tcp, on: .any)
        }

        func start() async throws -> UInt16 {
            listener.newConnectionHandler = { [queue] connection in
                connection.start(queue: queue)
                Self.read(connection, Data())
            }
            return try await withCheckedThrowingContinuation { continuation in
                // The handler runs on the server's serial queue only.
                listener.stateUpdateHandler = { [self] state in
                    guard !started else { return }
                    switch state {
                    case .ready:
                        started = true
                        continuation.resume(returning: listener.port?.rawValue ?? 0)
                    case .failed(let error):
                        started = true
                        continuation.resume(throwing: error)
                    default:
                        break
                    }
                }
                listener.start(queue: queue)
            }
        }

        func stop() {
            listener.cancel()
        }

        private static func read(_ connection: NWConnection, _ buffer: Data) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
                var buffer = buffer
                if let data {
                    buffer.append(data)
                }
                if let answer = answer(buffer) {
                    connection.send(content: answer, completion: .contentProcessed { _ in connection.cancel() })
                } else if complete || error != nil {
                    connection.cancel()
                } else {
                    read(connection, buffer)
                }
            }
        }

        /// The answer to a whole request, or nil while it has not all arrived.
        private static func answer(_ buffer: Data) -> Data? {
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                return nil
            }
            let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            var headers: [String: String] = [:]
            for line in head.dropFirst() {
                let parts = line.split(separator: ":", maxSplits: 1)
                if parts.count == 2 {
                    headers[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
                }
            }
            let length = Int(headers["content-length"] ?? "") ?? 0
            let body = buffer[end.upperBound...]
            guard body.count >= length else {
                return nil
            }
            let line = head[0].split(separator: " ")
            var status = "200 OK"
            var extra = "Kuaa-Livemode: false\r\n"
            var payload: [String: Any]
            if headers["authorization"] != "Bearer kuaa_test_abc_secret" {
                status = "401 Unauthorized"
                extra = "Retry-After: 3\r\nX-Request-ID: req_401\r\n"
                payload = ["error": ["code": "unauthenticated", "message": "Send a key."]]
            } else {
                let sent = (try? JSONSerialization.jsonObject(with: Data(body.prefix(length)))) as? [String: Any]
                let names = sent?["tags"] as? [String] ?? []
                payload = ["data": [
                    "case_id": "case_1",
                    "tags": names.map { name in
                        [
                            "id": "tag_1",
                            "name": name,
                            "slug": headers["idempotency-key"] ?? "",
                            "created_at": "\(line[0]) \(line.count > 1 ? line[1] : "")",
                        ]
                    },
                ]]
            }
            let json = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
            let header = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\n\(extra)Content-Length: \(json.count)\r\nConnection: close\r\n\r\n"
            return Data(header.utf8) + json
        }
    }
#endif
