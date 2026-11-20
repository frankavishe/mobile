import 'dart:async';
import 'dart:math';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart'
    show DuplicateMessageException;
import 'package:uuid/uuid.dart';

import '../../core/api/api_client.dart';
import '../../core/api/models/models.dart' as api;
import '../../core/auth/session.dart';
import '../../core/crypto/envelope_cipher.dart';
import '../../core/db/app_database.dart';
import '../../core/db/db_opener.dart';
import '../../core/phone.dart';
import '../../core/realtime/socket_service.dart';
import 'payload.dart';

/// Who this device is; read on every use because the session can change.
typedef LocalIdentityIds = ({String userId, String deviceId});

/// End-to-end encrypted messaging for this device (phase.md, Phase 4).
///
/// - **Send:** the message is stored as `pending` with its plaintext payload in the outbox, then
///   encrypted once per device of every member (plus this user's other devices, as sync copies)
///   and posted with `POST /messages`. A 409 `DEVICE_MISMATCH` corrects the device list and the
///   batch is rebuilt. Network errors back off and retry; other errors mark it `failed`.
/// - **Receive:** envelopes from `envelope:new` and from `GET /envelopes` on every (re)connect are
///   decrypted one at a time, stored, and only then acknowledged.
/// - **Receipts** are encrypted messages too: `delivered` when a message is stored, `read` when
///   its conversation is open.
/// - **Typing** is an unencrypted, never-stored relay over the socket.
class MessagingService {
  MessagingService({
    required this._api,
    required this._db,
    required this._cipher,
    required this._socket,
    required this._me,
    DateTime Function()? now,
    Uuid? uuid,
  })  : _now = now ?? DateTime.now,
        _uuid = uuid ?? const Uuid();

  final ApiClient _api;
  final AppDatabase _db;
  final EnvelopeCipher _cipher;
  final SocketService _socket;
  final LocalIdentityIds? Function() _me;
  final DateTime Function() _now;
  final Uuid _uuid;

  /// Send attempts before a message is marked failed.
  static const maxAttempts = 8;
  static const maxBackoff = Duration(minutes: 5);

  /// Rebuilds of one batch after `DEVICE_MISMATCH` before giving up for this attempt.
  static const maxMismatchRetries = 3;

  static const typingRefresh = Duration(seconds: 3);
  static const typingIdle = Duration(seconds: 5);

  final _subs = <StreamSubscription<Object?>>[];
  bool _running = false;

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  bool get isRunning => _running;

  /// Starts listening and catches up: conversations, pending envelopes, then the outbox.
  void start() {
    if (_running) return;
    _running = true;
    _subs
      ..add(_socket.envelopeNew.listen((e) => _receive([e])))
      ..add(_socket.connected.listen((_) => sync()))
      ..add(_socket.conversationUpdated.listen((e) {
        _onConversationUpdated(e).catchError((Object err) {
          // E.g. the database closed on sign-out; the next sync catches up.
          debugPrint('messaging: conversation update failed: $err');
        });
      }))
      ..add(_socket.typing.listen(_onTyping))
      ..add(_socket.profileUpdated.listen(_onProfileUpdated));
    unawaited(sync());
  }

  /// Stops all work; nothing touches the database afterwards (it may be wiped next).
  void stop() {
    _running = false;
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    _outboxTimer?.cancel();
    _outboxTimer = null;
    _typingIdleTimer?.cancel();
    _typingSentAt = null;
    _typingConversation = null;
    for (final users in _typing.values) {
      for (final t in users.values) {
        t.cancel();
      }
    }
    _typing.clear();
    _openConversation = null;
  }

  // ---------------------------------------------------------------------------
  // Catching up
  // ---------------------------------------------------------------------------

  Future<void>? _syncInFlight;
  bool _syncAgain = false;

  /// Fetches conversations, contacts' names and pending envelopes, then flushes the outbox.
  /// Calls made while a sync runs cause one more run afterwards.
  Future<void> sync() {
    if (_syncInFlight != null) {
      _syncAgain = true;
      return _syncInFlight!;
    }
    return _syncInFlight = _sync().whenComplete(() {
      _syncInFlight = null;
      if (_syncAgain && _running) {
        _syncAgain = false;
        unawaited(sync());
      }
    });
  }

