import Foundation

#if canImport(CryptoKit)
    import CryptoKit
#endif

/// The header with the delivery id, the same on every retry.
public let webhookHeaderDeliveryID = "X-Arandu-Delivery-Id"
/// The header with the Unix time, in seconds, the attempt was signed at.
public let webhookHeaderTimestamp = "X-Arandu-Timestamp"
/// The header with the signatures, one line per secret still signing.
public let webhookHeaderSignature = "X-Arandu-Signature"

/// How far from now, in seconds, a delivery's timestamp may be, either way.
public let webhookTolerance: TimeInterval = 300

/// One signature per secret still signing: the current one and at most five
/// previous ones.
private let maxSignatures = 6

/// Why a delivery was not accepted.
public enum WebhookVerificationError: Error, Sendable, Equatable {
    /// The secret is empty.
    case invalidSecret
    /// KUAA did not sign the delivery with the secret, or signed it too long
    /// ago.
    case invalidSignature
}

#if canImport(CryptoKit)
    /// Checks a delivery KUAA sent and answers its event, a CloudEvents 1.0
    /// envelope. The signature is
    /// `sha256=hex(HMAC-SHA256(secret, timestamp + "." + delivery_id + "." + body))`,
    /// keyed with the endpoint's secret exactly as it was shown; during a
    /// rotation the X-Arandu-Signature header comes once per secret, and any
    /// one matching is enough. A timestamp more than five minutes from now is
    /// refused. Pass the body exactly as it arrived, before parsing it, and
    /// deduplicate on the event's id: delivery is at least once.
    ///
    /// - Parameters:
    ///   - headers: the request's headers, their names in any case, each with
    ///     every line it came with.
    ///   - now: the moment to check the timestamp against.
    public func verifyWebhook(secret: String, headers: [String: [String]], body: Data, now: Date = Date()) throws -> WebhookEvent {
        guard !secret.isEmpty else {
            throw WebhookVerificationError.invalidSecret
        }
        func values(_ name: String) -> [String] {
            headers.filter { $0.key.lowercased() == name.lowercased() }.flatMap(\.value)
        }
        let delivery = values(webhookHeaderDeliveryID).first?.trimmingCharacters(in: .whitespaces) ?? ""
        let stamp = values(webhookHeaderTimestamp).first?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !delivery.isEmpty, !stamp.isEmpty, stamp.allSatisfy({ $0.isASCII && $0.isNumber }), let seconds = Int64(stamp) else {
            throw WebhookVerificationError.invalidSignature
        }
        guard abs(now.timeIntervalSince1970 - TimeInterval(seconds)) <= webhookTolerance else {
            throw WebhookVerificationError.invalidSignature
        }
        let signature = values(webhookHeaderSignature).joined(separator: ",")
        let entries = signature.split(separator: ",", omittingEmptySubsequences: false)
        guard !signature.trimmingCharacters(in: .whitespaces).isEmpty, entries.count <= maxSignatures else {
            throw WebhookVerificationError.invalidSignature
        }
        var given: [Data] = []
        for entry in entries {
            let trimmed = entry.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("sha256="), let decoded = hex(String(trimmed.dropFirst("sha256=".count))) else {
                throw WebhookVerificationError.invalidSignature
            }
            given.append(decoded)
        }
        let signed = Data("\(stamp).\(delivery).".utf8) + body
        let key = SymmetricKey(data: Data(secret.utf8))
        var matched = false
        for each in given {
            // isValidAuthenticationCode compares in constant time.
            matched = HMAC<SHA256>.isValidAuthenticationCode(each, authenticating: signed, using: key) || matched
        }
        guard matched else {
            throw WebhookVerificationError.invalidSignature
        }
        return try JSONDecoder().decode(WebhookEvent.self, from: body)
    }

    /// `verifyWebhook` for headers with one value each, such as
    /// `HTTPURLResponse.allHeaderFields` or a framework's map; a repeated
    /// header joined with commas verifies the same.
    public func verifyWebhook(secret: String, headers: [String: String], body: Data, now: Date = Date()) throws -> WebhookEvent {
        try verifyWebhook(secret: secret, headers: headers.mapValues { [$0] }, body: body, now: now)
    }
#endif

/// The 32 bytes 64 hexadecimal digits write, or nil.
private func hex(_ text: String) -> Data? {
    guard text.count == 64, text.allSatisfy(\.isHexDigit) else {
        return nil
    }
    var out = Data()
    var index = text.startIndex
    while index < text.endIndex {
        let next = text.index(index, offsetBy: 2)
        guard let byte = UInt8(text[index..<next], radix: 16) else {
            return nil
        }
        out.append(byte)
        index = next
    }
    return out
}
