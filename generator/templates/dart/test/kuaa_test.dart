import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kuaa/kuaa.dart';
import 'package:test/test.dart';

typedef Answer = http.Response Function(http.Request request);

(Kuaa, List<http.Request>) client(Answer answer) {
  final seen = <http.Request>[];
  final fake = MockClient((request) async {
    seen.add(request);
    return answer(request);
  });
  final kuaa = Kuaa(
    'kuaa_test_abc_secret',
    baseUrl: 'http://kuaa.test/',
    httpClient: fake,
  );
  return (kuaa, seen);
}

http.Response json(
  int status,
  Object? body, [
  Map<String, String> headers = const {},
]) => http.Response(
  body == null ? '' : jsonEncode(body),
  status,
  headers: {'content-type': 'application/json', ...headers},
);

const kase = <String, Object?>{
  'id': 'case_1',
  'external_reference': 'pedido-1',
  'kind': 'KYC',
  'status': 'open',
  'status_market': 'PROCESSING',
  'livemode': false,
  'custom_status': null,
  'current_state': 'collect_identity',
  'workflow_definition_id': null,
  'policy_version_id': null,
  'parent_case_id': null,
  'child_group': null,
  'parties': [
    {
      'id': 'party_1',
      'kind': 'PERSON',
      'primary': true,
      'identity_id': null,
      'cpf': '12345678909',
    },
  ],
  'relationships': <Object?>[],
  'created_at': '2027-01-15T08:00:00Z',
  'updated_at': '2027-01-15T08:00:00Z',
};

Map<String, Object?> summary(String id) => {
  'id': id,
  'external_reference': 'ref-$id',
  'kind': 'KYC',
  'status': 'open',
  'status_market': 'PROCESSING',
  'livemode': false,
  'current_state': 'start',
  'workflow_definition_id': null,
  'workflow_version_id': null,
  'policy_version_id': null,
  'created_at': '2027-01-15T08:00:00Z',
  'updated_at': '2027-01-15T08:00:00Z',
};

