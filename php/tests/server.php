<?php

// The router `php -S` runs for the test of the real HTTP: it answers what it
// was sent, as the API wraps a case's tags.

declare(strict_types=1);

header('Content-Type: application/json');
if (($_SERVER['HTTP_AUTHORIZATION'] ?? '') !== 'Bearer kuaa_test_abc_secret') {
    http_response_code(401);
    header('Retry-After: 3');
    header('X-Request-ID: req_401');
    echo json_encode(['error' => ['code' => 'unauthenticated', 'message' => 'Send Authorization: Bearer kuaa_<prefix>_<secret>.']]);
    return;
}
header('Kuaa-Livemode: false');
header('Kuaa-Environment: sandbox');
$body = (string) file_get_contents('php://input');
$tags = [];
foreach (json_decode($body, true)['tags'] ?? [] as $name) {
    $tags[] = ['id' => 'tag_' . $name, 'name' => $name, 'slug' => $_SERVER['HTTP_IDEMPOTENCY_KEY'] ?? '', 'created_at' => $_SERVER['REQUEST_METHOD'] . ' ' . $_SERVER['REQUEST_URI']];
}
echo json_encode(['data' => ['case_id' => 'case_1', 'tags' => $tags]]);
