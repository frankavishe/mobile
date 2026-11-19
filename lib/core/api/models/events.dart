import 'package:flutter/foundation.dart';

import 'conversation.dart';

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

/// Server event `conversation:updated`: a conversation was created or its
/// members changed. [removed] is true when the current user was removed, in
/// which case [conversation] is null.
@immutable
class ConversationUpdatedEvent {
  const ConversationUpdatedEvent({
    required this.id,
    this.conversation,
    this.removed = false,
  });

  final String id;
  final Conversation? conversation;
  final bool removed;

  factory ConversationUpdatedEvent.fromJson(Map<String, dynamic> json) =>
      json['removed'] == true
          ? ConversationUpdatedEvent(id: json['id'] as String, removed: true)
          : ConversationUpdatedEvent(
              id: json['id'] as String,
              conversation: Conversation.fromJson(json),
            );
}

/// `typing.state`, in both directions.
enum TypingState {
  start,
  stop;

  static TypingState fromJson(String value) => TypingState.values.byName(value);

  String toJson() => name;
}

/// Server event `typing`: another member started or stopped typing.
@immutable
class TypingEvent {
  const TypingEvent({
    required this.conversationId,
    required this.userId,
    required this.state,
  });

  final String conversationId;
  final String userId;
  final TypingState state;

  factory TypingEvent.fromJson(Map<String, dynamic> json) => TypingEvent(
        conversationId: json['conversationId'] as String,
        userId: json['userId'] as String,
        state: TypingState.fromJson(json['state'] as String),
      );
}

/// Server event `prekeys:low`: upload more one-time prekeys.
@immutable
class PrekeysLowEvent {
  const PrekeysLowEvent({required this.count});

  final int count;

  factory PrekeysLowEvent.fromJson(Map<String, dynamic> json) =>
      PrekeysLowEvent(count: json['count'] as int);
}
