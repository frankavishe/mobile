import 'package:flutter/foundation.dart';

import 'api_error.dart';

/// `EnvelopeType` in the contract: `prekey` starts a Signal session
/// (PreKeySignalMessage), `whisper` is a normal SignalMessage.
enum EnvelopeType {
  prekey,
  whisper;

  static EnvelopeType fromJson(String value) => EnvelopeType.values.byName(value);

  String toJson() => name;
}

/// `OutgoingEnvelope`: one ciphertext for one recipient device.
@immutable
class OutgoingEnvelope {
  const OutgoingEnvelope({
    required this.deviceId,
    required this.type,
    required this.ciphertext,
  });

  final String deviceId;
  final EnvelopeType type;

  /// Base64 of the serialized Signal message.
  final String ciphertext;

  Map<String, dynamic> toJson() => {
        'deviceId': deviceId,
        'type': type.toJson(),
        'ciphertext': ciphertext,
      };
}

/// `SendMessageBody` for `POST /messages`.
@immutable
class SendMessageBody {
  const SendMessageBody({required this.conversationId, required this.envelopes});

  final String conversationId;
  final List<OutgoingEnvelope> envelopes;

  Map<String, dynamic> toJson() => {
        'conversationId': conversationId,
        'envelopes': [for (final e in envelopes) e.toJson()],
      };
}

/// `DeviceRef` in the contract.
@immutable
class DeviceRef {
  const DeviceRef({required this.userId, required this.deviceId});

  final String userId;
  final String deviceId;

  factory DeviceRef.fromJson(Map<String, dynamic> json) => DeviceRef(
        userId: json['userId'] as String,
        deviceId: json['deviceId'] as String,
      );

  Map<String, dynamic> toJson() => {'userId': userId, 'deviceId': deviceId};

  @override
  bool operator ==(Object other) =>
      other is DeviceRef && other.userId == userId && other.deviceId == deviceId;

  @override
  int get hashCode => Object.hash(userId, deviceId);
}

/// `DeviceMismatch`: `details` of a 409 `DEVICE_MISMATCH` from `POST /messages`.
@immutable
class DeviceMismatch {
  const DeviceMismatch({required this.missingDevices, required this.staleDevices});

  /// Active devices that got no envelope: fetch their bundles and resend.
  final List<DeviceRef> missingDevices;

  /// Devices that are gone: drop their sessions.
  final List<DeviceRef> staleDevices;

  factory DeviceMismatch.fromJson(Map<String, dynamic> json) => DeviceMismatch(
        missingDevices: [
          for (final d in json['missingDevices'] as List)
            DeviceRef.fromJson(d as Map<String, dynamic>),
        ],
        staleDevices: [
          for (final d in json['staleDevices'] as List)
            DeviceRef.fromJson(d as Map<String, dynamic>),
        ],
      );

  Map<String, dynamic> toJson() => {
        'missingDevices': [for (final d in missingDevices) d.toJson()],
        'staleDevices': [for (final d in staleDevices) d.toJson()],
      };
}

/// The device lists of a 409 `DEVICE_MISMATCH`, or null for any other error.
DeviceMismatch? deviceMismatchOf(ApiError e) {
  final details = e.details;
  if (e.code != ApiErrorCode.deviceMismatch || details == null) return null;
  return DeviceMismatch.fromJson(details);
}

/// `Envelope`: a ciphertext waiting for this device. Also the payload of the
/// `envelope:new` realtime event.
@immutable
class Envelope {
  const Envelope({
    required this.id,
    required this.conversationId,
    required this.senderUserId,
    required this.senderDeviceId,
    required this.type,
    required this.ciphertext,
    required this.serverTimestamp,
  });

  final String id;
  final String conversationId;
  final String senderUserId;
  final String senderDeviceId;
  final EnvelopeType type;
  final String ciphertext;
  final DateTime serverTimestamp;

  factory Envelope.fromJson(Map<String, dynamic> json) => Envelope(
        id: json['id'] as String,
        conversationId: json['conversationId'] as String,
        senderUserId: json['senderUserId'] as String,
        senderDeviceId: json['senderDeviceId'] as String,
        type: EnvelopeType.fromJson(json['type'] as String),
        ciphertext: json['ciphertext'] as String,
        serverTimestamp: DateTime.parse(json['serverTimestamp'] as String),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'conversationId': conversationId,
        'senderUserId': senderUserId,
        'senderDeviceId': senderDeviceId,
        'type': type.toJson(),
        'ciphertext': ciphertext,
        'serverTimestamp': serverTimestamp.toUtc().toIso8601String(),
      };
}