  Future<void> _sync() async {
    if (!_running) return;
    try {
      final current = await _api.listConversations();
      for (final c in current) {
        if (!_running) return;
        await _saveConversation(c);
      }
      // Groups we were removed from while offline.
      final ids = {for (final c in current) c.id};
      for (final local in await _db.allConversations()) {
        if (!_running) return;
        if (local.kind == ConversationKind.group && local.active && !ids.contains(local.id)) {
          await _markRemoved(local.id, 'You were removed');
        }
      }
      cacheUsers(await _api.listContacts());
    } on api.ApiError catch (e) {
      debugPrint('messaging: conversation sync failed: $e');
    }
    try {
      while (_running) {
        final page = await _api.listEnvelopes();
        if (page.isEmpty) break;
        final handled = await _receive(page);
        // Stopped on a transient error; the rest comes with the next sync.
        if (handled < page.length) break;
      }
    } on api.ApiError catch (e) {
      debugPrint('messaging: envelope fetch failed: $e');
    }
    if (!_running) return;
    await _db.outboxDueNow(_now());
    _kickOutbox();
  }

  // ---------------------------------------------------------------------------
  // Conversations and users
  // ---------------------------------------------------------------------------

  /// Opens (or creates) the direct chat with [user] and returns its id.
  Future<String> startDirect(api.PublicUser user) async {
    await _cacheUser(user);
    final c = await _api.createConversation(api.CreateConversationBody.direct(user.id));
    await _saveConversation(c);
    return c.id;
  }

  void cacheUsers(Iterable<api.PublicUser>? users) {
    if (users == null || !_running) return;
    for (final u in users) {
      unawaited(_cacheUser(u));
    }
  }

  Future<void> _cacheUser(api.PublicUser u) => _db.cacheUser(CachedUsersCompanion.insert(
        id: u.id,
        displayName: Value(u.displayName),
        phone: Value(u.phone),
        avatarThumbUrl: Value(u.avatarThumbUrl ?? u.avatarUrl),
      ));

  Future<void> _onProfileUpdated(api.ProfileUpdatedEvent e) async {
    final known = await _db.cachedUser(e.id);
    if (known == null) return;
    await _db.cacheUser(CachedUsersCompanion(
      id: Value(e.id),
      displayName: Value(e.displayName),
      phone: Value(known.phone),
      avatarThumbUrl: Value(e.avatarThumbUrl ?? e.avatarUrl),
    ));
  }

  /// Stores [c] and its members. For a group already known here, member changes become
  /// system notes ("Bob joined", "Bob left").
  Future<void> _saveConversation(api.Conversation c) async {
    final me = _me();
    if (me == null) return;
    final isGroup = c.type == api.ConversationType.group;
    final peer = isGroup
        ? null
        : c.members.map((m) => m.userId).where((id) => id != me.userId).firstOrNull;
    final kind = isGroup ? ConversationKind.group : ConversationKind.direct;
    final memberIds = [for (final m in c.members) m.userId];
    if (isGroup) await _fetchUsers(memberIds);
    var someoneLeft = false;
    await _db.transaction(() async {
      final local = await _db.conversationById(c.id);
      if (local == null) {
        await _db.upsertConversation(ConversationsCompanion.insert(
          id: c.id,
          kind: kind,
          peerUserId: Value(peer),
          updatedAt: c.createdAt,
        ));
      } else if (isGroup) {
        final before = {for (final m in await _db.membersOf(c.id)) m.userId};
        final after = memberIds.toSet();
        final now = _now();
        if (!local.active && after.contains(me.userId)) {
          await _db.setActive(c.id, active: true);
          await _note(c.id, 'You were added', now);
        }
        for (final id in after.difference(before)) {
          if (id != me.userId) await _note(c.id, '${await _nameOf(id)} joined', now);
        }
        for (final id in before.difference(after)) {
          if (id == me.userId) continue;
          someoneLeft = true;
          await _note(c.id, '${await _nameOf(id)} left', now);
        }
      }
      await _db.setMembers(c.id, [
        for (final m in c.members)
          MembersCompanion.insert(
            conversationId: c.id,
            userId: m.userId,
            role: Value(m.role.toJson()),
          ),
      ]);
    });
    // Members who left no longer hold back delivered/read ticks.
    if (someoneLeft) await _db.reaggregate(c.id, me.userId);
  }

