import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// A request the API refused.
///
/// `code` is the API's, the one to branch on: unauthenticated, forbidden,
/// not_found, conflict, idempotency_key_reused, validation_failed,
/// payment_required, malformed_json, body_too_large, rate_limited…
/// `fields` says, for validation_failed, what is wrong with each field.
/// `retryAfter` is how long the API asked to wait, on a 429 or a 503.
public struct KuaaError: Error, Sendable, Hashable, CustomStringConvertible, LocalizedError {
    /// The HTTP status.
    public let status: Int
    /// The API's code for the refusal.
    public let code: String
    /// What went wrong, for a person to read.
    public let message: String
    /// The problems of each field of the request.
    public let fields: [String: [String]]
    /// How many seconds to wait before trying again.
    public let retryAfter: TimeInterval?
    /// The X-Request-ID header.
    public let requestId: String?

    public init(
        status: Int, code: String, message: String = "", fields: [String: [String]] = [:], retryAfter: TimeInterval? = nil,
        requestId: String? = nil
    ) {
        self.status = status
        self.code = code
        self.message = message
        self.fields = fields
        self.retryAfter = retryAfter
        self.requestId = requestId
    }

    /// The error a refused response carries. A refusal without a JSON body is
    /// still a refusal.
    init(response: HTTPURLResponse, body: Data) {
        let problem = (try? JSONDecoder().decode(Body.self, from: body))?.error
        let retryAfter = response.value(forHTTPHeaderField: "Retry-After")
            .flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            .map(TimeInterval.init)
        self.init(
            status: response.statusCode,
            code: problem?.code ?? "",
            message: problem?.message ?? "",
            fields: problem?.fields ?? [:],
            retryAfter: retryAfter,
            requestId: response.value(forHTTPHeaderField: "X-Request-ID")
        )
    }

    public var description: String {
        message.isEmpty ? "kuaa: \(status) \(code)" : "kuaa: \(status) \(code): \(message)"
    }

    public var errorDescription: String? { description }

    private struct Body: Decodable {
        let error: Problem?
    }

    private struct Problem: Decodable {
        let code: String?
        let message: String?
        let fields: [String: [String]]?
    }
}
