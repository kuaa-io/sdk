/// What a service calls the API through: [Kuaa], or a fake in a test.
abstract interface class Requester {
  /// Calls the API and answers its envelope: `data`, and a list's `meta`.
  ///
  /// A null or empty value in [query] is left out, and a list repeats its
  /// name. [multipart] sends [body] as multipart/form-data. [idempotencyKey]
  /// makes a write safe to repeat; [apiKey] sends this call with another key.
  Future<Map<String, Object?>> request(
    String method,
    String path, {
    Map<String, Object?> query,
    Map<String, Object?>? body,
    bool multipart,
    String? idempotencyKey,
    String? apiKey,
  });
}

/// One file of a multipart body.
final class FilePart {
  const FilePart(
    this.filename,
    this.data, [
    this.contentType = 'application/octet-stream',
  ]);

  /// The name the part carries, such as frente.jpg.
  final String filename;

  /// The file's bytes.
  final List<int> data;

  /// The file's media type: image/jpeg or image/png.
  final String contentType;
}

/// What the API said about an answer, beside its body.
final class ResponseInfo {
  const ResponseInfo({
    required this.status,
    required this.livemode,
    required this.environment,
    required this.idempotentReplayed,
    required this.requestId,
  });

  /// The info of an answer's status and headers, names in lower case.
  factory ResponseInfo.fromHeaders(int status, Map<String, String> headers) {
    final livemode = headers['kuaa-livemode'];
    return ResponseInfo(
      status: status,
      livemode: livemode == 'true'
          ? true
          : livemode == 'false'
          ? false
          : null,
      environment: headers['kuaa-environment'],
      idempotentReplayed: headers['idempotent-replayed'] == 'true',
      requestId: headers['x-request-id'],
    );
  }

  /// The HTTP status.
  final int status;

  /// The Kuaa-Livemode header: true for live, false for a sandbox, null when
  /// absent.
  final bool? livemode;

  /// The Kuaa-Environment header: live or sandbox.
  final String? environment;

  /// The answer is the stored answer of an earlier request with the same
  /// Idempotency-Key.
  final bool idempotentReplayed;

  /// The X-Request-ID header.
  final String? requestId;
}