void main() {
  test('a call carries the key and unwraps the data', () async {
    final (kuaa, seen) = client(
      (_) => json(
        200,
        {'data': kase},
        {
          'kuaa-livemode': 'false',
          'kuaa-environment': 'sandbox',
          'x-request-id': 'req_1',
        },
      ),
    );
    final got = await kuaa.cases.get('case_1');
    expect(got.id, 'case_1');
    expect(got.status, 'open');
    expect(got.parties.single.cpf, '12345678909');
    expect(seen.single.method, 'GET');
    expect(seen.single.url.path, '/v1/cases/case_1');
    expect(seen.single.headers['authorization'], 'Bearer kuaa_test_abc_secret');
    final last = kuaa.lastResponse!;
    expect(last.status, 200);
    expect(last.livemode, false);
    expect(last.environment, 'sandbox');
    expect(last.idempotentReplayed, false);
    expect(last.requestId, 'req_1');
  });

  test('a write sends its body and idempotency key', () async {
    final (kuaa, seen) = client(
      (_) => json(
        200,
        {
          'data': kase,
          'meta': {'created': false},
        },
        {'idempotent-replayed': 'true'},
      ),
    );
    final got = await kuaa.cases.create(
      const CaseRequest(externalReference: 'pedido-1', kind: 'KYC'),
      idempotencyKey: 'pedido-1',
    );
    expect(got.externalReference, 'pedido-1');
    expect(seen.single.method, 'POST');
    expect(seen.single.url.path, '/v1/cases');
    expect(seen.single.headers['idempotency-key'], 'pedido-1');
    expect(seen.single.headers['content-type'], startsWith('application/json'));
    expect(jsonDecode(seen.single.body), {
      'external_reference': 'pedido-1',
      'kind': 'KYC',
    });
    expect(kuaa.lastResponse!.idempotentReplayed, true);
  });

  test('a nested body is written whole', () async {
    final (kuaa, seen) = client((_) => json(201, {'data': kase}));
    await kuaa.cases.create(
      const CaseRequest(
        externalReference: 'pedido-1',
        kind: 'KYC',
        parties: [
          CaseRequestParty(
            kind: 'PERSON',
            primary: true,
            cpf: '123.456.789-09',
          ),
        ],
      ),
    );
    expect(jsonDecode(seen.single.body), {
      'external_reference': 'pedido-1',
      'kind': 'KYC',
      'parties': [
        {'cpf': '123.456.789-09', 'kind': 'PERSON', 'primary': true},
      ],
    });
  });

  test('iterating walks every page by cursor', () async {
    const following = {'': 'c2', 'c2': 'c3', 'c3': null};
    const ids = {'': 'case_1', 'c2': 'case_2', 'c3': 'case_3'};
    final (kuaa, seen) = client((request) {
      final query = request.url.queryParameters;
      expect(query['limit'], '1');
      expect(query['status'], 'open');
      final cursor = query['cursor'] ?? '';
      return json(200, {
        'data': {
          'livemode': false,
          'cases': [summary(ids[cursor]!)],
        },
        'meta': {
          'next_cursor': following[cursor],
          'has_more': following[cursor] != null,
          'limit': 1,
        },
      });
    });
    final walked = await kuaa.cases
        .listIter(limit: 1, status: 'open')
        .map((each) => each.id)
        .toList();
    expect(walked, ['case_1', 'case_2', 'case_3']);
    expect(seen, hasLength(3));
  });

  test('a refusal is a typed error', () async {
    final (kuaa, _) = client(
      (request) => request.url.path == '/v1/cases'
          ? json(422, {
              'error': {
                'code': 'validation_failed',
                'message': 'The input has invalid fields.',
                'fields': {
                  'kind': ['must be KYC, KYB or AGE'],
                },
              },
            })
          : json(
              429,
              {
                'error': {
                  'code': 'rate_limited',
                  'message': 'Too many requests.',
                },
              },
              {'retry-after': '7'},
            ),
    );
    await expectLater(
      kuaa.cases.create(const CaseRequest(externalReference: 'x', kind: 'KYC')),
      throwsA(
        isA<KuaaException>()
            .having((error) => error.status, 'status', 422)
            .having((error) => error.code, 'code', 'validation_failed')
            .having((error) => error.fields['kind'], 'fields', [
              'must be KYC, KYB or AGE',
            ]),
      ),
    );
    await expectLater(
      kuaa.cases.get('case_1'),
      throwsA(
        isA<KuaaException>()
            .having((error) => error.status, 'status', 429)
            .having((error) => error.code, 'code', 'rate_limited')
            .having((error) => error.retryAfter, 'retryAfter', 7),
      ),
    );
  });

  test('a capture is sent as multipart', () async {
    final (kuaa, seen) = client(
      (_) => json(201, {
        'data': {
          'documents': [
            {
              'id': 'doc_1',
              'capture': 'document',
              'party_id': 'party_1',
              'status': 'received',
              'artifact_id': null,
              'created_at': '2027-01-15T08:00:00Z',
            },
          ],
        },
      }),
    );
    final got = await kuaa.caseMedia.create(
      'case_1',
      CaptureForm(
        kind: 'document',
        documentType: 'CNH',
        side: 'front',
        file: [
          const FilePart('frente.jpg', [0xff, 0xd8, 0x20, 0x66], 'image/jpeg'),
          FilePart('verso.jpg', utf8.encode('verso'), 'image/jpeg'),
        ],
      ),
      idempotencyKey: 'captura-1',
    );
    expect(got.documents.single.id, 'doc_1');
    final request = seen.single;
    expect(request.url.path, '/v1/cases/case_1/media');
    expect(request.headers['idempotency-key'], 'captura-1');
    final type = request.headers['content-type']!;
    expect(type, startsWith('multipart/form-data; boundary='));
    final boundary = type.substring('multipart/form-data; boundary='.length);
    final body = latin1.decode(request.bodyBytes);
    expect(
      body,
      contains(
        'Content-Disposition: form-data; name="kind"\r\n\r\ndocument\r\n',
      ),
    );
    expect(
      body,
      contains(
        'Content-Disposition: form-data; name="file"; filename="frente.jpg"\r\n'
        'Content-Type: image/jpeg\r\n\r\nÿØ f\r\n',
      ),
    );
    expect(body, contains('filename="verso.jpg"'));
    expect(body, isNot(contains('name="party_id"')));
    expect(body, endsWith('--$boundary--\r\n'));
  });

  test('a list query repeats its name', () async {
    final (kuaa, seen) = client(
      (_) => json(200, {
        'data': {'case_id': 'case_1', 'tags': <Object?>[]},
      }),
    );
    final got = await kuaa.caseTags.delete(
      'case_1',
      tag: ['prioridade', 'revisar'],
    );
    expect(got.caseId, 'case_1');
    expect(seen.single.method, 'DELETE');
    expect(seen.single.url.query, 'tag=prioridade&tag=revisar');
  });

  // The vectors are generated once, in Go, by sdk/generator, and every SDK
  // checks its verification against them.
  test('the webhook vectors', () {
    final vectors =
        jsonDecode(File('test/webhook-vectors.json').readAsStringSync())
            as Map<String, Object?>;
    expect(vectors['tolerance_seconds'], webhookTolerance.inSeconds);
    final all = vectors['vectors'] as List<Object?>;
    expect(all, isNotEmpty);
    for (final each in all) {
      final vector = each as Map<String, Object?>;
      final name = vector['name'] as String;
      final headers = (vector['headers'] as Map<String, Object?>).map(
        (key, value) => MapEntry(key, value),
      );
      final now = DateTime.fromMillisecondsSinceEpoch(
        (vector['now'] as int) * 1000,
        isUtc: true,
      );
      final body = vector['body'] as String;
      final secret = vector['secret'] as String;
      if (vector['valid'] != true) {
        expect(
          () => verifyWebhook(secret, headers, body, now: now),
          throwsA(isA<WebhookVerificationException>()),
          reason: name,
        );
        continue;
      }
      final event = verifyWebhook(secret, headers, utf8.encode(body), now: now);
      final want = vector['event'] as Map<String, Object?>;
      expect(event.specversion, '1.0', reason: name);
      expect(
        [
          event.id,
          event.type,
          event.source,
          event.subject,
          event.data.caseId,
          event.data.status,
          event.data.environment,
          event.data.livemode,
        ],
        [
          want['id'],
          want['type'],
          want['source'],
          want['subject'],
          want['case_id'],
          want['status'],
          want['environment'],
          want['livemode'],
        ],
        reason: name,
      );
    }
  });

  test('a call goes over real HTTP', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final seen = <String, String>{};
    server.listen((request) async {
      final body = await utf8.decodeStream(request);
      seen['method'] = request.method;
      seen['path'] = request.uri.path;
      seen['raw'] = request.requestedUri.toString();
      seen['authorization'] = request.headers.value('authorization') ?? '';
      seen['user-agent'] = request.headers.value('user-agent') ?? '';
      seen['idempotency-key'] = request.headers.value('idempotency-key') ?? '';
      seen['body'] = body;
      final known = request.uri.path.endsWith('/tags');
      request.response
        ..statusCode = known ? 200 : 404
        ..headers.contentType = ContentType.json
        ..headers.set('Kuaa-Livemode', 'false')
        ..write(
          jsonEncode(
            known
                ? {
                    'data': {'case_id': 'case_1', 'tags': <Object?>[]},
                  }
                : {
                    'error': {'code': 'not_found', 'message': 'no such case'},
                  },
          ),
        );
      await request.response.close();
    });
    final kuaa = Kuaa(
      'kuaa_test_abc_secret',
      baseUrl: 'http://${server.address.host}:${server.port}',
    );
    addTearDown(kuaa.close);

    final tags = await kuaa.caseTags.create(
      'case 1/2',
      const CaseTagsRequest(tags: ['prioridade']),
      idempotencyKey: 'tag-1',
      apiKey: 'kuaa_test_other',
    );
    expect(tags.caseId, 'case_1');
    expect(kuaa.lastResponse!.livemode, false);
    expect(seen['method'], 'POST');
    expect(seen['raw'], endsWith('/v1/cases/case%201%2F2/tags'));
    expect(seen['authorization'], 'Bearer kuaa_test_other');
    expect(seen['user-agent'], 'kuaa-dart/$sdkVersion');
    expect(seen['idempotency-key'], 'tag-1');
    expect(jsonDecode(seen['body']!), {
      'tags': ['prioridade'],
    });

    await expectLater(
      kuaa.cases.get('case_1'),
      throwsA(
        isA<KuaaException>()
            .having((error) => error.status, 'status', 404)
            .having((error) => error.code, 'code', 'not_found')
            .having((error) => error.message, 'message', 'no such case'),
      ),
    );
  });
}
