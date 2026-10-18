from __future__ import annotations

import json
from collections.abc import Mapping
from typing import Any


class KuaaError(Exception):
    """A request the API refused.

    ``code`` is the API's, the one to branch on: unauthenticated, forbidden,
    not_found, conflict, idempotency_key_reused, validation_failed,
    payment_required, malformed_json, body_too_large, rate_limited…
    ``fields`` says, for validation_failed, what is wrong with each field.
    ``retry_after`` is how many seconds the API asked to wait, on a 429 or a
    503.
    """

    def __init__(
        self,
        status: int,
        code: str,
        message: str = "",
        fields: dict[str, list[str]] | None = None,
        retry_after: int | None = None,
        request_id: str | None = None,
    ) -> None:
        super().__init__(f"kuaa: {status} {code}: {message}" if message else f"kuaa: {status} {code}")
        self.status = status
        self.code = code
        self.message = message
        self.fields = fields or {}
        self.retry_after = retry_after
        self.request_id = request_id

    @classmethod
    def from_response(cls, status: int, headers: Mapping[str, str], body: bytes) -> KuaaError:
        problem: dict[str, Any] = {}
        try:
            loaded = json.loads(body or b"{}")
            if isinstance(loaded, dict) and isinstance(loaded.get("error"), dict):
                problem = loaded["error"]
        except ValueError:
            pass  # A refusal without a JSON body is still a refusal.
        retry_after = headers.get("retry-after", "").strip()
        return cls(
            status,
            str(problem.get("code") or ""),
            str(problem.get("message") or ""),
            problem.get("fields") or {},
            int(retry_after) if retry_after.isdigit() else None,
            headers.get("x-request-id"),
        )
