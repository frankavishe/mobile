import 'dart:convert';

import 'package:flutter/foundation.dart';

/// `kind` of a plaintext payload.
enum PayloadKind {
  text('text'),
  receipt('receipt'),
  groupUpdate('group_update');

  const PayloadKind(this.wire);

  final String wire;

  static PayloadKind? fromWire(Object? value) {
    for (final k in values) {
      if (k.wire == value) return k;
    }
    return null;
  }
}

enum ReceiptType {
  delivered,
  read;

  static ReceiptType? fromWire(Object? value) {
    for (final t in values) {
      if (t.name == value) return t;
    }
    return null;
  }
}

/// What travels inside every ciphertext (see phase.md, "Plaintext payload"):
/// `{v:1, kind, messageId, conversationId, sentAt, body?, receipt?: {type, messageIds},
/// group?: {name, memberIds}}`.
@immutable
class Payload {
  const Payload({
    required this.kind,
    required this.messageId,
    required this.conversationId,
    required this.sentAt,
    this.body,
    this.receiptType,
    this.receiptIds = const [],
    this.groupName,
    this.groupMemberIds = const [],
  });

  const Payload.text({
    required this.messageId,
    required this.conversationId,
    required this.sentAt,
    required String this.body,
  })  : kind = PayloadKind.text,
        receiptType = null,
        receiptIds = const [],
        groupName = null,
        groupMemberIds = const [];

  const Payload.receipt({
    required this.messageId,
    required this.conversationId,
    required this.sentAt,
    required ReceiptType this.receiptType,
    required this.receiptIds,
  })  : kind = PayloadKind.receipt,
        body = null,
        groupName = null,
        groupMemberIds = const [];

  /// Group metadata the server never sees: the name, and the member list as the sender
  /// knew it.
  const Payload.groupUpdate({
    required this.messageId,
    required this.conversationId,
    required this.sentAt,
    required String this.groupName,
    required this.groupMemberIds,
  })  : kind = PayloadKind.groupUpdate,
        body = null,
        receiptType = null,
        receiptIds = const [];

  static const version = 1;

  final PayloadKind kind;
  final String messageId;
  final String conversationId;
  final DateTime sentAt;
  final String? body;
  final ReceiptType? receiptType;
  final List<String> receiptIds;
  final String? groupName;
  final List<String> groupMemberIds;

  Map<String, dynamic> toJson() => {
        'v': version,
        'kind': kind.wire,
        'messageId': messageId,
        'conversationId': conversationId,
        'sentAt': sentAt.toUtc().toIso8601String(),
        'body': ?body,
        if (receiptType != null)
          'receipt': {'type': receiptType!.name, 'messageIds': receiptIds},
        if (groupName != null) 'group': {'name': groupName, 'memberIds': groupMemberIds},
      };

  String encode() => jsonEncode(toJson());

  Uint8List toBytes() => Uint8List.fromList(utf8.encode(encode()));

  /// Null for anything this version can't use: another `v`, an unknown kind, or bad fields.
  /// Unknown payloads are dropped rather than failing, so newer clients can add kinds.
  static Payload? tryParse(String json) {
    try {
      final m = jsonDecode(json);
      if (m is! Map<String, dynamic> || m['v'] != version) return null;
      final kind = PayloadKind.fromWire(m['kind']);
      if (kind == null) return null;
      final base = (
        messageId: m['messageId'] as String,
        conversationId: m['conversationId'] as String,
        sentAt: DateTime.parse(m['sentAt'] as String),
      );
      switch (kind) {
        case PayloadKind.text:
          final body = m['body'];
          if (body is! String) return null;
          return Payload.text(
            messageId: base.messageId,
            conversationId: base.conversationId,
            sentAt: base.sentAt,
            body: body,
          );
        case PayloadKind.receipt:
          final r = m['receipt'];
          if (r is! Map<String, dynamic>) return null;
          final type = ReceiptType.fromWire(r['type']);
          if (type == null) return null;
          return Payload.receipt(
            messageId: base.messageId,
            conversationId: base.conversationId,
            sentAt: base.sentAt,
            receiptType: type,
            receiptIds: [for (final id in r['messageIds'] as List) id as String],
          );
        case PayloadKind.groupUpdate:
          final g = m['group'];
          if (g is! Map<String, dynamic>) return null;
          final name = g['name'];
          if (name is! String) return null;
          return Payload.groupUpdate(
            messageId: base.messageId,
            conversationId: base.conversationId,
            sentAt: base.sentAt,
            groupName: name,
            groupMemberIds: [for (final id in (g['memberIds'] as List? ?? const [])) id as String],
          );
      }
    } catch (_) {
      return null;
    }
  }

  static Payload? fromBytes(Uint8List bytes) {
    try {
      return tryParse(utf8.decode(bytes));
    } on FormatException {
      return null;
    }
  }
}
