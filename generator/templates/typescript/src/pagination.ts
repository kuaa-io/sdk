import type { Envelope } from "./core.ts";

/** One page of a list, and where the next one starts. */
export interface Page<T> {
  items: T[];
  /** The cursor of the next page, or null on the last one. */
  nextCursor: string | null;
  /** Another page follows. */
  hasMore: boolean;
}

/** The page an envelope carries, its items under `field`. */
export function pageOf<T>(envelope: Envelope, field: string): Page<T> {
  const items = (envelope.data[field] as T[] | undefined) ?? [];
  const nextCursor = envelope.meta?.next_cursor ?? null;
  return { items, nextCursor, hasMore: envelope.meta?.has_more ?? (nextCursor !== null && nextCursor !== "") };
}

/** Walks pages from `cursor` until the last one, yielding every item. An error ends the walk. */
export async function* iterate<T>(fetch: (cursor: string | undefined) => Promise<Page<T>>, cursor?: string): AsyncGenerator<T, void, undefined> {
  for (;;) {
    const page = await fetch(cursor);
    yield* page.items;
    if (!page.hasMore || !page.nextCursor) {
      return;
    }
    cursor = page.nextCursor;
  }
}
