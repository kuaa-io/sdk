<?php

declare(strict_types=1);

namespace Kuaa;

/** What the API said about an answer, beside its body. */
final class ResponseInfo
{
    /**
     * @param ?bool $livemode the Kuaa-Livemode header: true for live, false for a sandbox, null when absent
     * @param ?string $environment the Kuaa-Environment header: live or sandbox
     * @param bool $idempotentReplayed the answer is the stored answer of an earlier request with the same Idempotency-Key
     * @param ?string $requestId the X-Request-ID header
     */
    public function __construct(
        public readonly int $status,
        public readonly ?bool $livemode,
        public readonly ?string $environment,
        public readonly bool $idempotentReplayed,
        public readonly ?string $requestId,
    ) {
    }

    /**
     * @param array<string, string> $headers in lower case
     */
    public static function fromHeaders(int $status, array $headers): self
    {
        $livemode = $headers['kuaa-livemode'] ?? null;
        return new self(
            $status,
            $livemode === 'true' ? true : ($livemode === 'false' ? false : null),
            $headers['kuaa-environment'] ?? null,
            ($headers['idempotent-replayed'] ?? '') === 'true',
            $headers['x-request-id'] ?? null,
        );
    }
}
