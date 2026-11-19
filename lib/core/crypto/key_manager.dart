import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

import '../api/api_client.dart';
import '../api/models/models.dart' as api;
import '../db/app_database.dart';
import '../db/db_opener.dart';
import 'drift_signal_store.dart';
import 'signal_address.dart';

/// Creates this device's Signal keys, publishes the public halves with `PUT /keys` and keeps the
/// server stocked with one-time prekeys.
class KeyManager {
  KeyManager({
    required this._api,
    required this._db,
    DriftSignalProtocolStore? store,
  }) : store = store ?? DriftSignalProtocolStore(_db);

  /// Prekeys per upload; also the most the API accepts at once.
  static const batchSize = 100;

  /// The server sends `prekeys:low` below this; [ensureKeys] uses the same threshold.
  static const lowWatermark = 10;

  static const signedPreKeyId = 1;

  static const _kNextPreKeyId = 'nextPreKeyId';
  static const _kUploaded = 'keysUploaded';

  final ApiClient _api;
  final AppDatabase _db;
  final DriftSignalProtocolStore store;

  Future<void>? _topUpInFlight;

  /// Run after sign-in and on every start: generates keys on first use, (re)uploads them until the
  /// server has them, then tops up prekeys when the server is running low.
  Future<void> ensureKeys() async {
    if (!await store.hasLocalIdentity()) await _generate();
    if (await _db.readKv(_kUploaded) != '1') {
      await _uploadAll();
      return;
    }
    final count = await _api.getKeyCount();
    if (count < lowWatermark) await topUp(count);
  }

  /// Uploads enough new prekeys to bring the server back to [batchSize]. Calls made while an upload
  /// is running share it, so a burst of `prekeys:low` events causes a single upload.
  Future<void> topUp(int remaining) {
    return _topUpInFlight ??= _topUp(remaining).whenComplete(() => _topUpInFlight = null);
  }

  Future<void> _topUp(int remaining) async {
    if (await _db.readKv(_kUploaded) != '1') return ensureKeys();
    final n = batchSize - remaining;
    if (n <= 0) return;
    final records = await _db.transaction(() async {
      final start = int.parse(await _db.readKv(_kNextPreKeyId) ?? '1');
      final records = generatePreKeys(start, n);
      await store.storePreKeys(records);
      await _db.writeKv(_kNextPreKeyId, '${_nextId(start, n)}');
      return records;
    });
    final identity = await store.getIdentityKeyPair();
    await _api.uploadKeys(api.UploadKeysBody(
      registrationId: await store.getLocalRegistrationId(),
      identityKey: b64(identity.getPublicKey().serialize()),
      preKeys: _public(records),
    ));
  }

  Future<void> _generate() async {
    final identity = generateIdentityKeyPair();
    final registrationId = generateRegistrationId(false);
    final signed = generateSignedPreKey(identity, signedPreKeyId);
    final preKeys = generatePreKeys(1, batchSize);
    await _db.transaction(() async {
      await (_db.delete(_db.preKeys)).go();
      await (_db.delete(_db.signedPreKeys)).go();
      await store.storeSignedPreKey(signedPreKeyId, signed);
      await store.storePreKeys(preKeys);
      await _db.writeKv(_kNextPreKeyId, '${_nextId(1, batchSize)}');
      await _db.writeKv(_kUploaded, '0');
      await store.saveLocalIdentity(identity, registrationId);
    });
  }

  /// Sends identity, signed prekey and the stored one-time prekeys. Safe to repeat: the server
  /// ignores prekeys it already has.
  Future<void> _uploadAll() async {
    final identity = await store.getIdentityKeyPair();
    final signed = await store.loadSignedPreKey(signedPreKeyId);
    final stored = await (_db.select(_db.preKeys)..limit(batchSize)).get();
    await _api.uploadKeys(api.UploadKeysBody(
      registrationId: await store.getLocalRegistrationId(),
      identityKey: b64(identity.getPublicKey().serialize()),
      signedPreKey: api.SignedPreKey(
        keyId: signed.id,
        publicKey: b64(signed.getKeyPair().publicKey.serialize()),
        signature: b64(signed.signature),
      ),
      preKeys: _public([for (final r in stored) PreKeyRecord.fromBuffer(r.record)]),
    ));
    await _db.writeKv(_kUploaded, '1');
  }

  static List<api.PublicPreKey> _public(List<PreKeyRecord> records) => [
        for (final r in records)
          api.PublicPreKey(keyId: r.id, publicKey: b64(r.getKeyPair().publicKey.serialize())),
      ];

  /// The id after [count] ids starting at [start], wrapping like `generatePreKeys` does
  /// (ids stay in 1 … 0xFFFFFE).
  static int _nextId(int start, int count) => ((start - 1 + count) % (maxValue - 1)) + 1;
}

final signalStoreProvider = Provider<DriftSignalProtocolStore>(
  (ref) => DriftSignalProtocolStore(ref.watch(appDatabaseProvider)),
);

final keyManagerProvider = Provider<KeyManager>((ref) => KeyManager(
      api: ref.watch(apiClientProvider),
      db: ref.watch(appDatabaseProvider),
      store: ref.watch(signalStoreProvider),
    ));
