from __future__ import annotations

from collections.abc import Callable, Iterator
from dataclasses import dataclass
from typing import Any, Generic, TypeVar

T = TypeVar("T")


@dataclass(frozen=True)
class Page(Generic[T]):
    """One page of a list, and where the next one starts."""

    items: list[T]
    next_cursor: str | None
    """The cursor of the next page, or None on the last one."""
    has_more: bool
    """Another page follows."""

    @classmethod
    def from_envelope(cls, envelope: dict[str, Any], field: str, item: Callable[[dict[str, Any]], T]) -> Page[T]:
        meta = envelope.get("meta") or {}
        next_cursor = meta.get("next_cursor")
        has_more = meta.get("has_more")
        return cls(
            items=[item(each) for each in (envelope.get("data") or {}).get(field) or []],
            next_cursor=next_cursor,
            has_more=bool(next_cursor) if has_more is None else bool(has_more),
        )


def iterate(fetch: Callable[[str | None], Page[T]], cursor: str | None = None) -> Iterator[T]:
    """Walks pages from ``cursor`` until the last one, yielding every item."""
    while True:
        page = fetch(cursor)
        yield from page.items
        if not page.has_more or not page.next_cursor:
            return
        cursor = page.next_cursor
