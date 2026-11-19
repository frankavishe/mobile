import 'dart:convert';
import 'dart:typed_data';

import 'package:chat_app/core/api/models/models.dart';
import 'package:chat_app/core/crypto/key_manager.dart';
import 'package:chat_app/core/crypto/signal_address.dart';
import 'package:chat_app/core/db/app_database.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:mocktail/mocktail.dart';

import '../support/fakes.dart';

/// One device with keys created by [KeyManager] in its own database.
class _Device {
  _Device(this.id);

  final String id;
  final db = AppDatabase(NativeDatabase.memory());
  final api = MockApiClient();
  late final KeyManager keys = KeyManager(api: api, db: db);
  late UploadKeysBody uploaded;

  Future<void> setUp() async {
    when(() => api.uploadKeys(any())).thenAnswer((inv) async {
      uploaded = inv.positionalArguments.single as UploadKeysBody;
    });
    await keys.ensureKeys();
  }

  /// What `GET /users/{id}/keys` would return for this device, consuming prekey [index].
  PreKeyBundle bundle(int index) {
    final spk = uploaded.signedPreKey!;
    final pk = uploaded.preKeys[index];
    return PreKeyBundle(
      uploaded.registrationId,
      signalDeviceId,
      pk.keyId,
      Curve.decodePoint(unb64(pk.publicKey), 0),
      spk.keyId,
      Curve.decodePoint(unb64(spk.publicKey), 0),
      unb64(spk.signature),
      IdentityKey.fromBytes(unb64(uploaded.identityKey), 0),
    );
  }

  SessionCipher cipherFor(_Device peer) => SessionCipher.fromStore(keys.store, addressOf(peer.id));

  Future<CiphertextMessage> send(_Device to, String text) =>
      cipherFor(to).encrypt(Uint8List.fromList(utf8.encode(text)));

  Future<String> receive(_Device from, CiphertextMessage msg) async {
    final cipher = cipherFor(from);
    final plain = msg.getType() == CiphertextMessage.prekeyType
        ? await cipher.decrypt(PreKeySignalMessage(msg.serialize()))
        : await cipher.decryptFromSignal(SignalMessage.fromSerialized(msg.serialize()));
    return utf8.decode(plain);
  }
}

void main() {
  setUpAll(() => registerFallbackValue(
        const UploadKeysBody(registrationId: 1, identityKey: '', preKeys: []),
      ));

  late _Device alice;
  late _Device bob;

  setUp(() async {
    alice = _Device('11111111-1111-4111-8111-111111111111');
    bob = _Device('22222222-2222-4222-8222-222222222222');
    await alice.setUp();
    await bob.setUp();
  });
  tearDown(() async {
    await alice.db.close();
    await bob.db.close();
  });

  test('two devices exchange messages through their drift stores', () async {
    await SessionBuilder.fromSignalStore(alice.keys.store, addressOf(bob.id))
        .processPreKeyBundle(bob.bundle(0));

    final first = await alice.send(bob, 'hi bob');
    expect(first.getType(), CiphertextMessage.prekeyType);
    expect(await bob.receive(alice, first), 'hi bob');
    // The one-time prekey is used up on Bob's side.
    expect(await bob.keys.store.containsPreKey(bob.uploaded.preKeys[0].keyId), isFalse);

    final reply = await bob.send(alice, 'hi alice');
    expect(reply.getType(), CiphertextMessage.whisperType);
    expect(await alice.receive(bob, reply), 'hi alice');

    // Several ratchet steps in both directions, including two in a row from one side.
    for (var i = 0; i < 5; i++) {
      final a1 = await alice.send(bob, 'a$i-1');
      final a2 = await alice.send(bob, 'a$i-2');
      expect(await bob.receive(alice, a1), 'a$i-1');
      expect(await bob.receive(alice, a2), 'a$i-2');
      final b = await bob.send(alice, 'b$i');
      expect(await alice.receive(bob, b), 'b$i');
    }

    // Each side pinned the other's identity.
    expect(
      (await alice.keys.store.getIdentity(addressOf(bob.id)))!.serialize(),
      unb64(bob.uploaded.identityKey),
    );
  });

  test('sessions survive a new store over the same database', () async {
    await SessionBuilder.fromSignalStore(alice.keys.store, addressOf(bob.id))
        .processPreKeyBundle(bob.bundle(1));
    expect(await bob.receive(alice, await alice.send(bob, 'one')), 'one');

    final restarted = KeyManager(api: alice.api, db: alice.db);
    final msg = await SessionCipher.fromStore(restarted.store, addressOf(bob.id))
        .encrypt(Uint8List.fromList(utf8.encode('after restart')));
    expect(await bob.receive(alice, msg), 'after restart');
  });

  test('a bundle signed by a different identity is rejected', () async {
    final good = bob.bundle(2);
    final forged = PreKeyBundle(
      good.getRegistrationId(),
      good.getDeviceId(),
      good.getPreKeyId(),
      good.getPreKey(),
      good.getSignedPreKeyId(),
      good.getSignedPreKey(),
      good.getSignedPreKeySignature(),
      generateIdentityKeyPair().getPublicKey(),
    );
    expect(
      () => SessionBuilder.fromSignalStore(alice.keys.store, addressOf(bob.id))
          .processPreKeyBundle(forged),
      throwsA(isA<InvalidKeyException>()),
    );
  });
}
