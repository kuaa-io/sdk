/// One page of a list, and where the next one starts.
public struct Page<Item: Decodable & Sendable>: Sendable {
    /// The page's items.
    public let items: [Item]
    /// The cursor of the next page, or nil on the last one.
    public let nextCursor: String?
    /// Another page follows.
    public let hasMore: Bool

    public init(items: [Item], nextCursor: String?, hasMore: Bool) {
        self.items = items
        self.nextCursor = nextCursor
        self.hasMore = hasMore
    }
}

/// Walks pages from `cursor` (the first page when nil) until the last one,
/// yielding every item. A page is fetched only when the items before it were
/// taken, and an error ends the walk.
func iterate<Item: Decodable & Sendable>(
    from cursor: String?,
    fetch: @escaping @Sendable (String?) async throws -> Page<Item>
) -> AsyncThrowingStream<Item, any Error> {
    let pager = Pager(cursor: cursor, fetch: fetch)
    return AsyncThrowingStream { try await pager.next() }
}

private actor Pager<Item: Decodable & Sendable> {
    private var cursor: String?
    private var items: ArraySlice<Item> = []
    private var done = false
    private let fetch: @Sendable (String?) async throws -> Page<Item>

    init(cursor: String?, fetch: @escaping @Sendable (String?) async throws -> Page<Item>) {
        self.cursor = cursor
        self.fetch = fetch
    }

    func next() async throws -> Item? {
        while true {
            if let item = items.popFirst() {
                return item
            }
            if done {
                return nil
            }
            done = true
            let page = try await fetch(cursor)
            if page.hasMore, let next = page.nextCursor, !next.isEmpty {
                cursor = next
                done = false
            }
            items = page.items[...]
        }
    }
}
