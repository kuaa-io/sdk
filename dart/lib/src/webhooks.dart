import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'models.dart';

/// The header with the delivery id, the same on every retry.
const webhookHeaderDeliveryId = 'X-Arandu-Delivery-Id';

/// The header with the Unix time, in seconds, the attempt was signed at.
const webhookHeaderTimestamp = 'X-Arandu-Timestamp';

/// The header with the signatures, one line per secret still signing.
const webhookHeaderSignature = 'X-Arandu-Signature';

/// How far from now a delivery's timestamp may be, either way.
const webhookTolerance = Duration(minutes: 5);

/// One signature per secret still signing: the current one and at most five
/// previous ones.
const _maxSignatures = 6;

final _digits = RegExp(r'^[0-9]+$');
final _hex = RegExp(r'^[0-9a-fA-F]{64}$');

/// A delivery KUAA did not sign with the secret, or signed too long ago.
class WebhookVerificationException implements Exception {
  const WebhookVerificationException([
    this.message = 'kuaa: webhook signature does not verify',
  ]);

  final String message;

  @override
  String toString() => message;
}

/// Checks a delivery KUAA sent and answers its event, a CloudEvents 1.0
/// envelope.
///
/// The signature is
/// `sha256=hex(HMAC-SHA256(secret, timestamp + "." + delivery_id + "." + body))`,
/// keyed with the endpoint's [secret] exactly as it was shown; during a
/// rotation the X-Arandu-Signature header comes once per secret, and any one
/// matching is enough. A timestamp more than five minutes from now is
/// refused. [headers] are the request's, names in any case, each a `String`
/// or a `List<String>` of its lines; [body] is a `String` or the bytes
/// (`List<int>`), exactly as they arrived, before parsing them. Throws
/// [WebhookVerificationException] when the signature does not verify.
/// Deduplicate on the event's id: delivery is at least once.
WebhookEvent verifyWebhook(
  String secret,
  Map<String, Object?> headers,
  Object body, {
  DateTime? now,
}) {
  if (secret.isEmpty) {
    throw ArgumentError.value(secret, 'secret', 'kuaa: the secret is empty');
  }
  final List<int> raw = switch (body) {
    String text => utf8.encode(text),
    List<int> bytes => bytes,
    _ => throw ArgumentError.value(body, 'body', 'a String or a List<int>'),
  };
  final delivery = _first(_values(headers, webhookHeaderDeliveryId));
  final stamp = _first(_values(headers, webhookHeaderTimestamp));
  final seconds = _digits.hasMatch(stamp) ? int.tryParse(stamp) : null;
  if (delivery.isEmpty || seconds == null) {
    throw const WebhookVerificationException();
  }
  final at = DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
  if ((now ?? DateTime.now()).difference(at).abs() > webhookTolerance) {
    throw const WebhookVerificationException();
  }
  final signature = _values(headers, webhookHeaderSignature).join(',');
  final entries = signature.split(',');
  if (signature.trim().isEmpty || entries.length > _maxSignatures) {
    throw const WebhookVerificationException();
  }
  final given = <List<int>>[];
  for (final entry in entries) {
    final trimmed = entry.trim();
    final digest = trimmed.startsWith('sha256=') ? trimmed.substring(7) : '';
    if (!_hex.hasMatch(digest)) {
      throw const WebhookVerificationException();
    }
    given.add([
      for (var i = 0; i < 64; i += 2)
        int.parse(digest.substring(i, i + 2), radix: 16),
    ]);
  }
  final expected = Hmac(
    sha256,
    utf8.encode(secret),
  ).convert([...utf8.encode('$stamp.$delivery.'), ...raw]).bytes;
  var matched = false;
  for (final each in given) {
    matched = _equal(each, expected) || matched;
  }
  if (!matched) {
    throw const WebhookVerificationException();
  }
  final json = jsonDecode(utf8.decode(raw));
  if (json is Map<String, Object?>) {
    return WebhookEvent.fromJson(json);
  }
  throw const FormatException('kuaa: the webhook body is not an event');
}

String _first(List<String> values) => values.isEmpty ? '' : values.first.trim();

List<String> _values(Map<String, Object?> headers, String name) {
  final wanted = name.toLowerCase();
  return [
    for (final MapEntry(:key, :value) in headers.entries)
      if (key.toLowerCase() == wanted)
        ...switch (value) {
          String text => [text],
          List<Object?> lines => [for (final line in lines) '$line'],
          null => const <String>[],
          _ => ['$value'],
        },
  ];
}

/// Compares two digests in constant time.
bool _equal(List<int> a, List<int> b) {
  if (a.length != b.length) {
    return false;
  }
  var difference = 0;
  for (var i = 0; i < a.length; i++) {
    difference |= a[i] ^ b[i];
  }
  return difference == 0;
}
