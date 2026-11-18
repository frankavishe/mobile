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
}
