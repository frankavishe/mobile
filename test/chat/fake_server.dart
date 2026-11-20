import 'dart:async';

import 'package:chat_app/core/api/api_client.dart';
import 'package:chat_app/core/api/models/models.dart';
import 'package:chat_app/core/crypto/envelope_cipher.dart';
import 'package:chat_app/core/crypto/key_manager.dart';
import 'package:chat_app/core/db/app_database.dart';
import 'package:chat_app/features/chat/messaging_service.dart';
import 'package:drift/native.dart';
import 'package:uuid/uuid.dart';

import '../support/fakes.dart';

const _uuid = Uuid();

/// An in-memory stand-in for the API's keys, conversations and messages modules, with the same
/// rules: bundles pop one prekey, `POST /messages` must cover exactly the other key-holding
/// devices of the members (409 `DEVICE_MISMATCH` otherwise), envelopes wait until acked.
class FakeServer {
  /// userId → deviceIds. Like the real server, revoked devices keep their row.
  final users = <String, List<String>>{};
  final revoked = <String>{};
  final keys = <String, UploadKeysBody>{};
  final usedPreKeys = <String, Set<int>>{};
  final conversations = <String, Conversation>{};
  final queues = <String, List<Envelope>>{};
  final sockets = <String, FakeSocketService>{};

  /// Devices whose socket is down (no push) or whose network is down (every call fails).
  final offline = <String>{};

  /// Every body accepted by `POST /messages`, for assertions.
  final sent = <SendMessageBody>[];

  String userOf(String deviceId) =>
      users.entries.firstWhere((e) => e.value.contains(deviceId)).key;

  bool isActive(String deviceId) => !revoked.contains(deviceId) && keys.containsKey(deviceId);

  void revoke(String deviceId) {
    revoked.add(deviceId);
    keys.remove(deviceId);
    queues.remove(deviceId);
  }

  Conversation direct(String a, String b) {
    for (final c in conversations.values) {
      final ids = c.members.map((m) => m.userId).toSet();
      if (c.type == ConversationType.direct && ids.containsAll([a, b]) && ids.length == 2) {
        return c;
      }
    }
    final c = Conversation(
      id: _uuid.v4(),
      type: ConversationType.direct,
      createdAt: DateTime.utc(2026, 11, 19),
      members: [
        for (final u in [a, b])
          ConversationMember(userId: u, role: MemberRole.member, joinedAt: DateTime.utc(2026)),
      ],
    );
    return conversations[c.id] = c;
  }

  List<String> _members(String conversationId) =>
      conversations[conversationId]!.members.map((m) => m.userId).toList();

  /// Public profiles for `GET /users`.
  final profiles = <String, PublicUser>{};

  int _joined = 0;

  /// Later joins sort after earlier ones (for admin promotion).
  DateTime _nextJoin() => DateTime.utc(2026).add(Duration(seconds: _joined++));

  Conversation group(String admin, List<String> others) {
    final c = Conversation(
      id: _uuid.v4(),
      type: ConversationType.group,
      createdAt: DateTime.utc(2026, 11, 19),
      members: [
        ConversationMember(userId: admin, role: MemberRole.admin, joinedAt: _nextJoin()),
        for (final u in others)
          ConversationMember(userId: u, role: MemberRole.member, joinedAt: _nextJoin()),
      ],
    );
    conversations[c.id] = c;
    _announce(c);
    return c;
  }

  /// `conversation:updated` to every device of every member.
  void _announce(Conversation c) {
    for (final m in c.members) {
      _push(m.userId, ConversationUpdatedEvent(id: c.id, conversation: c));
    }
  }

  void _push(String userId, ConversationUpdatedEvent e) {
    for (final d in users[userId] ?? const <String>[]) {
      final socket = sockets[d];
      if (socket != null && !offline.contains(d)) socket.conversations.add(e);
    }
  }

  static const _forbidden =
      ApiError(status: 403, code: ApiErrorCode.forbidden, message: 'Admins only');

