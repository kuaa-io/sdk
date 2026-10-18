<?php

declare(strict_types=1);

namespace Kuaa;

/**
 * One page of a list, and where the next one starts.
 *
 * @template T
 */
final class Page
{
    /**
     * @param list<T> $items
     * @param ?string $nextCursor the cursor of the next page, or null on the last one
     * @param bool $hasMore another page follows
     */
    public function __construct(
        public readonly array $items,
        public readonly ?string $nextCursor,
        public readonly bool $hasMore,
    ) {
    }

    /**
     * @template U
     * @param array<string, mixed> $envelope
     * @param callable(array<string, mixed>): U $item
     * @return Page<U>
     */
    public static function fromEnvelope(array $envelope, string $field, callable $item): self
    {
        $items = [];
        $data = is_array($envelope['data'] ?? null) ? $envelope['data'] : [];
        foreach (is_array($data[$field] ?? null) ? $data[$field] : [] as $each) {
            $items[] = $item($each);
        }
        $meta = is_array($envelope['meta'] ?? null) ? $envelope['meta'] : [];
        $next = is_string($meta['next_cursor'] ?? null) ? $meta['next_cursor'] : null;
        $hasMore = is_bool($meta['has_more'] ?? null) ? $meta['has_more'] : ($next !== null && $next !== '');
        return new self($items, $next, $hasMore);
    }

    /**
     * Walks pages from $cursor until the last one, yielding every item.
     *
     * @template U
     * @param callable(?string): Page<U> $fetch
     * @return \Generator<int, U>
     */
    public static function iterate(callable $fetch, ?string $cursor = null): \Generator
    {
        for (;;) {
            $page = $fetch($cursor);
            foreach ($page->items as $item) {
                yield $item;
            }
            if (!$page->hasMore || $page->nextCursor === null || $page->nextCursor === '') {
                return;
            }
            $cursor = $page->nextCursor;
        }
    }
}
