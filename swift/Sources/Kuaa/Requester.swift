import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Sends one request and answers its body and response, whatever the status.
/// The SDK sends through `URLSession.shared`; a test, or a program with its
/// own HTTP stack, gives another one to `KuaaClient`.
public typealias KuaaTransport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

/// One file of a multipart body.
public struct FilePart: Codable, Sendable, Hashable {
    /// The name the part carries, such as frente.jpg.
    public let filename: String
    /// The file's bytes.
    public let data: Data
    /// The file's media type: image/jpeg or image/png.
    public let contentType: String

    public init(filename: String, data: Data, contentType: String = "application/octet-stream") {
        self.filename = filename
        self.data = data
        self.contentType = contentType
    }
}

/// One field of a multipart body: a text value, or a file.
enum Part: Sendable {
    case text(String)
    case file(FilePart)
}

/// What the API said about an answer, beside its body.
public struct ResponseInfo: Sendable, Hashable {
    /// The HTTP status.
    public let status: Int
    /// The Kuaa-Livemode header: true for live, false for a sandbox, nil when
    /// absent.
    public let livemode: Bool?
    /// The Kuaa-Environment header: live or sandbox.
    public let environment: String?
    /// The answer is the stored answer of an earlier request with the same
    /// Idempotency-Key.
    public let idempotentReplayed: Bool
    /// The X-Request-ID header.
    public let requestId: String?

    init(_ response: HTTPURLResponse) {
        status = response.statusCode
        switch response.value(forHTTPHeaderField: "Kuaa-Livemode") {
        case "true": livemode = true
        case "false": livemode = false
        default: livemode = nil
        }
        environment = response.value(forHTTPHeaderField: "Kuaa-Environment")
        idempotentReplayed = response.value(forHTTPHeaderField: "Idempotent-Replayed") == "true"
        requestId = response.value(forHTTPHeaderField: "X-Request-ID")
    }
}

/// The last answer a client read, behind a lock.
final class LastResponse: @unchecked Sendable {
    private let lock = NSLock()
    private var info: ResponseInfo?

    var value: ResponseInfo? {
        get { lock.withLock { info } }
        set { lock.withLock { info = newValue } }
    }
}

/// A request's body: JSON, or a multipart form.
enum Body: Sendable {
    case json(any Encodable & Sendable)
    case multipart([(String, Part)])
}

/// What a service calls the API through.
struct Requester: Sendable {
    let apiKey: String
    let baseURL: String
    let timeout: TimeInterval
    let transport: KuaaTransport
    let last: LastResponse

    /// Calls the API and answers its `data`; a refusal throws `KuaaError`.
    func request<T: Decodable>(
        _ method: String,
        _ path: String,
        query: [(String, String?)] = [],
        body: Body? = nil,
        idempotencyKey: String? = nil,
        apiKey: String? = nil
    ) async throws -> T {
        let data = try await send(method, path, query: query, body: body, idempotencyKey: idempotencyKey, apiKey: apiKey)
        return try JSONDecoder().decode(Envelope<T>.self, from: data).data
    }

    /// Calls a list and answers its page, the items under `field`.
    func page<T: Decodable & Sendable>(_ path: String, field: String, query: [(String, String?)], apiKey: String?) async throws -> Page<T> {
        let data = try await send("GET", path, query: query, body: nil, idempotencyKey: nil, apiKey: apiKey)
        let decoder = JSONDecoder()
        decoder.userInfo[ListField.key] = field
        let envelope = try decoder.decode(ListEnvelope<T>.self, from: data)
        let next = envelope.meta?.nextCursor
        return Page(items: envelope.data.items, nextCursor: next, hasMore: envelope.meta?.hasMore ?? !(next ?? "").isEmpty)
    }

    private func send(
        _ method: String,
        _ path: String,
        query: [(String, String?)],
        body: Body?,
        idempotencyKey: String?,
        apiKey: String?
    ) async throws -> Data {
        var address = baseURL + path
        let pairs = query.compactMap { name, value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return "\(escape(name))=\(escape(value))"
        }
        if !pairs.isEmpty {
            address += "?" + pairs.joined(separator: "&")
        }
        guard let url = URL(string: address) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        let key = apiKey.flatMap { $0.isEmpty ? nil : $0 } ?? self.apiKey
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("kuaa-swift/\(KuaaClient.version)", forHTTPHeaderField: "User-Agent")
        switch body {
        case .json(let value):
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            request.httpBody = try encoder.encode(value)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        case .multipart(let parts):
            let (data, type) = multipart(parts)
            request.httpBody = data
            request.setValue(type, forHTTPHeaderField: "Content-Type")
        case nil:
            break
        }
        if let idempotencyKey, !idempotencyKey.isEmpty {
            request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        }
        let (data, response) = try await transport(request)
        last.value = ResponseInfo(response)
        if response.statusCode >= 300 {
            throw KuaaError(response: response, body: data)
        }
        return data
    }

    /// Sends through `URLSession.shared`.
    static let urlSession: KuaaTransport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}

private struct Envelope<T: Decodable>: Decodable {
    let data: T
}

/// The name of the property a list's items are under, for `ListData`.
private enum ListField {
    static let key = CodingUserInfoKey(rawValue: "kuaa.list.field")!
}

private struct AnyKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        nil
    }
}

private struct ListData<T: Decodable>: Decodable {
    let items: [T]

    init(from decoder: any Decoder) throws {
        let field = decoder.userInfo[ListField.key] as? String ?? "items"
        let container = try decoder.container(keyedBy: AnyKey.self)
        items = try container.decodeIfPresent([T].self, forKey: AnyKey(stringValue: field)) ?? []
    }
}

private struct ListMeta: Decodable {
    let nextCursor: String?
    let hasMore: Bool?

    enum CodingKeys: String, CodingKey {
        case nextCursor = "next_cursor"
        case hasMore = "has_more"
    }
}

private struct ListEnvelope<T: Decodable>: Decodable {
    let data: ListData<T>
    let meta: ListMeta?
}

/// A body as multipart/form-data: a text value per field, or a file.
func multipart(_ parts: [(String, Part)]) -> (Data, String) {
    let boundary = "kuaa-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(24)
    func quote(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "%0D")
            .replacingOccurrences(of: "\n", with: "%0A")
    }
    var out = Data()
    for (name, part) in parts {
        out += Data("--\(boundary)\r\n".utf8)
        switch part {
        case .file(let file):
            out += Data("Content-Disposition: form-data; name=\"\(quote(name))\"; filename=\"\(quote(file.filename))\"\r\n".utf8)
            out += Data("Content-Type: \(file.contentType)\r\n\r\n".utf8)
            out += file.data
        case .text(let text):
            out += Data("Content-Disposition: form-data; name=\"\(quote(name))\"\r\n\r\n\(text)".utf8)
        }
        out += Data("\r\n".utf8)
    }
    out += Data("--\(boundary)--\r\n".utf8)
    return (out, "multipart/form-data; boundary=\(boundary)")
}

private let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

/// A path parameter or a query value, escaped: everything but letters, digits
/// and `-._~`.
func escape(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
}
