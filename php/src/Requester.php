<?php

declare(strict_types=1);

namespace Kuaa;

/** What a service calls the API through. */
interface Requester
{
    /**
     * Calls the API and answers its envelope: data, and a list's meta.
     *
     * @param array<string, mixed> $query
     * @param array<string, mixed>|null $body
     * @return array<string, mixed>
     */
    public function request(string $method, string $path, array $query = [], ?array $body = null, bool $multipart = false, ?string $idempotencyKey = null, ?string $apiKey = null): array;
}