  Future<void> _onConversationUpdated(api.ConversationUpdatedEvent e) async {
    if (!_running) return;
    final c = e.conversation;
    if (e.removed) {
      // The event for our own leave can arrive before leaveGroup() returns.
      await _markRemoved(e.id, _leaving.contains(e.id) ? 'You left' : 'You were removed');
    } else if (c != null) {
      await _saveConversation(c);
    }
  }

  /// Keeps the history but makes the group read-only. Nothing happens when it already is
  /// (e.g. the server's `removed` event after we left ourselves).
  Future<void> _markRemoved(String conversationId, String note) => _db.transaction(() async {
        final local = await _db.conversationById(conversationId);
        if (local == null || !local.active) return;
        await _db.setActive(conversationId, active: false);
        await _note(conversationId, note, _now());
      });

  Future<void> _note(String conversationId, String text, DateTime at) =>
      _db.insertMessage(MessagesCompanion.insert(
        id: 'note-${_uuid.v4()}',
        conversationId: conversationId,
        senderUserId: '',
        senderDeviceId: '',
        kind: const Value(MessageKind.system),
        body: Value(text),
        sentAt: at,
        receivedAt: Value(at),
        status: MessageStatus.delivered,
      ));

  /// "You", the cached name or number, else "Someone".
  Future<String> _nameOf(String userId) async {
    if (userId == _me()?.userId) return 'You';
    final u = await _db.cachedUser(userId);
    final name = u?.displayName;
    if (name != null && name.isNotEmpty) return name;
    final phone = u?.phone;
    if (phone != null && phone.isNotEmpty) return formatPhone(phone);
    return 'Someone';
  }

  /// Ids already asked for with `GET /users` this session.
  final _requestedUsers = <String>{};

