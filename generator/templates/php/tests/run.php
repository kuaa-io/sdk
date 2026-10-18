<?php

// KUAA's PHP SDK tests, with no dependency to install: php tests/run.php

declare(strict_types=1);

use Kuaa\File;
use Kuaa\Kuaa;
use Kuaa\KuaaException;
use Kuaa\Webhook;
use Kuaa\WebhookVerificationException;

spl_autoload_register(static function (string $class): void {
    if (str_starts_with($class, 'Kuaa\\')) {
        require __DIR__ . '/../src/' . str_replace('\\', '/', substr($class, 5)) . '.php';
    }
});

$tests = [];
$failures = 0;

function check(bool $condition, string $what): void
{
    if (!$condition) {
        throw new \RuntimeException($what);
    }
}

/**
 * @param callable(array{method: string, url: string, headers: array<string, string>, body: ?string}): array{0: int, 1: array<string, string>, 2: mixed} $answer
 * @return array{0: Kuaa, 1: \ArrayObject<int, array{method: string, url: string, headers: array<string, string>, body: ?string}>}
 */
function client(callable $answer): array
{
    $seen = new \ArrayObject();
    $transport = static function (string $method, string $url, array $headers, ?string $body, float $timeout) use ($answer, $seen): array {
        $request = ['method' => $method, 'url' => $url, 'headers' => $headers, 'body' => $body];
        $seen[] = $request;
        [$status, $extra, $payload] = $answer($request);
        return [$status, $extra, $payload === null ? '' : json_encode($payload)];
    };
    return [new Kuaa('kuaa_test_abc_secret', 'http://kuaa.test/', transport: $transport), $seen];
}

function kase(): array
{
    return [
        'id' => 'case_1', 'external_reference' => 'pedido-1', 'kind' => 'KYC', 'status' => 'open', 'status_market' => 'PROCESSING', 'livemode' => false,
        'custom_status' => null, 'current_state' => 'collect_identity', 'workflow_definition_id' => null, 'policy_version_id' => null,
        'parent_case_id' => null, 'child_group' => null, 'parties' => [['id' => 'party_1', 'kind' => 'PERSON', 'primary' => true, 'identity_id' => null, 'cpf' => '12345678909']],
        'relationships' => [], 'created_at' => '2027-01-15T08:00:00Z', 'updated_at' => '2027-01-15T08:00:00Z',
    ];
}

function summary(string $id): array
{
    return [
        'id' => $id, 'external_reference' => "ref-{$id}", 'kind' => 'KYC', 'status' => 'open', 'status_market' => 'PROCESSING', 'livemode' => false,
        'current_state' => 'start', 'workflow_definition_id' => null, 'workflow_version_id' => null, 'policy_version_id' => null,
        'created_at' => '2027-01-15T08:00:00Z', 'updated_at' => '2027-01-15T08:00:00Z',
    ];
}

$tests['a call carries the key and unwraps the data'] = static function (): void {
    [$kuaa, $seen] = client(static fn (): array => [200, ['kuaa-livemode' => 'false', 'kuaa-environment' => 'sandbox', 'x-request-id' => 'req_1'], ['data' => kase()]]);
    $got = $kuaa->cases->get('case_1');
    check($got->id === 'case_1' && $got->status === 'open' && $got->parties[0]->cpf === '12345678909', 'case');
    check($seen[0]['method'] === 'GET' && $seen[0]['url'] === 'http://kuaa.test/v1/cases/case_1', 'request ' . $seen[0]['url']);
    check($seen[0]['headers']['Authorization'] === 'Bearer kuaa_test_abc_secret', 'key');
    $last = $kuaa->lastResponse;
    check($last !== null && $last->status === 200 && $last->livemode === false && $last->environment === 'sandbox' && $last->requestId === 'req_1', 'last response');
};

