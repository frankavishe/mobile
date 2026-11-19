import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:chat_app/core/api/api_client.dart';
import 'package:chat_app/core/api/models/models.dart';
import 'package:chat_app/core/storage/secure_store.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

typedef Handler = Future<ResponseBody> Function(RequestOptions o);

/// Answers requests with [handler] and records them.
class FakeAdapter implements HttpClientAdapter {
  FakeAdapter(this.handler);

  final Handler handler;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    requests.add(options);
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody json(int status, Object body, {Map<String, List<String>>? headers}) =>
    ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
        ...?headers,
      },
    );

const meJson = {
  'id': 'u1',
  'phone': '+255712345678',
  'displayName': 'Frank',
  'about': 'Hi',
  'avatarUrl': null,
  'profileComplete': true,
};

void main() {
  late MemorySecureStore store;
  String? accessToken;
  var sessionLost = 0;

  ApiClient client(FakeAdapter adapter) => ApiClient(
        store: store,
        baseUrl: 'http://api.test/v1',
        adapter: adapter,
        hooks: SessionHooks(
          accessToken: () => accessToken,
          onAccessToken: (t) => accessToken = t,
          onSessionLost: () => sessionLost++,
        ),
      );

  setUp(() {
    store = MemorySecureStore('rt-1');
    accessToken = 'old';
    sessionLost = 0;
  });

  test('concurrent 401s share one refresh, then each request is retried', () async {
    var refreshes = 0;
    final refreshGate = Completer<void>();
    final adapter = FakeAdapter((o) async {
      if (o.path.endsWith('/auth/refresh')) {
        refreshes++;
        expect((o.data as Map)['refreshToken'], 'rt-1');
        await refreshGate.future;
        return json(200, {'accessToken': 'new', 'expiresIn': 900, 'refreshToken': 'rt-2'});
      }
      final auth = o.headers['Authorization'];
      return auth == 'Bearer new' ? json(200, meJson) : json(401, {'code': 'UNAUTHORIZED', 'message': 'x'});
    });
    final api = client(adapter);

    final calls = Future.wait([api.getMe(), api.getMe(), api.getMe()]);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    refreshGate.complete();
    final results = await calls;

    expect(results.map((m) => m.displayName), everyElement('Frank'));
    expect(refreshes, 1);
    expect(accessToken, 'new');
    expect(store.refreshToken, 'rt-2');
  });

  test('/auth/* 401s are not retried and do not refresh', () async {
    final adapter = FakeAdapter((o) async =>
        json(401, {'code': 'INVALID_CODE', 'message': 'Wrong code'}));
    final api = client(adapter);

    await expectLater(
      api.verify(phone: '+255712345678', code: '000000', deviceName: 'Pixel'),
      throwsA(isA<ApiError>().having((e) => e.code, 'code', ApiErrorCode.invalidCode)),
    );
    expect(adapter.requests, hasLength(1));
  });

  test('a rejected refresh wipes storage and reports the session lost', () async {
    final adapter = FakeAdapter((o) async => o.path.endsWith('/auth/refresh')
        ? json(401, {'code': 'SESSION_REVOKED', 'message': 'Revoked'})
        : json(401, {'code': 'UNAUTHORIZED', 'message': 'x'}));
    final api = client(adapter);

    await expectLater(
      api.getMe(),
      throwsA(isA<ApiError>().having((e) => e.status, 'status', 401)),
    );
    expect(store.refreshToken, isNull);
    expect(sessionLost, 1);
  });

  test('refresh without a stored token returns null without a request', () async {
    store.refreshToken = null;
    final adapter = FakeAdapter((o) async => json(500, {}));
    expect(await client(adapter).refresh(), isNull);
    expect(adapter.requests, isEmpty);
  });

  test('network failure becomes ApiError(network) and keeps the session', () async {
    final adapter = FakeAdapter((o) async =>
        throw DioException.connectionError(requestOptions: o, reason: 'offline'));
    final api = client(adapter);

    await expectLater(
      api.refresh(),
      throwsA(isA<ApiError>().having((e) => e.code, 'code', ApiErrorCode.network)),
    );
    expect(store.refreshToken, 'rt-1');
    expect(sessionLost, 0);
  });

  test('429 carries Retry-After', () async {
    final adapter = FakeAdapter((o) async => json(
          429,
          {'code': 'RATE_LIMITED', 'message': 'Wait'},
          headers: {'retry-after': ['37']},
        ));
    await expectLater(
      client(adapter).requestCode('+255712345678'),
      throwsA(isA<ApiError>()
          .having((e) => e.code, 'code', ApiErrorCode.rateLimited)
          .having((e) => e.retryAfter, 'retryAfter', 37)),
    );
  });

  test('verify stores the refresh token and sends deviceType android', () async {
    store.refreshToken = null;
    final adapter = FakeAdapter((o) async {
      expect((o.data as Map)['deviceType'], 'android');
      return json(200, {
        'accessToken': 'a',
        'expiresIn': 900,
        'refreshToken': 'rt-new',
        'isNewAccount': false,
        'device': {
          'id': 'd1',
          'type': 'android',
          'name': 'Pixel',
          'createdAt': '2026-11-17T10:00:00Z',
          'lastActiveAt': '2026-11-17T10:00:00Z',
          'current': true,
        },
        'user': meJson,
      });
    });
    final r = await client(adapter)
        .verify(phone: '+255712345678', code: '123456', deviceName: 'Pixel');
    expect(r.user.profileComplete, isTrue);
    expect(store.refreshToken, 'rt-new');
  });

  group('messaging endpoints', () {
    Map<String, dynamic> bundle(String deviceId) => {
          'deviceId': deviceId,
          'registrationId': 7,
          'identityKey': 'aWs=',
          'signedPreKey': {'keyId': 1, 'publicKey': 'cGs=', 'signature': 'c2ln'},
          'preKey': null,
        };

    test('getUserKeys repeats deviceId and fetches more than 5 in chunks', () async {
      final adapter = FakeAdapter((o) async {
        final ids = (o.queryParameters['deviceId'] as List).cast<String>();
        return json(200, {'userId': 'u2', 'devices': [for (final d in ids) bundle(d)]});
      });
      final ids = [for (var i = 0; i < 7; i++) 'd$i'];
      final keys = await client(adapter).getUserKeys('u2', deviceIds: ids);

      expect(keys.devices.map((d) => d.deviceId), ids);
      expect(adapter.requests, hasLength(2));
      expect(
        adapter.requests.first.uri.toString(),
        'http://api.test/v1/users/u2/keys'
        '?deviceId=d0&deviceId=d1&deviceId=d2&deviceId=d3&deviceId=d4',
      );
      expect(keys.devices.first.preKey, isNull);
    });

    test('sendMessage returns the server time; 409 carries the device lists', () async {
      var calls = 0;
      final adapter = FakeAdapter((o) async {
        if (calls++ == 0) return json(200, {'serverTimestamp': '2026-11-19T10:00:00.000Z'});
        return json(409, {
          'code': 'DEVICE_MISMATCH',
          'message': 'Device list is out of date',
          'details': {
            'missingDevices': [
              {'userId': 'u2', 'deviceId': 'd2'},
            ],
            'staleDevices': <Object>[],
          },
        });
      });
      final api = client(adapter);
      const body = SendMessageBody(conversationId: 'c1', envelopes: [
        OutgoingEnvelope(deviceId: 'd1', type: EnvelopeType.prekey, ciphertext: 'AA=='),
      ]);

      expect(await api.sendMessage(body), DateTime.utc(2026, 11, 19, 10));
      expect(adapter.requests.single.data, {
        'conversationId': 'c1',
        'envelopes': [
          {'deviceId': 'd1', 'type': 'prekey', 'ciphertext': 'AA=='},
        ],
      });

      ApiError? error;
      try {
        await api.sendMessage(body);
      } on ApiError catch (e) {
        error = e;
      }
      final mismatch = deviceMismatchOf(error!)!;
      expect(mismatch.missingDevices, [const DeviceRef(userId: 'u2', deviceId: 'd2')]);
      expect(mismatch.staleDevices, isEmpty);
      expect(deviceMismatchOf(const ApiError.network()), isNull);
    });

    test('envelopes are listed, and acked in batches of 500', () async {
      final adapter = FakeAdapter((o) async {
        if (o.method == 'GET') {
          return json(200, [
            {
              'id': 'e1',
              'conversationId': 'c1',
              'senderUserId': 'u2',
              'senderDeviceId': 'd2',
              'type': 'whisper',
              'ciphertext': 'AA==',
              'serverTimestamp': '2026-11-19T10:00:00.000Z',
            },
          ]);
        }
        return ResponseBody.fromString('', 204);
      });
      final api = client(adapter);

      final list = await api.listEnvelopes(limit: 50);
      expect(list.single.type, EnvelopeType.whisper);
      expect(adapter.requests.single.queryParameters, {'limit': 50});

      await api.ackEnvelopes([for (var i = 0; i < 501; i++) 'e$i']);
      final acks = adapter.requests.skip(1).toList();
      expect(acks.map((r) => ((r.data as Map)['ids'] as List).length), [500, 1]);
      expect(acks.first.path, '/envelopes/ack');
    });

    test('createConversation sends a direct body and parses the conversation', () async {
      final adapter = FakeAdapter((o) async => json(201, {
            'id': 'c1',
            'type': 'direct',
            'createdAt': '2026-11-19T10:00:00.000Z',
            'members': [
              {'userId': 'u1', 'role': 'member', 'joinedAt': '2026-11-19T10:00:00.000Z'},
              {'userId': 'u2', 'role': 'member', 'joinedAt': '2026-11-19T10:00:00.000Z'},
            ],
          }));
      final c =
          await client(adapter).createConversation(const CreateConversationBody.direct('u2'));

      expect(adapter.requests.single.data, {'type': 'direct', 'peerId': 'u2'});
      expect(c.members.map((m) => m.userId), ['u1', 'u2']);
    });
  });
}
