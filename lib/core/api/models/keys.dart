import 'package:flutter/foundation.dart';

/// `PublicPreKey` in the contract. Keys are base64 strings on the wire.
@immutable
class PublicPreKey {
  const PublicPreKey({required this.keyId, required this.publicKey});

  final int keyId;

  /// Base64 of the 33-byte Curve25519 public key (0x05 prefix).
  final String publicKey;

  factory PublicPreKey.fromJson(Map<String, dynamic> json) => PublicPreKey(
        keyId: json['keyId'] as int,
        publicKey: json['publicKey'] as String,
      );

  Map<String, dynamic> toJson() => {'keyId': keyId, 'publicKey': publicKey};
}

/// `SignedPreKey` in the contract.
@immutable
class SignedPreKey {
  const SignedPreKey({
    required this.keyId,
    required this.publicKey,
    required this.signature,
  });

  final int keyId;
  final String publicKey;

  /// Base64 of the 64-byte signature of [publicKey] by the identity key.
  final String signature;

  factory SignedPreKey.fromJson(Map<String, dynamic> json) => SignedPreKey(
        keyId: json['keyId'] as int,
        publicKey: json['publicKey'] as String,
        signature: json['signature'] as String,
      );

  Map<String, dynamic> toJson() =>
      {'keyId': keyId, 'publicKey': publicKey, 'signature': signature};
}

/// `UploadKeysBody` for `PUT /keys`.
@immutable
class UploadKeysBody {
  const UploadKeysBody({
    required this.registrationId,
    required this.identityKey,
    required this.preKeys,
    this.signedPreKey,
  });

  final int registrationId;
  final String identityKey;

  /// Required on the first upload; omit when only topping up [preKeys].
  final SignedPreKey? signedPreKey;
  final List<PublicPreKey> preKeys;

  Map<String, dynamic> toJson() => {
        'registrationId': registrationId,
        'identityKey': identityKey,
        if (signedPreKey != null) 'signedPreKey': signedPreKey!.toJson(),
        'preKeys': [for (final k in preKeys) k.toJson()],
      };
}

/// `DeviceBundle`: what a sender needs to start a session with one device.
@immutable
class DeviceBundle {
  const DeviceBundle({
    required this.deviceId,
    required this.registrationId,
    required this.identityKey,
    required this.signedPreKey,
    required this.preKey,
  });

  final String deviceId;
  final int registrationId;
  final String identityKey;
  final SignedPreKey signedPreKey;

  /// Null when the device has run out of one-time prekeys.
  final PublicPreKey? preKey;

  factory DeviceBundle.fromJson(Map<String, dynamic> json) => DeviceBundle(
        deviceId: json['deviceId'] as String,
        registrationId: json['registrationId'] as int,
        identityKey: json['identityKey'] as String,
        signedPreKey:
            SignedPreKey.fromJson(json['signedPreKey'] as Map<String, dynamic>),
        preKey: json['preKey'] == null
            ? null
            : PublicPreKey.fromJson(json['preKey'] as Map<String, dynamic>),
      );

  Map<String, dynamic> toJson() => {
        'deviceId': deviceId,
        'registrationId': registrationId,
        'identityKey': identityKey,
        'signedPreKey': signedPreKey.toJson(),
        'preKey': preKey?.toJson(),
      };
}

/// `UserKeys`: bundles for every key-holding device of one user.
@immutable
class UserKeys {
  const UserKeys({required this.userId, required this.devices});

  final String userId;
  final List<DeviceBundle> devices;

  factory UserKeys.fromJson(Map<String, dynamic> json) => UserKeys(
        userId: json['userId'] as String,
        devices: [
          for (final d in json['devices'] as List)
            DeviceBundle.fromJson(d as Map<String, dynamic>),
        ],
      );

  Map<String, dynamic> toJson() => {
        'userId': userId,
        'devices': [for (final d in devices) d.toJson()],
      };
}
