<?php

declare(strict_types=1);

namespace Kuaa;

/** A delivery KUAA did not sign with the secret, or signed too long ago. */
final class WebhookVerificationException extends \RuntimeException
{
    public function __construct(string $message = 'kuaa: webhook signature does not verify')
    {
        parent::__construct($message);
    }
}
