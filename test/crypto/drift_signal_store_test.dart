import 'package:chat_app/core/crypto/drift_signal_store.dart';
import 'package:chat_app/core/crypto/signal_address.dart';
import 'package:chat_app/core/db/app_database.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

void main() {
  late AppDatabase db;
  late DriftSignalProtocolStore store;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    store = DriftSignalProtocolStore(db);
  });
  tearDown(() => db.close());

  test('local identity round-trips', () async {
    expect(await store.hasLocalIdentity(), isFalse);
    expect(store.getIdentityKeyPair, throwsA(isA<NoLocalIdentityException>()));

    final identity = generateIdentityKeyPair();
    await store.saveLocalIdentity(identity, 1234);

    expect(await store.hasLocalIdentity(), isTrue);
    expect(await store.getLocalRegistrationId(), 1234);
    expect((await store.getIdentityKeyPair()).serialize(), identity.serialize());
    // A fresh store over the same database sees it too.
    expect(await DriftSignalProtocolStore(db).getLocalRegistrationId(), 1234);
  });

  test('remote identities are trusted on first use and a changed key is rejected', () async {
    final alice = addressOf('device-a');
    final key = generateIdentityKeyPair().getPublicKey();
    final other = generateIdentityKeyPair().getPublicKey();

    expect(await store.getIdentity(alice), isNull);
    expect(await store.isTrustedIdentity(alice, key, Direction.sending), isTrue);
    expect(await store.isTrustedIdentity(alice, null, Direction.sending), isFalse);

    expect(await store.saveIdentity(alice, key), isTrue);
    expect(await store.saveIdentity(alice, key), isFalse);
    expect((await store.getIdentity(alice))!.serialize(), key.serialize());

    expect(await store.isTrustedIdentity(alice, key, Direction.receiving), isTrue);
    expect(await store.isTrustedIdentity(alice, other, Direction.receiving), isFalse);
    expect(await store.isTrustedIdentity(addressOf('device-b'), other, Direction.sending), isTrue);
  });

  test('prekeys store, load and remove', () async {
    final keys = generatePreKeys(1, 3);
    await store.storePreKeys(keys);

    expect(await store.containsPreKey(2), isTrue);
    expect((await store.loadPreKey(2)).serialize(), keys[1].serialize());

    await store.removePreKey(2);
    expect(await store.containsPreKey(2), isFalse);
    expect(() => store.loadPreKey(2), throwsA(isA<InvalidKeyIdException>()));

    final replacement = generatePreKeys(1, 1).single;
    await store.storePreKey(1, replacement);
    expect((await store.loadPreKey(1)).serialize(), replacement.serialize());
  });

  test('signed prekeys store, list and remove', () async {
    final identity = generateIdentityKeyPair();
    final a = generateSignedPreKey(identity, 1);
    final b = generateSignedPreKey(identity, 2);
    await store.storeSignedPreKey(1, a);
    await store.storeSignedPreKey(2, b);

    expect(await store.containsSignedPreKey(1), isTrue);
    expect((await store.loadSignedPreKey(1)).serialize(), a.serialize());
    expect((await store.loadSignedPreKeys()).map((r) => r.id), unorderedEquals([1, 2]));

    await store.removeSignedPreKey(1);
    expect(await store.containsSignedPreKey(1), isFalse);
    expect(() => store.loadSignedPreKey(1), throwsA(isA<InvalidKeyIdException>()));
  });

  test('sessions store, list and delete', () async {
    final a1 = addressOf('device-a');
    final a2 = SignalProtocolAddress('device-a', 2);
    final b = addressOf('device-b');

    expect(await store.containsSession(a1), isFalse);
    expect((await store.loadSession(a1)).isFresh(), isTrue);

    final record = SessionRecord();
    for (final address in [a1, a2, b]) {
      await store.storeSession(address, record);
    }
    expect(await store.containsSession(a1), isTrue);
    expect((await store.loadSession(a1)).serialize(), record.serialize());
    expect(await store.getSubDeviceSessions('device-a'), [2]);

    await store.deleteSession(a2);
    expect(await store.containsSession(a2), isFalse);

    await store.deleteAllSessions('device-a');
    expect(await store.containsSession(a1), isFalse);
    expect(await store.containsSession(b), isTrue);
  });
}
