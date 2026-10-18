from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Protocol
from urllib.parse import quote


@dataclass(frozen=True)
class KuaaFile:
    """One file of a multipart body."""

    filename: str
    """The name the part carries, such as frente.jpg."""
    data: bytes
    content_type: str = "application/octet-stream"
    """The file's media type: image/jpeg or image/png."""


@dataclass(frozen=True)
class ResponseInfo:
    """What the API said about an answer, beside its body."""

    status: int
    livemode: bool | None
    """The Kuaa-Livemode header: True for live, False for a sandbox, None when absent."""
    environment: str | None
    """The Kuaa-Environment header: live or sandbox."""
    idempotent_replayed: bool
    """The answer is the stored answer of an earlier request with the same Idempotency-Key."""
    request_id: str | None
    """The X-Request-ID header."""


class Requester(Protocol):
    """What a service calls the API through."""

    def request(
        self,
        method: str,
        path: str,
        *,
        query: dict[str, Any] | None = None,
        body: Any = None,
        multipart: bool = False,
        idempotency_key: str | None = None,
        api_key: str | None = None,
    ) -> dict[str, Any]: ...


def segment(value: str) -> str:
    """A path parameter, escaped."""
    return quote(value, safe="")
