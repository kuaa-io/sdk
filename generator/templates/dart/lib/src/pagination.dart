import 'json.dart';

/// One page of a list, and where the next one starts.
final class Page<T> {
  const Page({
    required this.items,
    required this.nextCursor,
    required this.hasMore,
  });

  /// A page out of the API's envelope, its items under [field], each read by
  /// [item].
  factory Page.fromEnvelope(
    Map<String, Object?> envelope,
    String field,
    T Function(Map<String, Object?> json) item,
  ) {
    final data = readObject(envelope['data']);
    final meta = envelope['meta'] is Map<String, Object?>
        ? readObject(envelope['meta'])
        : const <String, Object?>{};
    final next = meta['next_cursor'] as String?;
    final more = meta['has_more'] as bool?;
    return Page(
      items: data[field] == null
          ? const []
          : readList(data[field], (value) => item(readObject(value))),
      nextCursor: next,
      hasMore: more ?? (next != null && next.isNotEmpty),
    );
  }

  /// The items of this page.
  final List<T> items;

  /// The cursor of the next page, or null on the last one.
  final String? nextCursor;

  /// Another page follows.
  final bool hasMore;
}

/// Walks pages from [cursor] (the first page when null) until the last one,
/// giving every item. An error ends the walk.
Stream<T> iterate<T>(
  Future<Page<T>> Function(String? cursor) fetch, [
  String? cursor,
]) async* {
  var at = cursor;
  while (true) {
    final page = await fetch(at);
    for (final item in page.items) {
      yield item;
    }
    final next = page.nextCursor;
    if (!page.hasMore || next == null || next.isEmpty) {
      return;
    }
    at = next;
  }
}