  Conversation addMembers(String caller, String id, List<String> userIds) {
    final c = conversations[id]!;
    final me = c.members.firstWhere((m) => m.userId == caller);
    if (me.role != MemberRole.admin) throw _forbidden;
    final updated = Conversation(
      id: c.id,
      type: c.type,
      createdAt: c.createdAt,
      members: [
        ...c.members,
        for (final u in userIds)
          if (!c.members.any((m) => m.userId == u))
            ConversationMember(userId: u, role: MemberRole.member, joinedAt: _nextJoin()),
      ],
    );
    conversations[id] = updated;
    _announce(updated);
    return updated;
  }

  void removeMember(String caller, String id, String target) {
    final c = conversations[id]!;
    final me = c.members.firstWhere((m) => m.userId == caller);
    if (caller != target && me.role != MemberRole.admin) throw _forbidden;
    var rest = c.members.where((m) => m.userId != target).toList();
    if (rest.isNotEmpty && !rest.any((m) => m.role == MemberRole.admin)) {
      rest.sort((a, b) => a.joinedAt.compareTo(b.joinedAt));
      final oldest = rest.first;
      rest = [
        ConversationMember(userId: oldest.userId, role: MemberRole.admin, joinedAt: oldest.joinedAt),
        ...rest.skip(1),
      ];
    }
    final updated =
        Conversation(id: c.id, type: c.type, createdAt: c.createdAt, members: rest);
    conversations[id] = updated;
    _announce(updated);
    _push(target, ConversationUpdatedEvent(id: id, removed: true));
  }
}

/// `ApiClient` for one device, backed by [FakeServer].
class FakeApi implements ApiClient {
  FakeApi(this.server, this.userId, this.deviceId);

  final FakeServer server;
  final String userId;
  final String deviceId;

  void _online() {
    if (server.offline.contains(deviceId)) throw const ApiError.network();
  }

  @override
  Future<void> uploadKeys(UploadKeysBody body) async {
    _online();
    final old = server.keys[deviceId];
    server.keys[deviceId] = UploadKeysBody(
      registrationId: body.registrationId,
      identityKey: body.identityKey,
      signedPreKey: body.signedPreKey ?? old?.signedPreKey,
      preKeys: [...?old?.preKeys, ...body.preKeys],
    );
  }

  @override
  Future<int> getKeyCount() async {
    _online();
    final k = server.keys[deviceId];
    final used = server.usedPreKeys[deviceId] ?? {};
    return k == null ? 0 : k.preKeys.where((p) => !used.contains(p.keyId)).length;
  }

  @override
  Future<UserKeys> getUserKeys(String userId, {List<String>? deviceIds}) async {
    _online();
    final devices = <DeviceBundle>[];
    for (final d in server.users[userId] ?? const <String>[]) {
      if (d == deviceId || (deviceIds != null && !deviceIds.contains(d))) continue;
      if (!server.isActive(d)) continue;
      final k = server.keys[d]!;
      final used = server.usedPreKeys[d] ??= {};
      final pk = k.preKeys.where((p) => !used.contains(p.keyId)).firstOrNull;
      if (pk != null) used.add(pk.keyId);
      devices.add(DeviceBundle(
        deviceId: d,
        registrationId: k.registrationId,
        identityKey: k.identityKey,
        signedPreKey: k.signedPreKey!,
        preKey: pk,
      ));
    }
    return UserKeys(userId: userId, devices: devices);
  }

  @override
  Future<List<Conversation>> listConversations() async {
    _online();
    return [
      for (final c in server.conversations.values)
        if (c.members.any((m) => m.userId == userId)) c,
    ];
  }

  @override
  Future<Conversation> getConversation(String id) async {
    _online();
    final c = server.conversations[id];
    if (c == null || !c.members.any((m) => m.userId == userId)) {
      throw const ApiError(
        status: 404,
        code: ApiErrorCode.conversationNotFound,
        message: 'Conversation not found',
      );
    }
    return c;
  }

  @override
  Future<Conversation> createConversation(CreateConversationBody body) async {
    _online();
    return switch (body) {
      CreateDirectConversation(:final peerId) => server.direct(userId, peerId),
      CreateGroupConversation(:final memberIds) => server.group(userId, memberIds),
    };
  }

  @override
  Future<Conversation> addMembers(String conversationId, List<String> userIds) async {
    _online();
    return server.addMembers(userId, conversationId, userIds);
  }

  @override
  Future<void> removeMember(String conversationId, String userId) async {
    _online();
    server.removeMember(this.userId, conversationId, userId);
  }