$tests['a write sends its body and idempotency key'] = static function (): void {
    [$kuaa, $seen] = client(static fn (): array => [200, ['idempotent-replayed' => 'true'], ['data' => kase(), 'meta' => ['created' => false]]]);
    $got = $kuaa->cases->create(['external_reference' => 'pedido-1', 'kind' => 'KYC'], idempotencyKey: 'pedido-1');
    check($got->externalReference === 'pedido-1', 'case');
    check($seen[0]['method'] === 'POST' && $seen[0]['headers']['Idempotency-Key'] === 'pedido-1' && $seen[0]['headers']['Content-Type'] === 'application/json', 'request');
    check(json_decode((string) $seen[0]['body'], true) === ['external_reference' => 'pedido-1', 'kind' => 'KYC'], 'body ' . $seen[0]['body']);
    check($kuaa->lastResponse?->idempotentReplayed === true, 'replayed');
};

$tests['iterating walks every page by cursor'] = static function (): void {
    $next = ['' => 'c2', 'c2' => 'c3', 'c3' => null];
    $ids = ['' => 'case_1', 'c2' => 'case_2', 'c3' => 'case_3'];
    [$kuaa, $seen] = client(static function (array $request) use ($next, $ids): array {
        parse_str((string) parse_url($request['url'], PHP_URL_QUERY), $query);
        check(($query['limit'] ?? '') === '1' && ($query['status'] ?? '') === 'open', 'query ' . $request['url']);
        $cursor = $query['cursor'] ?? '';
        return [200, [], ['data' => ['livemode' => false, 'cases' => [summary($ids[$cursor])]], 'meta' => ['next_cursor' => $next[$cursor], 'has_more' => $next[$cursor] !== null, 'limit' => 1]]];
    });
    $walked = [];
    foreach ($kuaa->cases->listIter(['limit' => 1, 'status' => 'open']) as $item) {
        $walked[] = $item->id;
    }
    check($walked === ['case_1', 'case_2', 'case_3'], 'walked ' . implode(',', $walked));
    check(count($seen) === 3, 'pages');
};

$tests['a refusal is a typed error'] = static function (): void {
    [$kuaa] = client(static fn (array $request): array => str_ends_with($request['url'], '/v1/cases')
        ? [422, [], ['error' => ['code' => 'validation_failed', 'message' => 'The input has invalid fields.', 'fields' => ['kind' => ['must be KYC, KYB or AGE']]]]]
        : [429, ['retry-after' => '7'], ['error' => ['code' => 'rate_limited', 'message' => 'Too many requests.']]]);
    try {
        $kuaa->cases->create(['external_reference' => 'x', 'kind' => 'KYC']);
        check(false, 'a 422 did not throw');
    } catch (KuaaException $refused) {
        check($refused->status === 422 && $refused->errorCode === 'validation_failed' && $refused->fields['kind'] === ['must be KYC, KYB or AGE'], 'refusal');
    }
    try {
        $kuaa->cases->get('case_1');
        check(false, 'a 429 did not throw');
    } catch (KuaaException $limited) {
        check($limited->status === 429 && $limited->errorCode === 'rate_limited' && $limited->retryAfter === 7, 'retry after');
    }
};

$tests['a capture is sent as multipart'] = static function (): void {
    $document = ['id' => 'doc_1', 'capture' => 'document', 'party_id' => 'party_1', 'status' => 'received', 'artifact_id' => null, 'created_at' => '2027-01-15T08:00:00Z'];
    [$kuaa, $seen] = client(static fn (): array => [201, [], ['data' => ['documents' => [$document]]]]);
    $got = $kuaa->caseMedia->create('case_1', [
        'kind' => 'document',
        'document_type' => 'CNH',
        'side' => 'front',
        'file' => [new File('frente.jpg', "\xff\xd8 frente", 'image/jpeg'), new File('verso.jpg', 'verso', 'image/jpeg')],
    ], idempotencyKey: 'captura-1');
    check($got->documents[0]->id === 'doc_1', 'capture');
    $type = $seen[0]['headers']['Content-Type'];
    check(str_starts_with($type, 'multipart/form-data; boundary=') && $seen[0]['headers']['Idempotency-Key'] === 'captura-1', 'type ' . $type);
    $boundary = substr($type, strlen('multipart/form-data; boundary='));
    $body = (string) $seen[0]['body'];
    check(str_contains($body, "Content-Disposition: form-data; name=\"kind\"\r\n\r\ndocument\r\n"), 'kind');
    check(str_contains($body, "Content-Disposition: form-data; name=\"file\"; filename=\"frente.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n\xff\xd8 frente\r\n"), 'file');
    check(str_contains($body, 'filename="verso.jpg"') && !str_contains($body, 'name="party_id"') && str_ends_with($body, "--{$boundary}--\r\n"), 'body');
};

