"""Verifying the webhooks KUAA sends."""

from __future__ import annotations

import hashlib
import hmac
import json
import re
import time
from collections.abc import Iterable, Mapping

from .models import WebhookEvent

WEBHOOK_HEADER_DELIVERY_ID = "X-Arandu-Delivery-Id"
WEBHOOK_HEADER_TIMESTAMP = "X-Arandu-Timestamp"
WEBHOOK_HEADER_SIGNATURE = "X-Arandu-Signature"

WEBHOOK_TOLERANCE_SECONDS = 300
"""How far from now a delivery's timestamp may be, either way."""

_MAX_SIGNATURES = 6
"""One signature per secret still signing: the current one and at most five previous ones."""

_HEX = re.compile(r"[0-9a-fA-F]{64}")


class WebhookVerificationError(Exception):
    """A delivery KUAA did not sign with the secret, or signed too long ago."""

    def __init__(self, message: str = "kuaa: webhook signature does not verify") -> None:
        super().__init__(message)


def _values(headers: Mapping[str, str | Iterable[str]], name: str) -> list[str]:
    """Every value of a header, in any case; a Rack-style HTTP_X_ARANDU_… key names it too."""
    out: list[str] = []
    wanted = name.lower()
    for key, value in headers.items():
        normalized = key.lower().replace("_", "-")
        if normalized.startswith("http-"):
            normalized = normalized[len("http-") :]
        if normalized == wanted:
            if isinstance(value, str):
                out.append(value)
            else:
                out.extend(value)
    return out


def verify_webhook(secret: str, headers: Mapping[str, str | Iterable[str]], body: bytes | str, now: float | None = None) -> WebhookEvent:
    """Checks a delivery KUAA sent and answers its event, a CloudEvents 1.0 envelope.

    The signature is ``sha256=hex(HMAC-SHA256(secret, timestamp + "." +
    delivery_id + "." + body))``, keyed with the endpoint's secret exactly as
    it was shown; during a rotation the X-Arandu-Signature header comes once
    per secret, and any one matching is enough. A timestamp more than five
    minutes from now is refused. Pass the body exactly as it arrived, before
    parsing it, and deduplicate on the event's id: delivery is at least once.
    """
    if not secret:
        raise ValueError("kuaa: the webhook secret is empty")
    raw = body.encode() if isinstance(body, str) else body
    deliveries = _values(headers, WEBHOOK_HEADER_DELIVERY_ID)
    stamps = _values(headers, WEBHOOK_HEADER_TIMESTAMP)
    delivery = deliveries[0].strip() if deliveries else ""
    stamp = stamps[0].strip() if stamps else ""
    if not delivery or not stamp.isascii() or not stamp.isdigit():
        raise WebhookVerificationError()
    if abs(int(time.time() if now is None else now) - int(stamp)) > WEBHOOK_TOLERANCE_SECONDS:
        raise WebhookVerificationError()
    signature = ",".join(_values(headers, WEBHOOK_HEADER_SIGNATURE))
    entries = signature.split(",")
    if not signature.strip() or len(entries) > _MAX_SIGNATURES:
        raise WebhookVerificationError()
    given: list[bytes] = []
    for entry in entries:
        entry = entry.strip()
        digest = entry[len("sha256=") :] if entry.startswith("sha256=") else ""
        if not _HEX.fullmatch(digest):
            raise WebhookVerificationError()
        given.append(bytes.fromhex(digest))
    expected = hmac.new(secret.encode(), f"{stamp}.{delivery}.".encode() + raw, hashlib.sha256).digest()
    matched = False
    for each in given:
        if hmac.compare_digest(each, expected):
            matched = True
    if not matched:
        raise WebhookVerificationError()
    return WebhookEvent.from_dict(json.loads(raw))
