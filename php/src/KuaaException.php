<?php

declare(strict_types=1);

namespace Kuaa;

/**
 * A request the API refused. $errorCode is the API's, the one to branch on:
 * unauthenticated, forbidden, not_found, conflict, idempotency_key_reused,
 * validation_failed, payment_required, malformed_json, body_too_large,
 * rate_limited… $fields says, for validation_failed, what is wrong with each
 * field. $retryAfter is how many seconds the API asked to wait, on a 429 or
 * a 503.
 */
final class KuaaException extends \RuntimeException
{
    /**
     * @param array<string, list<string>> $fields
     */
    public function __construct(
        public readonly int $status,
        public readonly string $errorCode,
        string $message = '',
        public readonly array $fields = [],
        public readonly ?int $retryAfter = null,
        public readonly ?string $requestId = null,
    ) {
        parent::__construct($message !== '' ? "kuaa: {$status} {$errorCode}: {$message}" : "kuaa: {$status} {$errorCode}", $status);
    }

    /**
     * @param array<string, string> $headers in lower case
     */
    public static function fromResponse(int $status, array $headers, string $body): self
    {
        $data = json_decode($body, true);
        $problem = is_array($data) && is_array($data['error'] ?? null) ? $data['error'] : []; // A refusal without a JSON body is still a refusal.
        $retryAfter = trim($headers['retry-after'] ?? '');
        /** @var array<string, list<string>> $fields */
        $fields = is_array($problem['fields'] ?? null) ? $problem['fields'] : [];
        return new self(
            $status,
            is_string($problem['code'] ?? null) ? $problem['code'] : '',
            is_string($problem['message'] ?? null) ? $problem['message'] : '',
            $fields,
            ctype_digit($retryAfter) ? (int) $retryAfter : null,
            $headers['x-request-id'] ?? null,
        );
    }
}
