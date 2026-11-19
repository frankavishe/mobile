import 'dart:async';

import 'package:chat_app/core/api/models/models.dart';
import 'package:chat_app/core/crypto/key_manager.dart';
import 'package:chat_app/core/crypto/signal_address.dart';
import 'package:chat_app/core/db/app_database.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:mocktail/mocktail.dart';

import '../support/fakes.dart';

const _body = UploadKeysBody(registrationId: 1, identityKey: '', preKeys: []);

void main() {
  setUpAll(() => registerFallbackValue(_body));

  late AppDatabase db;
  late MockApiClient api;
  late KeyManager keys;
  late List<UploadKeysBody> uploads;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    api = MockApiClient();
    uploads = [];
    when(() => api.uploadKeys(any())).thenAnswer((inv) async {
      uploads.add(inv.positionalArguments.single as UploadKeysBody);
    });
    when(() => api.getKeyCount()).thenAnswer((_) async => 100);
    keys = KeyManager(api: api, db: db);
  });
  tearDown(() => db.close());

  test('first run generates and uploads identity, signed prekey and 100 prekeys', () async {
    await keys.ensureKeys();

    final body = uploads.single;
    final identity = await keys.store.getIdentityKeyPair();
    expect(body.registrationId, await keys.store.getLocalRegistrationId());
    expect(body.registrationId, inInclusiveRange(1, 16380));
    expect(body.identityKey, b64(identity.getPublicKey().serialize()));
    expect(unb64(body.identityKey), hasLength(33));

    final spk = body.signedPreKey!;
    expect(spk.keyId, KeyManager.signedPreKeyId);
    expect(unb64(spk.signature), hasLength(64));
    expect(
      Curve.verifySignature(identity.getPublicKey().publicKey, unb64(spk.publicKey), unb64(spk.signature)),
      isTrue,
    );

    expect(body.preKeys, hasLength(100));
    expect(body.preKeys.map((k) => k.keyId), List.generate(100, (i) => i + 1));
    final stored = await keys.store.loadPreKey(42);
    expect(body.preKeys[41].publicKey, b64(stored.getKeyPair().publicKey.serialize()));
    verifyNever(() => api.getKeyCount());
  });

  test('later runs keep the keys and only check the count', () async {
    await keys.ensureKeys();
    final identity = (await keys.store.getIdentityKeyPair()).serialize();

    await KeyManager(api: api, db: db).ensureKeys();

    expect(uploads, hasLength(1));
    expect((await keys.store.getIdentityKeyPair()).serialize(), identity);
    verify(() => api.getKeyCount()).called(1);
  });

  test('a failed first upload is retried with the same keys', () async {
    when(() => api.uploadKeys(any())).thenThrow(const ApiError(code: ApiErrorCode.network, status: 0, message: 'offline'));
    await expectLater(keys.ensureKeys(), throwsA(isA<ApiError>()));
    final identity = (await keys.store.getIdentityKeyPair()).serialize();

    when(() => api.uploadKeys(any())).thenAnswer((inv) async {
      uploads.add(inv.positionalArguments.single as UploadKeysBody);
    });
    await keys.ensureKeys();

    expect((await keys.store.getIdentityKeyPair()).serialize(), identity);
    expect(uploads.single.signedPreKey, isNotNull);
    expect(uploads.single.preKeys, hasLength(100));
    verifyNever(() => api.getKeyCount());
  });

  test('a low count on start tops up', () async {
    await keys.ensureKeys();
    when(() => api.getKeyCount()).thenAnswer((_) async => 4);

    await keys.ensureKeys();

    expect(uploads, hasLength(2));
    expect(uploads.last.preKeys, hasLength(96));
  });

  test('topUp uploads the difference with new ids and no signed prekey', () async {
    await keys.ensureKeys();

    await keys.topUp(3);
    await keys.topUp(90);

    final first = uploads[1];
    expect(first.signedPreKey, isNull);
    expect(first.identityKey, uploads[0].identityKey);
    expect(first.preKeys.map((k) => k.keyId), List.generate(97, (i) => 101 + i));
    expect(await keys.store.containsPreKey(197), isTrue);
    expect(uploads[2].preKeys.map((k) => k.keyId), List.generate(10, (i) => 198 + i));
  });

  test('topUp does nothing when the server is full', () async {
    await keys.ensureKeys();
    await keys.topUp(100);
    expect(uploads, hasLength(1));
  });

  test('concurrent top-ups share one upload', () async {
    await keys.ensureKeys();
    final gate = Completer<void>();
    when(() => api.uploadKeys(any())).thenAnswer((inv) async {
      await gate.future;
      uploads.add(inv.positionalArguments.single as UploadKeysBody);
    });

    final a = keys.topUp(5);
    final b = keys.topUp(2);
    gate.complete();
    await Future.wait([a, b]);

    expect(uploads, hasLength(2));
  });

  test('topUp before the first upload runs the full setup', () async {
    await keys.topUp(0);
    expect(uploads.single.signedPreKey, isNotNull);
    expect(uploads.single.preKeys, hasLength(100));
  });
}
