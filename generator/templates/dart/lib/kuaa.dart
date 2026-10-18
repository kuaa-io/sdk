/// KUAA's SDK for Dart and Flutter.
///
/// ```dart
/// final kuaa = Kuaa(apiKey);
/// final kase = await kuaa.cases.create(
///   const CaseRequest(externalReference: 'pedido-1', kind: 'KYC'),
/// );
/// await for (final summary in kuaa.cases.listIter()) { … }
/// ```
library;

export 'src/client.dart' show Kuaa;
export 'src/core.dart' show FilePart, Requester, ResponseInfo;
export 'src/errors.dart' show KuaaException;
export 'src/models.dart';
export 'src/pagination.dart' show Page;
export 'src/services.dart';
export 'src/version.dart' show apiVersion, defaultBaseUrl, sdkVersion;
export 'src/webhooks.dart'
    show
        WebhookVerificationException,
        verifyWebhook,
        webhookHeaderDeliveryId,
        webhookHeaderSignature,
        webhookHeaderTimestamp,
        webhookTolerance;
