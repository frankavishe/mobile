import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

import '../api/models/models.dart' as api;
import 'drift_signal_store.dart';
import 'key_manager.dart';
import 'signal_address.dart';

/// Encrypts and decrypts envelopes with this device's Signal sessions.
///
/// Every operation runs one at a time: the session store is read, ratcheted and written back
/// per call, so two interleaved calls on the same session would lose a ratchet step.
class EnvelopeCipher {
  EnvelopeCipher(this._store);

  final DriftSignalProtocolStore _store;
  Future<void> _tail = Future.value();

  Future<T> _serial<T>(Future<T> Function() fn) {
    final result = _tail.then((_) => fn());
    _tail = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<bool> hasSession(String deviceId) =>
      _serial(() => _store.containsSession(addressOf(deviceId)));

  Future<void> deleteSession(String deviceId) =>
      _serial(() => _store.deleteSession(addressOf(deviceId)));

  /// Starts a session from a bundle fetched with `GET /users/{id}/keys`.
  Future<void> processBundle(api.DeviceBundle b) => _serial(() async {
        final spk = b.signedPreKey;
        final pk = b.preKey;
        await SessionBuilder.fromSignalStore(_store, addressOf(b.deviceId))
            .processPreKeyBundle(PreKeyBundle(
          b.registrationId,
          signalDeviceId,
          pk?.keyId,
          pk == null ? null : Curve.decodePoint(unb64(pk.publicKey), 0),
          spk.keyId,
          Curve.decodePoint(unb64(spk.publicKey), 0),
          unb64(spk.signature),
          IdentityKey.fromBytes(unb64(b.identityKey), 0),
        ));
      });

  /// One envelope for [deviceId]; needs a session ([processBundle]).
  Future<api.OutgoingEnvelope> encrypt(String deviceId, Uint8List plaintext) =>
      _serial(() async {
        final msg = await SessionCipher.fromStore(_store, addressOf(deviceId)).encrypt(plaintext);
        return api.OutgoingEnvelope(
          deviceId: deviceId,
          // libsignal uses 3 for prekey messages; the TS library and Dart disagree on the
          // whisper number, so the wire carries names instead (Phase 0 finding).
          type: msg.getType() == CiphertextMessage.prekeyType
              ? api.EnvelopeType.prekey
              : api.EnvelopeType.whisper,
          ciphertext: b64(msg.serialize()),
        );
      });

  /// Throws libsignal exceptions (untrusted identity, duplicate, invalid message, no session).
  Future<Uint8List> decrypt(api.Envelope e) => _serial(() async {
        final cipher = SessionCipher.fromStore(_store, addressOf(e.senderDeviceId));
        final bytes = unb64(e.ciphertext);
        return switch (e.type) {
          api.EnvelopeType.prekey => cipher.decrypt(PreKeySignalMessage(bytes)),
          api.EnvelopeType.whisper =>
            cipher.decryptFromSignal(SignalMessage.fromSerialized(bytes)),
        };
      });
}

final envelopeCipherProvider =
    Provider<EnvelopeCipher>((ref) => EnvelopeCipher(ref.watch(signalStoreProvider)));
