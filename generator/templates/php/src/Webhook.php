<?php

declare(strict_types=1);

namespace Kuaa;

use Kuaa\Models\WebhookEvent;

/** Verifying the webhooks KUAA sends. */
final class Webhook
{
    public const HEADER_DELIVERY_ID = 'X-Arandu-Delivery-Id';
    public const HEADER_TIMESTAMP = 'X-Arandu-Timestamp';
    public const HEADER_SIGNATURE = 'X-Arandu-Signature';

    /** How far from now, in seconds, a delivery's timestamp may be, either way. */
    public const TOLERANCE_SECONDS = 300;

    /** One signature per secret still signing: the current one and at most five previous ones. */
    private const MAX_SIGNATURES = 6;

    /**
     * Checks a delivery KUAA sent and answers its event, a CloudEvents 1.0
     * envelope. The signature is
     * sha256=hex(HMAC-SHA256(secret, timestamp + "." + delivery_id + "." + body)),
     * keyed with the endpoint's secret exactly as it was shown; during a
     * rotation the X-Arandu-Signature header comes once per secret, and any
     * one matching is enough. A timestamp more than five minutes from now is
     * refused. Pass the body exactly as it arrived
     * (file_get_contents('php://input')), before decoding it, and deduplicate
     * on the event's id: delivery is at least once.
     *
     * @param array<string, string|list<string>> $headers getallheaders(), $_SERVER or any map of the request's headers
     */
    public static function verify(string $secret, array $headers, string $body, ?int $now = null): WebhookEvent
    {
        if ($secret === '') {
            throw new \InvalidArgumentException('kuaa: the webhook secret is empty');
        }
        $delivery = trim(self::values($headers, self::HEADER_DELIVERY_ID)[0] ?? '');
        $stamp = trim(self::values($headers, self::HEADER_TIMESTAMP)[0] ?? '');
        if ($delivery === '' || !ctype_digit($stamp) || abs(($now ?? time()) - (int) $stamp) > self::TOLERANCE_SECONDS) {
            throw new WebhookVerificationException();
        }
        $signature = implode(',', self::values($headers, self::HEADER_SIGNATURE));
        $entries = explode(',', $signature);
        if (trim($signature) === '' || count($entries) > self::MAX_SIGNATURES) {
            throw new WebhookVerificationException();
        }
        $given = [];
        foreach ($entries as $entry) {
            $entry = trim($entry);
            $digest = str_starts_with($entry, 'sha256=') ? substr($entry, 7) : '';
            if (preg_match('/^[0-9a-fA-F]{64}$/', $digest) !== 1) {
                throw new WebhookVerificationException();
            }
            $given[] = strtolower($digest);
        }
        $expected = hash_hmac('sha256', "{$stamp}.{$delivery}.{$body}", $secret);
        $matched = false;
        foreach ($given as $each) {
            if (hash_equals($expected, $each)) {
                $matched = true;
            }
        }
        if (!$matched) {
            throw new WebhookVerificationException();
        }
        $event = json_decode($body, true, 512, JSON_THROW_ON_ERROR);
        if (!is_array($event)) {
            throw new WebhookVerificationException('kuaa: the webhook body is not a JSON object');
        }
        /** @var array<string, mixed> $event */
        return WebhookEvent::fromArray($event);
    }

    /**
     * Every value of a header, in any case; $_SERVER's HTTP_X_ARANDU_… names it too.
     *
     * @param array<string, string|list<string>> $headers
     * @return list<string>
     */
    private static function values(array $headers, string $name): array
    {
        $wanted = strtolower($name);
        $out = [];
        foreach ($headers as $key => $value) {
            $normalized = str_replace('_', '-', strtolower((string) $key));
            if (str_starts_with($normalized, 'http-')) {
                $normalized = substr($normalized, 5);
            }
            if ($normalized === $wanted) {
                foreach (is_array($value) ? $value : [$value] as $each) {
                    $out[] = (string) $each;
                }
            }
        }
        return $out;
    }
}
