import 'package:flutter/foundation.dart';

/// `DeviceType` in the contract.
enum DeviceType {
  android,
  web;

  static DeviceType fromJson(String value) => DeviceType.values.byName(value);

  String toJson() => name;
}

/// `Device` in the contract: one signed-in device of the current account.
@immutable
class Device {
  const Device({
    required this.id,
    required this.type,
    required this.name,
    required this.createdAt,
    required this.lastActiveAt,
    required this.current,
  });

  final String id;
  final DeviceType type;
  final String name;
  final DateTime createdAt;
  final DateTime lastActiveAt;

  /// True for the device making the request.
  final bool current;

  factory Device.fromJson(Map<String, dynamic> json) => Device(
        id: json['id'] as String,
        type: DeviceType.fromJson(json['type'] as String),
        name: json['name'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String),
        lastActiveAt: DateTime.parse(json['lastActiveAt'] as String),
        current: json['current'] as bool,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type.toJson(),
        'name': name,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'lastActiveAt': lastActiveAt.toUtc().toIso8601String(),
        'current': current,
      };
}
