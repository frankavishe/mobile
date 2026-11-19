import 'package:flutter/foundation.dart';

/// `ConversationType` in the contract.
enum ConversationType {
  direct,
  group;

  static ConversationType fromJson(String value) =>
      ConversationType.values.byName(value);

  String toJson() => name;
}

/// `MemberRole` in the contract.
enum MemberRole {
  admin,
  member;

  static MemberRole fromJson(String value) => MemberRole.values.byName(value);

  String toJson() => name;
}

/// `ConversationMember` in the contract.
@immutable
class ConversationMember {
  const ConversationMember({
    required this.userId,
    required this.role,
    required this.joinedAt,
  });

  final String userId;
  final MemberRole role;
  final DateTime joinedAt;

  factory ConversationMember.fromJson(Map<String, dynamic> json) =>
      ConversationMember(
        userId: json['userId'] as String,
        role: MemberRole.fromJson(json['role'] as String),
        joinedAt: DateTime.parse(json['joinedAt'] as String),
      );

  Map<String, dynamic> toJson() => {
        'userId': userId,
        'role': role.toJson(),
        'joinedAt': joinedAt.toUtc().toIso8601String(),
      };
}

/// `Conversation` in the contract. Holds routing data only: group names and
/// other metadata travel end-to-end encrypted inside messages.
@immutable
class Conversation {
  const Conversation({
    required this.id,
    required this.type,
    required this.createdAt,
    required this.members,
  });

  final String id;
  final ConversationType type;
  final DateTime createdAt;
  final List<ConversationMember> members;

  factory Conversation.fromJson(Map<String, dynamic> json) => Conversation(
        id: json['id'] as String,
        type: ConversationType.fromJson(json['type'] as String),
        createdAt: DateTime.parse(json['createdAt'] as String),
        members: [
          for (final m in json['members'] as List)
            ConversationMember.fromJson(m as Map<String, dynamic>),
        ],
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type.toJson(),
        'createdAt': createdAt.toUtc().toIso8601String(),
        'members': [for (final m in members) m.toJson()],
      };
}

/// `CreateConversationBody` for `POST /conversations`.
@immutable
sealed class CreateConversationBody {
  const CreateConversationBody();

  const factory CreateConversationBody.direct(String peerId) =
      CreateDirectConversation;
  const factory CreateConversationBody.group(List<String> memberIds) =
      CreateGroupConversation;

  Map<String, dynamic> toJson();
}

final class CreateDirectConversation extends CreateConversationBody {
  const CreateDirectConversation(this.peerId);

  final String peerId;

  @override
  Map<String, dynamic> toJson() => {'type': 'direct', 'peerId': peerId};
}

final class CreateGroupConversation extends CreateConversationBody {
  const CreateGroupConversation(this.memberIds);

  /// Other members (1–63); the caller becomes admin.
  final List<String> memberIds;

  @override
  Map<String, dynamic> toJson() => {'type': 'group', 'memberIds': memberIds};
}
