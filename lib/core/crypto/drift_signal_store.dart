import 'package:drift/drift.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

import '../db/app_database.dart';

/// Thrown when the local identity is needed before [KeyManager] created it.
class NoLocalIdentityException implements Exception {
  @override
  String toString() => 'NoLocalIdentityException: keys have not been generated yet';
}

/// Signal protocol state kept in the encrypted [AppDatabase].
///
/// Remote identities are trusted on first use. A different key for an address we already know is
/// rejected: an address is a device UUID and a reinstall registers a new device, so a changed key
/// on the same address is not expected.
class DriftSignalProtocolStore extends SignalProtocolStore {
  DriftSignalProtocolStore(this._db);

  final AppDatabase _db;

  // --- local identity -------------------------------------------------------

  Future<bool> hasLocalIdentity() async =>
      await _db.select(_db.localIdentity).getSingleOrNull() != null;

  Future<void> saveLocalIdentity(IdentityKeyPair keyPair, int registrationId) =>
      _db.into(_db.localIdentity).insertOnConflictUpdate(LocalIdentityCompanion.insert(
            keyPair: keyPair.serialize(),
            registrationId: registrationId,
          ));

  Future<LocalIdentityData> _local() async {
    final row = await _db.select(_db.localIdentity).getSingleOrNull();
    if (row == null) throw NoLocalIdentityException();
    return row;
  }

  @override
  Future<IdentityKeyPair> getIdentityKeyPair() async =>
      IdentityKeyPair.fromSerialized((await _local()).keyPair);

  @override
  Future<int> getLocalRegistrationId() async => (await _local()).registrationId;

  // --- remote identities ----------------------------------------------------

  @override
  Future<IdentityKey?> getIdentity(SignalProtocolAddress address) async {
    final row = await (_db.select(_db.remoteIdentities)
          ..where((t) =>
              t.name.equals(address.getName()) & t.deviceId.equals(address.getDeviceId())))
        .getSingleOrNull();
    return row == null ? null : IdentityKey.fromBytes(row.identityKey, 0);
  }

  @override
  Future<bool> saveIdentity(SignalProtocolAddress address, IdentityKey? identityKey) async {
    if (identityKey == null) return false;
    final existing = await getIdentity(address);
    if (existing != null && _same(existing, identityKey)) return false;
    await _db.into(_db.remoteIdentities).insertOnConflictUpdate(RemoteIdentitiesCompanion.insert(
          name: address.getName(),
          deviceId: address.getDeviceId(),
          identityKey: identityKey.serialize(),
        ));
    return true;
  }

  @override
  Future<bool> isTrustedIdentity(
    SignalProtocolAddress address,
    IdentityKey? identityKey,
    Direction direction,
  ) async {
    if (identityKey == null) return false;
    final known = await getIdentity(address);
    return known == null || _same(known, identityKey);
  }

  bool _same(IdentityKey a, IdentityKey b) => _bytesEqual(a.serialize(), b.serialize());

  // --- one-time prekeys -----------------------------------------------------

  @override
  Future<PreKeyRecord> loadPreKey(int preKeyId) async {
    final row = await (_db.select(_db.preKeys)..where((t) => t.id.equals(preKeyId)))
        .getSingleOrNull();
    if (row == null) throw InvalidKeyIdException('No such prekey: $preKeyId');
    return PreKeyRecord.fromBuffer(row.record);
  }

  @override
  Future<void> storePreKey(int preKeyId, PreKeyRecord record) =>
      _db.into(_db.preKeys).insertOnConflictUpdate(
            PreKeysCompanion.insert(id: Value(preKeyId), record: record.serialize()),
          );

  /// Stores many prekeys in one batch.
  Future<void> storePreKeys(List<PreKeyRecord> records) => _db.batch((b) => b.insertAllOnConflictUpdate(
        _db.preKeys,
        [for (final r in records) PreKeysCompanion.insert(id: Value(r.id), record: r.serialize())],
      ));

  @override
  Future<bool> containsPreKey(int preKeyId) async =>
      await (_db.select(_db.preKeys)..where((t) => t.id.equals(preKeyId))).getSingleOrNull() !=
      null;

  @override
  Future<void> removePreKey(int preKeyId) =>
      (_db.delete(_db.preKeys)..where((t) => t.id.equals(preKeyId))).go();

  // --- signed prekeys -------------------------------------------------------

  @override
  Future<SignedPreKeyRecord> loadSignedPreKey(int signedPreKeyId) async {
    final row = await (_db.select(_db.signedPreKeys)..where((t) => t.id.equals(signedPreKeyId)))
        .getSingleOrNull();
    if (row == null) throw InvalidKeyIdException('No such signed prekey: $signedPreKeyId');
    return SignedPreKeyRecord.fromSerialized(row.record);
  }

  @override
  Future<List<SignedPreKeyRecord>> loadSignedPreKeys() async => [
        for (final row in await _db.select(_db.signedPreKeys).get())
          SignedPreKeyRecord.fromSerialized(row.record),
      ];

  @override
  Future<void> storeSignedPreKey(int signedPreKeyId, SignedPreKeyRecord record) =>
      _db.into(_db.signedPreKeys).insertOnConflictUpdate(
            SignedPreKeysCompanion.insert(id: Value(signedPreKeyId), record: record.serialize()),
          );

  @override
  Future<bool> containsSignedPreKey(int signedPreKeyId) async =>
      await (_db.select(_db.signedPreKeys)..where((t) => t.id.equals(signedPreKeyId)))
          .getSingleOrNull() !=
      null;

  @override
  Future<void> removeSignedPreKey(int signedPreKeyId) =>
      (_db.delete(_db.signedPreKeys)..where((t) => t.id.equals(signedPreKeyId))).go();

  // --- sessions ---------------------------------------------------------------

  Future<Session?> _session(SignalProtocolAddress a) => (_db.select(_db.sessions)
        ..where((t) => t.name.equals(a.getName()) & t.deviceId.equals(a.getDeviceId())))
      .getSingleOrNull();

  @override
  Future<SessionRecord> loadSession(SignalProtocolAddress address) async {
    final row = await _session(address);
    return row == null ? SessionRecord() : SessionRecord.fromSerialized(row.record);
  }

  @override
  Future<List<int>> getSubDeviceSessions(String name) async => [
        for (final row
            in await (_db.select(_db.sessions)..where((t) => t.name.equals(name))).get())
          if (row.deviceId != 1) row.deviceId,
      ];

  @override
  Future<void> storeSession(SignalProtocolAddress address, SessionRecord record) =>
      _db.into(_db.sessions).insertOnConflictUpdate(SessionsCompanion.insert(
            name: address.getName(),
            deviceId: address.getDeviceId(),
            record: record.serialize(),
          ));

  @override
  Future<bool> containsSession(SignalProtocolAddress address) async =>
      await _session(address) != null;

  @override
  Future<void> deleteSession(SignalProtocolAddress address) => (_db.delete(_db.sessions)
        ..where((t) =>
            t.name.equals(address.getName()) & t.deviceId.equals(address.getDeviceId())))
      .go();

  @override
  Future<void> deleteAllSessions(String name) =>
      (_db.delete(_db.sessions)..where((t) => t.name.equals(name))).go();
}

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