  /// Caches profiles of users we have no name for (e.g. group members who aren't
  /// contacts). Errors are ignored; each id is asked for once per session.
  Future<void> _fetchUsers(Iterable<String> ids) async {
    if (!_running) return;
    final me = _me()?.userId;
    final missing = <String>[];
    for (final id in ids.toSet()) {
      if (id == me || _requestedUsers.contains(id)) continue;
      if (await _db.cachedUser(id) != null) continue;
      missing.add(id);
    }
    if (missing.isEmpty) return;
    _requestedUsers.addAll(missing);
    try {
      final users = await _api.getUsers(missing);
      if (!_running) return;
      for (final u in users) {
        await _cacheUser(u);
      }
    } on api.ApiError catch (e) {
      _requestedUsers.removeAll(missing);
      debugPrint('messaging: user lookup failed: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Groups
  // ---------------------------------------------------------------------------

  /// Creates a group with [users] (this user becomes admin), names it, and sends the
  /// encrypted name to everyone. Returns the conversation id.
  Future<String> createGroup(String name, List<api.PublicUser> users) async {
    for (final u in users) {
      await _cacheUser(u);
    }
    final c = await _api.createConversation(
      api.CreateConversationBody.group([for (final u in users) u.id]),
    );
    await _saveConversation(c);
    final now = _now();
    await _db.setConversationName(c.id, name, now);
    await _note(c.id, "You created group '$name'", now);
    await _queueGroupUpdate(c.id, name, now);
    return c.id;
  }

  /// Admins only. New members learn the name from a fresh `group_update`.
  Future<void> addMembers(String conversationId, List<api.PublicUser> users) async {
    for (final u in users) {
      await _cacheUser(u);
    }
    final c = await _api.addMembers(conversationId, [for (final u in users) u.id]);
    await _saveConversation(c);
    final name = (await _db.conversationById(conversationId))?.name;
    if (name != null) await _queueGroupUpdate(conversationId, name, _now());
  }

  /// Admins only.
  Future<void> removeMember(String conversationId, String userId) async {
    await _api.removeMember(conversationId, userId);
    await _saveConversation(await _api.getConversation(conversationId));
  }

  /// Leaves the group; its history stays here, read-only.
  Future<void> leaveGroup(String conversationId) async {
    final me = _me()!;
    _leaving.add(conversationId);
    try {
      await _api.removeMember(conversationId, me.userId);
      await _markRemoved(conversationId, 'You left');
    } finally {
      _leaving.remove(conversationId);
    }
  }

  /// Groups this device is leaving right now.
  final _leaving = <String>{};

  /// Admins only. Other members apply it when it is newer than the name they have.
  Future<void> renameGroup(String conversationId, String name) async {
    final now = _now();
    if (!await _db.setConversationName(conversationId, name, now)) return;
    await _note(conversationId, "You changed the group name to '$name'", now);
    await _queueGroupUpdate(conversationId, name, now);
  }

  /// Deletes the chat and its messages from this device only.
  Future<void> deleteConversation(String conversationId) =>
      _db.deleteConversation(conversationId);

  Future<void> _queueGroupUpdate(String conversationId, String name, DateTime at) async {
    await _enqueue(Payload.groupUpdate(
      messageId: _uuid.v4(),
      conversationId: conversationId,
      sentAt: at,
      groupName: name,
      groupMemberIds: [for (final m in await _db.membersOf(conversationId)) m.userId],
    ));
    _kickOutbox();
  }

  Future<void> _applyGroupUpdate(api.Envelope e, Payload p, {required bool fromMe}) async {
    final local = await _db.conversationById(p.conversationId);
    if (local == null || local.kind != ConversationKind.group) return;
    // The server can't check encrypted metadata: only admins may change it.
    final sender = (await _db.membersOf(p.conversationId))
        .where((m) => m.userId == e.senderUserId)
        .firstOrNull;
    if (sender == null || sender.role != api.MemberRole.admin.toJson()) return;
    final name = p.groupName!.trim();
    if (name.isEmpty) return;
    final previous = local.name;
    if (!await _db.setConversationName(p.conversationId, name, p.sentAt)) return;
    // The first name a device learns (on creation or when added) is not a change.
    if (previous != null && previous != name) {
      final who = fromMe ? 'You' : await _nameOf(e.senderUserId);
      await _note(p.conversationId, "$who changed the group name to '$name'", p.sentAt);
    }
  }

  /// Makes sure [id] exists locally. Returns false when the server says it is gone for us.
  Future<bool> _ensureConversation(String id) async {
    if (await _db.conversationById(id) != null) return true;
    try {
      await _saveConversation(await _api.getConversation(id));
      return true;
    } on api.ApiError catch (e) {
      if (e.status == 404 || e.status == 403) return false;
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // Sending
  // ---------------------------------------------------------------------------

  /// Stores [body] as `pending` and queues it. Returns the message id.
  Future<String> sendText(String conversationId, String body) async {
    final me = _me()!;
    final now = _now();
    final payload = Payload.text(
      messageId: _uuid.v4(),
      conversationId: conversationId,
      sentAt: now,
      body: body,
    );
    await _db.transaction(() async {
      await _db.insertMessage(MessagesCompanion.insert(
        id: payload.messageId,
        conversationId: conversationId,
        senderUserId: me.userId,
        senderDeviceId: me.deviceId,
        body: Value(body),
        sentAt: now,
        status: MessageStatus.pending,
      ));
      await _db.touchConversation(conversationId, now);
      await _enqueue(payload);
    });
    _stopTyping(conversationId);
    _kickOutbox();
    return payload.messageId;
  }

  /// Queues a failed message again.
  Future<void> retry(String messageId) async {
    final m = await _db.messageById(messageId);
    if (m == null || m.status != MessageStatus.failed || m.body == null) return;
    await _db.transaction(() async {
      await _db.updateMessageStatus(messageId, MessageStatus.pending);
      await _enqueue(Payload.text(
        messageId: m.id,
        conversationId: m.conversationId,
        sentAt: m.sentAt,
        body: m.body!,
      ));
    });
    _kickOutbox();
  }

  Future<void> _queueReceipt(String conversationId, ReceiptType type, List<String> ids) async {
    if (ids.isEmpty) return;
    if ((await _db.conversationById(conversationId))?.active != true) return;
    await _enqueue(Payload.receipt(
      messageId: _uuid.v4(),
      conversationId: conversationId,
      sentAt: _now(),
      receiptType: type,
      receiptIds: ids,
    ));
    _kickOutbox();
  }

  Future<void> _enqueue(Payload p) => _db.enqueueOutbox(OutboxCompanion.insert(
        messageId: p.messageId,
        conversationId: p.conversationId,
        payload: p.encode(),
        nextAttemptAt: _now(),
        createdAt: _now(),
      ));

  bool _draining = false;
  bool _drainAgain = false;
  Timer? _outboxTimer;

  void _kickOutbox() {
    if (!_running) return;
    if (_draining) {
      _drainAgain = true;
      return;
    }
    _draining = true;
    _drainOutbox().catchError((Object e) {
      debugPrint('messaging: outbox failed: $e');
    }).whenComplete(() {
      _draining = false;
      if (_drainAgain) {
        _drainAgain = false;
        _kickOutbox();
      }
    });
  }

  /// Completes when the outbox has nothing due (for tests and the UI's retry).
  Future<void> flush() async {
    _kickOutbox();
    while (_draining) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }

  Future<void> _drainOutbox() async {
    _outboxTimer?.cancel();
    for (final item in await _db.dueOutbox(_now())) {
      if (!_running) return;
      // Stop at the first transient failure so later messages don't overtake it.
      if (!await _attempt(item)) break;
    }
    if (!_running) return;
    final next = await _db.nextOutboxDue();
    if (next != null) {
      final wait = next.difference(_now());
      _outboxTimer = Timer(wait.isNegative ? Duration.zero : wait, _kickOutbox);
    }
  }

  /// Returns false when sending should pause (offline, rate limited, server trouble).
  Future<bool> _attempt(OutboxData item) async {
    final payload = Payload.tryParse(item.payload);
    if (payload == null) {
      await _db.removeOutbox(item.id);
      return true;
    }
    final isText = payload.kind == PayloadKind.text;
    final conversation = await _db.conversationById(item.conversationId);
    if (conversation == null || !conversation.active) {
      // We left or were removed: the server would refuse it.
      await _fail(item, isText);
      return true;
    }
    try {
      await _deliver(item.conversationId, payload);
      await _db.removeOutbox(item.id);
      if (isText) await _db.updateMessageStatus(payload.messageId, MessageStatus.sent);
      return true;
    } on api.ApiError catch (e) {
      final attempts = item.attempts + 1;
      if (_isTransient(e) && attempts < maxAttempts) {
        final backoff = Duration(seconds: min(1 << attempts, maxBackoff.inSeconds));
        final wait = e.retryAfter != null && e.retryAfter! > backoff.inSeconds
            ? Duration(seconds: e.retryAfter!)
            : backoff;
        await _db.rescheduleOutbox(item.id, attempts: attempts, next: _now().add(wait));
        return false;
      }
      debugPrint('messaging: giving up on ${payload.messageId}: $e');
      await _fail(item, isText);
      return true;
    } catch (e) {
      // Crypto failures (e.g. a peer's identity key changed) won't fix themselves.
      debugPrint('messaging: cannot send ${payload.messageId}: $e');
      await _fail(item, isText);
      return true;
    }
  }

  Future<void> _fail(OutboxData item, bool isText) async {
    await _db.removeOutbox(item.id);
    if (isText) await _db.updateMessageStatus(item.messageId, MessageStatus.failed);
  }

  static bool _isTransient(api.ApiError e) =>
      e.code == api.ApiErrorCode.network ||
      e.code == api.ApiErrorCode.deviceMismatch ||
      e.code == api.ApiErrorCode.keysNotUploaded ||
      e.status == 429 ||
      e.status >= 500;

  /// Encrypts [payload] for every other device in the conversation and posts the batch.
  Future<void> _deliver(String conversationId, Payload payload) async {
    final me = _me()!;
    final plaintext = payload.toBytes();
    for (var round = 0;; round++) {
      final users = {
        me.userId,
        for (final m in await _db.membersOf(conversationId)) m.userId,
      };
      final targets = <api.DeviceRef>[
        for (final u in users)
          for (final d in await _db.devicesOf(u))
            if (d != me.deviceId) api.DeviceRef(userId: u, deviceId: d),
      ];
      await _ensureSessions(targets);

      final envelopes = <api.OutgoingEnvelope>[];
      for (final t in targets) {
        if (await _cipher.hasSession(t.deviceId)) {
          envelopes.add(await _cipher.encrypt(t.deviceId, plaintext));
        }
      }
      try {
        await _api.sendMessage(
          api.SendMessageBody(conversationId: conversationId, envelopes: envelopes),
        );
        return;
      } on api.ApiError catch (e) {
        final mismatch = api.deviceMismatchOf(e);
        if (mismatch == null || round >= maxMismatchRetries) rethrow;
        for (final d in mismatch.staleDevices) {
          await _db.removeDevice(d.userId, d.deviceId);
          await _cipher.deleteSession(d.deviceId);
        }
        for (final d in mismatch.missingDevices) {
          await _db.addDevice(d.userId, d.deviceId);
        }
        // A member we don't know yet (added elsewhere): refresh the member list.
        if (mismatch.missingDevices.any((d) => !users.contains(d.userId))) {
          await _saveConversation(await _api.getConversation(conversationId));
        }
      }
    }
  }

  /// Fetches bundles for [targets] without a session. Devices the server returns no bundle for
  /// have no keys any more and are forgotten.
  Future<void> _ensureSessions(List<api.DeviceRef> targets) async {
    final missing = <String, List<String>>{};
    for (final t in targets) {
      if (!await _cipher.hasSession(t.deviceId)) {
        (missing[t.userId] ??= []).add(t.deviceId);
      }
    }
    for (final MapEntry(key: userId, value: deviceIds) in missing.entries) {
      final keys = await _api.getUserKeys(userId, deviceIds: deviceIds);
      final returned = <String>{};
      for (final b in keys.devices) {
        await _cipher.processBundle(b);
        returned.add(b.deviceId);
      }
      for (final d in deviceIds) {
        if (!returned.contains(d)) await _db.removeDevice(userId, d);
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Receiving
  // ---------------------------------------------------------------------------

  Future<void> _receiveTail = Future.value();

  /// Recently handled envelope ids: a push and a fetch can deliver the same one.
  final _seen = <String>{};
  static const _seenMax = 2000;

  /// Handles [envelopes] in order, after any batch already running. Returns how many were
  /// handled (and acknowledged) before a transient error stopped the batch.
  Future<int> _receive(List<api.Envelope> envelopes) {
    final result = _receiveTail.then((_) => _receiveBatch(envelopes));
    _receiveTail = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<int> _receiveBatch(List<api.Envelope> envelopes) async {
    final handled = <String>[];
    final delivered = <String, List<String>>{};
    try {
      for (final e in envelopes) {
        if (!_running) break;
        final id = await _handle(e);
        handled.add(e.id);
        if (id != null) (delivered[e.conversationId] ??= []).add(id);
      }
    } catch (e) {
      debugPrint('messaging: receive paused: $e');
    }
    if (!_running) return handled.length;
    for (final MapEntry(key: conversationId, value: ids) in delivered.entries) {
      await _queueReceipt(conversationId, ReceiptType.delivered, ids);
    }
    if (handled.isNotEmpty) {
      try {
        await _api.ackEnvelopes(handled);
      } on api.ApiError catch (e) {
        // They come back with the next fetch and are recognised as duplicates.
        debugPrint('messaging: ack failed: $e');
      }
    }
    return handled.length;
  }

  /// Decrypts and stores one envelope. Returns the id of a new message from someone else that
  /// still needs a `delivered` receipt. Throws only on transient errors (envelope not acked).
  Future<String?> _handle(api.Envelope e) async {
    final me = _me()!;
    if (_seen.contains(e.id)) return null;
    if (!await _ensureConversation(e.conversationId)) {
      _remember(e.id);
      return null;
    }
    await _db.addDevice(e.senderUserId, e.senderDeviceId);
    // A group member we have no name for yet.
    if (e.senderUserId != me.userId) unawaited(_fetchUsers([e.senderUserId]));

    final Payload? payload;
    try {
      payload = Payload.fromBytes(await _cipher.decrypt(e));
    } on DuplicateMessageException {
      _remember(e.id);
      return null;
    } catch (err) {
      debugPrint('messaging: could not decrypt ${e.id}: $err');
      await _db.insertMessage(MessagesCompanion.insert(
        id: 'undecryptable-${e.id}',
        conversationId: e.conversationId,
        senderUserId: e.senderUserId,
        senderDeviceId: e.senderDeviceId,
        kind: const Value(MessageKind.system),
        body: const Value("A message couldn't be decrypted."),
        sentAt: e.serverTimestamp,
        receivedAt: Value(_now()),
        status: MessageStatus.delivered,
      ));
      _remember(e.id);
      return null;
    }
    _remember(e.id);
    // The routing data is visible to the server; the payload must agree with it.
    if (payload == null || payload.conversationId != e.conversationId) return null;

    final fromMe = e.senderUserId == me.userId;
    switch (payload.kind) {
      case PayloadKind.text:
        return _storeText(e, payload, fromMe: fromMe);
      case PayloadKind.receipt:
        await _applyReceipt(e, payload, fromMe: fromMe);
        return null;
      case PayloadKind.groupUpdate:
        await _applyGroupUpdate(e, payload, fromMe: fromMe);
        return null;
    }
  }

  void _remember(String envelopeId) {
    _seen.add(envelopeId);
    if (_seen.length > _seenMax) _seen.remove(_seen.first);
  }

  Future<String?> _storeText(api.Envelope e, Payload p, {required bool fromMe}) async {
    final me = _me()!;
    if (await _db.messageById(p.messageId) != null) return null;
    await _db.transaction(() async {
      await _db.insertMessage(MessagesCompanion.insert(
        id: p.messageId,
        conversationId: p.conversationId,
        senderUserId: e.senderUserId,
        senderDeviceId: e.senderDeviceId,
        body: Value(p.body),
        sentAt: p.sentAt,
        receivedAt: Value(_now()),
        // A sync copy of our own message was sent; someone else's has reached us.
        status: fromMe ? MessageStatus.sent : MessageStatus.delivered,
      ));
      await _db.touchConversation(p.conversationId, p.sentAt);
      if (!fromMe) await _db.recountUnread(p.conversationId, me.userId);
    });
    if (fromMe) return null;
    if (_openConversation == p.conversationId) {
      // Read straight away; that receipt implies delivery.
      await _markRead(p.conversationId);
      return null;
    }
    return p.messageId;
  }

  Future<void> _applyReceipt(api.Envelope e, Payload p, {required bool fromMe}) async {
    final me = _me()!;
    final status =
        p.receiptType == ReceiptType.read ? MessageStatus.read : MessageStatus.delivered;
    final isGroup =
        (await _db.conversationById(p.conversationId))?.kind == ConversationKind.group;
    for (final id in p.receiptIds) {
      final m = await _db.messageById(id);
      if (m == null || m.conversationId != p.conversationId) continue;
      if (fromMe) {
        // Another of our devices read these: mark them read here too.
        if (status == MessageStatus.read && m.senderUserId != me.userId) {
          await _db.updateMessageStatus(id, MessageStatus.read);
        }
      } else if (m.senderUserId == me.userId) {
        // In a group, ticks move only once every member got there.
        if (isGroup) {
          await _db.applyReceipt(id, e.senderUserId, status, me.userId);
        } else {
          await _db.updateMessageStatus(id, status);
        }
      }
    }
    if (fromMe) await _db.recountUnread(p.conversationId, me.userId);
  }

  // ---------------------------------------------------------------------------
  // Reading
  // ---------------------------------------------------------------------------

  String? _openConversation;

  /// The conversation screen is visible: mark its messages read and keep doing so.
  Future<void> openConversation(String conversationId) async {
    _openConversation = conversationId;
    if (_running) await _markRead(conversationId);
  }

  /// The conversation screen was closed or the app went to the background.
  void closeConversation(String conversationId) {
    if (_openConversation == conversationId) _openConversation = null;
    _stopTyping(conversationId);
  }

  Future<void> _markRead(String conversationId) async {
    final me = _me();
    if (me == null) return;
    final ids = await _db.markIncomingRead(conversationId, me.userId);
    await _queueReceipt(conversationId, ReceiptType.read, ids);
  }

  // ---------------------------------------------------------------------------
  // Typing
  // ---------------------------------------------------------------------------

  /// conversationId → userId → timer that drops a `start` nobody refreshed.
  final _typing = <String, Map<String, Timer>>{};
  final _typingChanged = StreamController<String>.broadcast();

  /// Users typing in [conversationId] right now.
  Stream<Set<String>> typingUsers(String conversationId) {
    StreamSubscription<String>? sub;
    late final StreamController<Set<String>> out;
    out = StreamController<Set<String>>(
      onListen: () {
        out.add(_typingIn(conversationId));
        sub = _typingChanged.stream
            .where((c) => c == conversationId)
            .listen((_) => out.add(_typingIn(conversationId)));
      },
      onCancel: () => sub?.cancel(),
    );
    return out.stream;
  }

  Set<String> _typingIn(String conversationId) =>
      _typing[conversationId]?.keys.toSet() ?? const {};

  void _onTyping(api.TypingEvent e) {
    final users = _typing[e.conversationId] ??= {};
    users.remove(e.userId)?.cancel();
    if (e.state == api.TypingState.start) {
      users[e.userId] = Timer(typingIdle, () {
        users.remove(e.userId);
        _typingChanged.add(e.conversationId);
      });
    }
    _typingChanged.add(e.conversationId);
  }

  DateTime? _typingSentAt;
  String? _typingConversation;
  Timer? _typingIdleTimer;

  /// Call on every composer change: sends `start` at most every 3 s, `stop` after 5 s idle or
  /// when the text is cleared.
  void composerChanged(String conversationId, String text) {
    if (!_running) return;
    if (text.trim().isEmpty) {
      _stopTyping(conversationId);
      return;
    }
    if (_typingConversation != null && _typingConversation != conversationId) {
      _stopTyping(_typingConversation!);
    }
    final now = _now();
    final sent = _typingSentAt;
    if (sent == null || now.difference(sent) >= typingRefresh) {
      _socket.emitTyping(conversationId, api.TypingState.start);
      _typingSentAt = now;
      _typingConversation = conversationId;
    }
    _typingIdleTimer?.cancel();
    _typingIdleTimer = Timer(typingIdle, () => _stopTyping(conversationId));
  }

  void _stopTyping(String conversationId) {
    if (_typingConversation != conversationId) return;
    _typingIdleTimer?.cancel();
    _typingIdleTimer = null;
    _typingSentAt = null;
    _typingConversation = null;
    _socket.emitTyping(conversationId, api.TypingState.stop);
  }

  void dispose() {
    stop();
    _typingChanged.close();
  }
}

/// Started and stopped with the session by `sessionLifecycleProvider`.
final messagingServiceProvider = Provider<MessagingService>((ref) {
  final service = MessagingService(
    api: ref.watch(apiClientProvider),
    db: ref.watch(appDatabaseProvider),
    cipher: ref.watch(envelopeCipherProvider),
    socket: ref.watch(socketServiceProvider),
    me: () {
      final s = ref.read(sessionProvider);
      final userId = s.me?.id;
      final deviceId = s.deviceId;
      return userId == null || deviceId == null ? null : (userId: userId, deviceId: deviceId);
    },
  );
  ref.onDispose(service.dispose);
  return service;
});
