package io.kuaa;

import java.util.Collections;
import java.util.Iterator;
import java.util.List;
import java.util.Map;
import java.util.NoSuchElementException;
import java.util.function.Function;

/**
 * One page of a list, and where the next one starts.
 *
 * @param <T> the object listed
 */
public final class Page<T> {
    private final List<T> items;
    private final String nextCursor;
    private final boolean hasMore;

    /**
     * A page.
     *
     * @param items the page's items
     * @param nextCursor the cursor of the next page, or null on the last one
     * @param hasMore whether another page follows
     */
    public Page(List<T> items, String nextCursor, boolean hasMore) {
        this.items = Collections.unmodifiableList(items);
        this.nextCursor = nextCursor;
        this.hasMore = hasMore;
    }

    /** @return the page's items */
    public List<T> getItems() {
        return items;
    }

    /** @return the cursor of the next page, or null on the last one */
    public String getNextCursor() {
        return nextCursor;
    }

    /** @return whether another page follows */
    public boolean hasMore() {
        return hasMore;
    }

    static <T> Page<T> fromEnvelope(Map<String, Object> envelope, String field, Function<Object, T> item) {
        Map<String, Object> data = Json.required(envelope, "data", Json::asObject);
        List<T> items = Json.optional(data, field, Json.list(item));
        Map<String, Object> meta = Json.optional(envelope, "meta", Json::asObject);
        String next = meta == null ? null : Json.optional(meta, "next_cursor", Json::asString);
        Boolean more = meta == null ? null : Json.optional(meta, "has_more", Json::asBoolean);
        return new Page<>(items == null ? Collections.emptyList() : items, next,
                more != null ? more : next != null && !next.isEmpty());
    }

    /**
     * Walks pages from cursor (the first page when null) until the last one,
     * fetching each page only when the previous one is used up.
     */
    static <T> Iterable<T> iterate(Function<String, Page<T>> fetch, String cursor) {
        return () -> new Iterator<T>() {
            private String next = cursor;
            private Iterator<T> items = Collections.emptyIterator();
            private boolean last;

            @Override
            public boolean hasNext() {
                while (!items.hasNext()) {
                    if (last) {
                        return false;
                    }
                    Page<T> page = fetch.apply(next);
                    items = page.getItems().iterator();
                    next = page.getNextCursor();
                    last = !page.hasMore() || next == null || next.isEmpty();
                }
                return true;
            }

            @Override
            public T next() {
                if (!hasNext()) {
                    throw new NoSuchElementException();
                }
                return items.next();
            }
        };
    }
}
