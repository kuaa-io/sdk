import 'dart:convert';

/// A request the API refused.
///
/// [code] is the API's, the one to branch on: `unauthenticated`,
/// `forbidden`, `not_found`, `conflict`, `idempotency_key_reused`,
/// `validation_failed`, `payment_required`, `malformed_json`,
/// `body_too_large`, `rate_limited`… [fields] says, for `validation_failed`,
/// what is wrong with each field. [retryAfter] is how many seconds the API
/// asked to wait, on a 429 or a 503.
class KuaaException implements Exception {
  const KuaaException(
    this.status,
    this.code,
    this.message, {
    this.fields = const {},
    this.retryAfter,
    this.requestId,
  });

  /// The error a refused response carries: its status, headers and body.
  factory KuaaException.fromResponse(
    int status,
    Map<String, String> headers,
    List<int> body,
  ) {
    var problem = const <String, Object?>{};
    try {
      final decoded = jsonDecode(utf8.decode(body));
      if (decoded case {'error': final Map<String, Object?> error}) {
        problem = error;
      }
    } on FormatException {
      // A refusal without a JSON body is still a refusal.
    }
    final fields = <String, List<String>>{};
    if (problem['fields'] case final Map<String, Object?> problems) {
      for (final MapEntry(:key, :value) in problems.entries) {
        if (value is List<Object?>) {
          fields[key] = List.unmodifiable(value.map((each) => '$each'));
        }
      }
    }
    final requestId = _header(headers, 'x-request-id');
    return KuaaException(
      status,
      problem['code'] is String ? problem['code'] as String : '',
      problem['message'] is String ? problem['message'] as String : '',
      fields: Map.unmodifiable(fields),
      retryAfter: int.tryParse(_header(headers, 'retry-after')),
      requestId: requestId.isEmpty ? null : requestId,
    );
  }

  /// The HTTP status.
  final int status;

  /// The API's error code.
  final String code;

  /// What went wrong, in words.
  final String message;

  /// What is wrong with each field of the request.
  final Map<String, List<String>> fields;

  /// Seconds to wait before trying again, on a 429 or a 503.
  final int? retryAfter;

  /// The X-Request-ID header.
  final String? requestId;

  @override
  String toString() =>
      message.isEmpty ? 'kuaa: $status $code' : 'kuaa: $status $code: $message';
}

String _header(Map<String, String> headers, String name) {
  for (final MapEntry(:key, :value) in headers.entries) {
    if (key.toLowerCase() == name) {
      return value.trim();
    }
  }
  return '';
}
