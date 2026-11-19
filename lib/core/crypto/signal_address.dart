import 'dart:convert';
import 'dart:typed_data';

import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

/// Every device is its own Signal address: `(deviceUUID, 1)`.
const signalDeviceId = 1;

SignalProtocolAddress addressOf(String deviceId) =>
    SignalProtocolAddress(deviceId, signalDeviceId);

/// Keys and signatures are base64 on the wire (public keys are 33 bytes, 0x05-prefixed).
String b64(Uint8List bytes) => base64Encode(bytes);

Uint8List unb64(String value) => base64Decode(value);
