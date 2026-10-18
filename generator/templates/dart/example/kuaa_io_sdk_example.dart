import 'dart:io';

import 'package:kuaa_io_sdk/kuaa_io_sdk.dart';

/// Opens a case and lists every case in review of the organization whose key
/// is in KUAA_API_KEY.
Future<void> main() async {
  final kuaa = Kuaa(Platform.environment['KUAA_API_KEY']!);
  try {
    final kase = await kuaa.cases.create(
      const CaseRequest(externalReference: 'pedido-0001', kind: 'KYC'),
      idempotencyKey: 'pedido-0001',
    );
    stdout.writeln(
      'opened ${kase.id} (livemode: ${kuaa.lastResponse?.livemode})',
    );

    await for (final summary in kuaa.cases.listIter(status: 'in_review')) {
      stdout.writeln('${summary.id} ${summary.status}');
    }
  } on KuaaException catch (error) {
    stderr.writeln(error);
    exitCode = 1;
  } finally {
    kuaa.close();
  }
}