$tests['a list query repeats its name'] = static function (): void {
    [$kuaa, $seen] = client(static fn (): array => [200, [], ['data' => ['case_id' => 'case_1', 'tags' => []]]]);
    $got = $kuaa->caseTags->delete('case_1', ['tag' => ['prioridade', 'revisar']]);
    check($got->caseId === 'case_1' && $seen[0]['method'] === 'DELETE' && $seen[0]['url'] === 'http://kuaa.test/v1/cases/case_1/tags?tag=prioridade&tag=revisar', 'request ' . $seen[0]['url']);
};

// The vectors are generated once, in Go, by sdk/generator, and every SDK
// checks its verification against them.
$tests['the webhook vectors'] = static function (): void {
    $vectors = json_decode((string) file_get_contents(__DIR__ . '/webhook-vectors.json'), true, 512, JSON_THROW_ON_ERROR);
    check($vectors['tolerance_seconds'] === Webhook::TOLERANCE_SECONDS && $vectors['vectors'] !== [], 'tolerance');
    foreach ($vectors['vectors'] as $vector) {
        try {
            $event = Webhook::verify($vector['secret'], $vector['headers'], $vector['body'], $vector['now']);
        } catch (WebhookVerificationException) {
            check(!$vector['valid'], $vector['name'] . ': refused');
            continue;
        }
        check($vector['valid'], $vector['name'] . ': verified');
        $want = $vector['event'];
        check(
            $event->specversion === '1.0' && $event->id === $want['id'] && $event->type === $want['type'] && $event->source === $want['source']
                && $event->subject === $want['subject'] && $event->data->caseId === $want['case_id'] && $event->data->status === $want['status']
                && $event->data->environment === $want['environment'] && $event->data->livemode === $want['livemode'],
            $vector['name'] . ': event',
        );
    }
};

$tests['the real HTTP sends and reads through curl'] = static function (): void {
    $socket = stream_socket_server('tcp://127.0.0.1:0');
    $port = (int) substr((string) strrchr((string) stream_socket_get_name($socket, false), ':'), 1);
    fclose($socket);
    $server = proc_open([PHP_BINARY, '-S', "127.0.0.1:{$port}", __DIR__ . '/server.php'], [1 => ['file', '/dev/null', 'w'], 2 => ['file', '/dev/null', 'w']], $pipes);
    try {
        for ($tries = 0; $tries < 50 && @fsockopen('127.0.0.1', $port) === false; $tries++) {
            usleep(100_000);
        }
        $kuaa = new Kuaa('kuaa_test_abc_secret', "http://127.0.0.1:{$port}");
        $tags = $kuaa->caseTags->create('case 1/2', ['tags' => ['prioridade']], idempotencyKey: 'tag-1');
        check($tags->tags[0]->name === 'prioridade' && $tags->tags[0]->slug === 'tag-1' && $tags->tags[0]->createdAt === 'POST /v1/cases/case%201%2F2/tags', 'over HTTP: ' . json_encode($tags));
        check($kuaa->lastResponse?->livemode === false && $kuaa->lastResponse->environment === 'sandbox', 'over HTTP livemode');
        try {
            (new Kuaa('kuaa_test_other', "http://127.0.0.1:{$port}"))->cases->get('case_1');
            check(false, 'a 401 did not throw');
        } catch (KuaaException $refused) {
            check($refused->status === 401 && $refused->errorCode === 'unauthenticated' && $refused->retryAfter === 3 && $refused->requestId === 'req_401', 'over HTTP refusal');
        }
    } finally {
        proc_terminate($server);
        proc_close($server);
    }
};

foreach ($tests as $name => $test) {
    try {
        $test();
        echo "ok   {$name}\n";
    } catch (\Throwable $error) {
        $failures++;
        echo "FAIL {$name}: {$error->getMessage()}\n";
    }
}
echo $failures === 0 ? "\nPASS " . count($tests) . " tests\n" : "\nFAIL {$failures} of " . count($tests) . " tests\n";
exit($failures === 0 ? 0 : 1);