  @override
  Future<List<PublicUser>> getUsers(List<String> ids) async {
    _online();
    return [
      for (final id in ids)
        if (server.profiles[id] != null) server.profiles[id]!,
    ];
  }

  @override
  Future<DateTime> sendMessage(SendMessageBody body) async {
    _online();
    if (!server.conversations.containsKey(body.conversationId)) {
      throw const ApiError(
        status: 404,
        code: ApiErrorCode.conversationNotFound,
        message: 'Conversation not found',
      );
    }
    if (!server._members(body.conversationId).contains(userId)) {
      throw const ApiError(
        status: 403,
        code: ApiErrorCode.notAMember,
        message: 'Not a member',
      );
    }
    final expected = <DeviceRef>[
      for (final u in server._members(body.conversationId))
        for (final d in server.users[u]!)
          if (d != deviceId && server.isActive(d)) DeviceRef(userId: u, deviceId: d),
    ];
    final given = body.envelopes.map((e) => e.deviceId).toSet();
    final missing = expected.where((d) => !given.contains(d.deviceId)).toList();
    final stale = [
      for (final d in given)
        if (!expected.any((e) => e.deviceId == d))
          DeviceRef(userId: server.userOf(d), deviceId: d),
    ];
    if (missing.isNotEmpty || stale.isNotEmpty) {
      throw ApiError(
        status: 409,
        code: ApiErrorCode.deviceMismatch,
        message: 'Device list is out of date',
        details: DeviceMismatch(missingDevices: missing, staleDevices: stale).toJson(),
      );
    }
    server.sent.add(body);
    final now = DateTime.now().toUtc();
    for (final e in body.envelopes) {
      final env = Envelope(
        id: _uuid.v4(),
        conversationId: body.conversationId,
        senderUserId: userId,
        senderDeviceId: deviceId,
        type: e.type,
        ciphertext: e.ciphertext,
        serverTimestamp: now,
      );
      (server.queues[e.deviceId] ??= []).add(env);
      final socket = server.sockets[e.deviceId];
      if (socket != null && !server.offline.contains(e.deviceId)) socket.envelopes.add(env);
    }
    return now;
  }

  @override
  Future<List<Envelope>> listEnvelopes({int limit = 100}) async {
    _online();
    return (server.queues[deviceId] ?? []).take(limit).toList();
  }

  @override
  Future<void> ackEnvelopes(List<String> ids) async {
    _online();
    server.queues[deviceId]?.removeWhere((e) => ids.contains(e.id));
  }

  @override
  Future<List<PublicUser>> listContacts() async {
    _online();
    return const [];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// One signed-in device: its own encrypted-store stand-in, keys, socket and messaging service.
class TestDevice {
  TestDevice(this.server, this.userId, this.deviceId) {
    (server.users[userId] ??= []).add(deviceId);
    server.sockets[deviceId] = socket;
  }

  final FakeServer server;
  final String userId;
  final String deviceId;
  final db = AppDatabase(NativeDatabase.memory());
  final socket = FakeSocketService();
  late final api = FakeApi(server, userId, deviceId);
  late final keys = KeyManager(api: api, db: db);
  late final cipher = EnvelopeCipher(keys.store);
  DateTime clock = DateTime.utc(2026, 11, 19, 12);
  late final service = MessagingService(
    api: api,
    db: db,
    cipher: cipher,
    socket: socket,
    me: () => (userId: userId, deviceId: deviceId),
    now: () => clock,
  );

  Future<void> boot() async {
    await keys.ensureKeys();
    service.start();
  }

  void goOffline() => server.offline.add(deviceId);

  /// Back online: what the socket's reconnect does.
  void goOnline() {
    server.offline.remove(deviceId);
    socket.connectedEvents.add(null);
  }

  Future<List<Message>> messages(String conversationId) => db.messagesIn(conversationId);

  Future<void> close() async {
    service.dispose();
    socket.dispose();
    await db.close();
  }
}

/// Polls [check] until it passes (or fails after [timeout]).
Future<void> eventually(
  FutureOr<void> Function() check, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final end = DateTime.now().add(timeout);
  while (true) {
    try {
      await check();
      return;
    } catch (_) {
      if (DateTime.now().isAfter(end)) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }
}
