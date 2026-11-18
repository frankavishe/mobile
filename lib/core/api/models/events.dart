import 'package:flutter/foundation.dart';

/// Why a device was signed out (`device:revoked.reason`).
enum DeviceRevokedReason {
  signedOut('signed_out'),
  replaced('replaced'),
  evicted('evicted'),
  tokenReuse('token_reuse'),
  inactive('inactive');

  const DeviceRevokedReason(this.wire);

  final String wire;

  static DeviceRevokedReason fromWire(String value) =>
      values.firstWhere((r) => r.wire == value, orElse: () => signedOut);
}

/// Server event `device:revoked`: wipe local data and return to sign-in.
@immutable
class DeviceRevokedEvent {
  const DeviceRevokedEvent({required this.deviceId, required this.reason});

  final String deviceId;
  final DeviceRevokedReason reason;

  factory DeviceRevokedEvent.fromJson(Map<String, dynamic> json) =>
      DeviceRevokedEvent(
        deviceId: json['deviceId'] as String,
        reason: DeviceRevokedReason.fromWire(json['reason'] as String),
      );
}

/// Server event `profile:updated`, for the user or one of their contacts.
@immutable
class ProfileUpdatedEvent {
  const ProfileUpdatedEvent({
    required this.id,
    required this.displayName,
    required this.about,
    required this.avatarUrl,
    this.avatarThumbUrl,
  });

  final String id;
  final String? displayName;
  final String about;
  final String? avatarUrl;
  final String? avatarThumbUrl;

  factory ProfileUpdatedEvent.fromJson(Map<String, dynamic> json) =>
      ProfileUpdatedEvent(
        id: json['id'] as String,
        displayName: json['displayName'] as String?,
        about: json['about'] as String,
        avatarUrl: json['avatarUrl'] as String?,
        avatarThumbUrl: json['avatarThumbUrl'] as String?,
      );
}
