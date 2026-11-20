import 'package:drift/drift.dart';

part 'app_database.g.dart';

// ---------------------------------------------------------------------------
// Signal protocol state. Records are the library's own protobuf serialisation.
// ---------------------------------------------------------------------------

/// This device's identity. At most one row (id = 0).
class LocalIdentity extends Table {
  IntColumn get id => integer().withDefault(const Constant(0))();
  BlobColumn get keyPair => blob()();
  IntColumn get registrationId => integer()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Identity keys of other devices, trusted on first use.
class RemoteIdentities extends Table {
  TextColumn get name => text()();
  IntColumn get deviceId => integer()();
  BlobColumn get identityKey => blob()();

  @override
  Set<Column> get primaryKey => {name, deviceId};
}

class PreKeys extends Table {
  IntColumn get id => integer()();
  BlobColumn get record => blob()();

  @override
  Set<Column> get primaryKey => {id};
}

class SignedPreKeys extends Table {
  IntColumn get id => integer()();
  BlobColumn get record => blob()();

  @override
  Set<Column> get primaryKey => {id};
}

class Sessions extends Table {
  TextColumn get name => text()();
  IntColumn get deviceId => integer()();
  BlobColumn get record => blob()();

  @override
  Set<Column> get primaryKey => {name, deviceId};
}

/// Small settings such as the next prekey id.
class Kv extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

// ---------------------------------------------------------------------------
// Chats. Plaintext lives only here, inside the encrypted database.
// ---------------------------------------------------------------------------

enum ConversationKind { direct, group }

enum MessageStatus { pending, sent, delivered, read, failed }

enum MessageKind { text, system }

@DataClassName('LocalConversation')
class Conversations extends Table {
  TextColumn get id => text()();
  TextColumn get kind => textEnum<ConversationKind>()();

  /// Group name, learnt from encrypted `group_update` payloads.
  TextColumn get name => text().nullable()();

  /// `sentAt` of the `group_update` that set [name]; older updates are ignored.
  DateTimeColumn get nameUpdatedAt => dateTime().nullable()();

  /// False once this user left or was removed: the history stays, read-only.
  BoolColumn get active => boolean().withDefault(const Constant(true))();

  /// The other user of a direct chat.
  TextColumn get peerUserId => text().nullable()();
  DateTimeColumn get updatedAt => dateTime()();
  IntColumn get unreadCount => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

class Members extends Table {
  TextColumn get conversationId =>
      text().references(Conversations, #id, onDelete: KeyAction.cascade)();
  TextColumn get userId => text()();

  /// `admin` or `member`, as on the server.
  TextColumn get role => text().withDefault(const Constant('member'))();

  @override
  Set<Column> get primaryKey => {conversationId, userId};
}

@TableIndex(name: 'messages_by_conversation', columns: {#conversationId, #sentAt})
class Messages extends Table {
  /// Client-generated message id (UUID), the same on every device.
  TextColumn get id => text()();
  TextColumn get conversationId =>
      text().references(Conversations, #id, onDelete: KeyAction.cascade)();
  TextColumn get senderUserId => text()();
  TextColumn get senderDeviceId => text()();
  TextColumn get kind => textEnum<MessageKind>().withDefault(const Constant('text'))();
  TextColumn get body => text().nullable()();
  DateTimeColumn get sentAt => dateTime()();
  DateTimeColumn get receivedAt => dateTime().nullable()();
  TextColumn get status => textEnum<MessageStatus>()();

  @override
  Set<Column> get primaryKey => {id};
}

/// How far each recipient got with one of this user's group messages. The message's own
/// status is the lowest across the current members.
class Receipts extends Table {
  TextColumn get messageId =>
      text().references(Messages, #id, onDelete: KeyAction.cascade)();
  TextColumn get userId => text()();
  TextColumn get status => textEnum<MessageStatus>()();

  @override
  Set<Column> get primaryKey => {messageId, userId};
}

/// Plaintext payloads waiting to be encrypted and sent.
class Outbox extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get messageId => text()();
  TextColumn get conversationId => text()();

  /// JSON of the plaintext payload (`{v, kind, messageId, ...}`).
  TextColumn get payload => text()();
  IntColumn get attempts => integer().withDefault(const Constant(0))();
  DateTimeColumn get nextAttemptAt => dateTime()();
  DateTimeColumn get createdAt => dateTime()();
}

/// Devices of a user that this device fans messages out to. Corrected by the server's 409
/// `DEVICE_MISMATCH` answers; the Signal sessions table only knows device ids.
class KnownDevices extends Table {
  TextColumn get userId => text()();
  TextColumn get deviceId => text()();

  @override
  Set<Column> get primaryKey => {userId, deviceId};
}

/// Names and avatars for chat titles, from contacts, lookups and `profile:updated`.
class CachedUsers extends Table {
  TextColumn get id => text()();
  TextColumn get displayName => text().nullable()();
  TextColumn get phone => text().nullable()();
  TextColumn get avatarThumbUrl => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// One row of the chat list.
class ChatSummary {
  const ChatSummary({
    required this.conversation,
    this.lastMessage,
    this.peer,
    this.lastSender,
  });

  final LocalConversation conversation;
  final Message? lastMessage;

  /// The other user of a direct chat, when known.
  final CachedUser? peer;

  /// Who sent [lastMessage], when known (for "Alice: hi" in groups).
  final CachedUser? lastSender;
}

/// A conversation member with their cached profile, when known.
class MemberInfo {
  const MemberInfo({required this.member, this.user});

  final Member member;
  final CachedUser? user;

  bool get isAdmin => member.role == 'admin';
}

@DriftDatabase(tables: [
  LocalIdentity,
  RemoteIdentities,
  PreKeys,
  SignedPreKeys,
  Sessions,
  Kv,
  Conversations,
  Members,
  Messages,
  Outbox,
  KnownDevices,
  CachedUsers,
  Receipts,
])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  @override
  int get schemaVersion => 3;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            await m.createTable(knownDevices);
            await m.createTable(cachedUsers);
          }
          if (from < 3) {
            await m.addColumn(conversations, conversations.nameUpdatedAt);
            await m.addColumn(conversations, conversations.active);
            await m.createTable(receipts);
          }
        },
        beforeOpen: (details) async {
          await customStatement('PRAGMA foreign_keys = ON');
        },
      );

  // --- key/value ------------------------------------------------------------

  Future<String?> readKv(String key) async {
    final row = await (select(kv)..where((t) => t.key.equals(key))).getSingleOrNull();
    return row?.value;
  }

  Future<void> writeKv(String key, String value) =>
      into(kv).insertOnConflictUpdate(KvCompanion.insert(key: key, value: value));

  // --- chats ------------------------------------------------------------------

  Future<void> upsertConversation(ConversationsCompanion c) =>
      into(conversations).insertOnConflictUpdate(c);

  Future<void> setMembers(String conversationId, List<MembersCompanion> list) =>
      transaction(() async {
        await (delete(members)..where((t) => t.conversationId.equals(conversationId))).go();
        await batch((b) => b.insertAll(members, list));
      });

  Future<List<Member>> membersOf(String conversationId) =>
      (select(members)..where((t) => t.conversationId.equals(conversationId))).get();

  /// Members with their cached profiles; admins first, then by name.
  Stream<List<MemberInfo>> watchMembers(String conversationId) {
    final query = select(members).join([
      leftOuterJoin(cachedUsers, cachedUsers.id.equalsExp(members.userId)),
    ])
      ..where(members.conversationId.equals(conversationId));
    return query.watch().map((rows) {
      final list = [
        for (final r in rows)
          MemberInfo(member: r.readTable(members), user: r.readTableOrNull(cachedUsers)),
      ];
      String key(MemberInfo m) =>
          (m.user?.displayName ?? m.user?.phone ?? '￿').toLowerCase();
      list.sort((a, b) {
        if (a.isAdmin != b.isAdmin) return a.isAdmin ? -1 : 1;
        return key(a).compareTo(key(b));
      });
      return list;
    });
  }

  Future<List<LocalConversation>> allConversations() => select(conversations).get();

  /// Sets the group name when [at] is newer than the time the current name was set.
  /// Returns whether it changed.
  Future<bool> setConversationName(String id, String name, DateTime at) =>
      transaction(() async {
        final c = await conversationById(id);
        if (c == null) return false;
        final prev = c.nameUpdatedAt;
        if (prev != null && !at.isAfter(prev)) return false;
        await (update(conversations)..where((t) => t.id.equals(id))).write(
          ConversationsCompanion(name: Value(name), nameUpdatedAt: Value(at)),
        );
        return true;
      });

  Future<void> setActive(String id, {required bool active}) =>
      (update(conversations)..where((t) => t.id.equals(id)))
          .write(ConversationsCompanion(active: Value(active)));

  Future<void> insertMessage(MessagesCompanion m) =>
      into(messages).insert(m, mode: InsertMode.insertOrIgnore);

  SimpleSelectStatement<$MessagesTable, Message> _messagesIn(String conversationId) =>
      select(messages)
        ..where((t) => t.conversationId.equals(conversationId))
        // Times are stored in seconds; insertion order breaks ties.
        ..orderBy([
          (t) => OrderingTerm.asc(t.sentAt),
          (t) => OrderingTerm.asc(t.rowId),
        ]);

  Future<List<Message>> messagesIn(String conversationId) =>
      _messagesIn(conversationId).get();

  /// Oldest first.
  Stream<List<Message>> watchMessages(String conversationId) =>
      _messagesIn(conversationId).watch();

  Future<Message?> messageById(String id) =>
      (select(messages)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<LocalConversation?> conversationById(String id) =>
      (select(conversations)..where((t) => t.id.equals(id))).getSingleOrNull();

  Stream<LocalConversation?> watchConversation(String id) =>
      (select(conversations)..where((t) => t.id.equals(id))).watchSingleOrNull();

  Future<void> deleteConversation(String id) =>
      (delete(conversations)..where((t) => t.id.equals(id))).go();

  /// Moves the conversation to the top of the list.
  Future<void> touchConversation(String id, DateTime at) =>
      (update(conversations)..where((t) => t.id.equals(id)))
          .write(ConversationsCompanion(updatedAt: Value(at)));

  /// Sets the unread count to the number of other users' messages not yet read.
  Future<void> recountUnread(String id, String myUserId) => customUpdate(
        'UPDATE conversations SET unread_count = (SELECT count(*) FROM messages m '
        'WHERE m.conversation_id = ?1 AND m.sender_user_id != ?2 '
        "AND m.kind = 'text' AND m.status != 'read') WHERE id = ?1",
        variables: [Variable.withString(id), Variable.withString(myUserId)],
        updates: {conversations},
      );

  Future<void> resetUnread(String id) =>
      (update(conversations)..where((t) => t.id.equals(id)))
          .write(const ConversationsCompanion(unreadCount: Value(0)));

  /// Marks other users' unread messages in [conversationId] as read, clears the unread count
  /// and returns the ids that changed.
  Future<List<String>> markIncomingRead(String conversationId, String myUserId) =>
      transaction(() async {
        final rows = await (select(messages)
              ..where((t) =>
                  t.conversationId.equals(conversationId) &
                  t.senderUserId.equals(myUserId).not() &
                  t.kind.equalsValue(MessageKind.text) &
                  t.status.equalsValue(MessageStatus.read).not()))
            .get();
        final ids = [for (final r in rows) r.id];
        if (ids.isNotEmpty) {
          await (update(messages)..where((t) => t.id.isIn(ids)))
              .write(const MessagesCompanion(status: Value(MessageStatus.read)));
        }
        await recountUnread(conversationId, myUserId);
        return ids;
      });

  /// The chat list, most recent activity first.
  Stream<List<ChatSummary>> watchChatList() {
    final last = alias(messages, 'last_message');
    final sender = alias(cachedUsers, 'last_sender');
    final latestId = subqueryExpression<String>(
      selectOnly(messages)
        ..addColumns([messages.id])
        ..where(messages.conversationId.equalsExp(conversations.id))
        ..orderBy([
          OrderingTerm.desc(messages.sentAt),
          OrderingTerm.desc(messages.rowId),
        ])
        ..limit(1),
    );
    final query = select(conversations).join([
      leftOuterJoin(last, last.id.equalsExp(latestId)),
      leftOuterJoin(cachedUsers, cachedUsers.id.equalsExp(conversations.peerUserId)),
      leftOuterJoin(sender, sender.id.equalsExp(last.senderUserId)),
    ])
      ..orderBy([
        OrderingTerm.desc(coalesce<DateTime>([last.sentAt, conversations.updatedAt])),
      ]);
    return query.watch().map((rows) => [
          for (final r in rows)
            ChatSummary(
              conversation: r.readTable(conversations),
              lastMessage: r.readTableOrNull(last),
              peer: r.readTableOrNull(cachedUsers),
              lastSender: r.readTableOrNull(sender),
            ),
        ]);
  }

  // --- devices and users -------------------------------------------------------

  Future<List<String>> devicesOf(String userId) async => [
        for (final r
            in await (select(knownDevices)..where((t) => t.userId.equals(userId))).get())
          r.deviceId,
      ];

  Future<void> addDevice(String userId, String deviceId) => into(knownDevices).insert(
        KnownDevicesCompanion.insert(userId: userId, deviceId: deviceId),
        mode: InsertMode.insertOrIgnore,
      );

  Future<void> removeDevice(String userId, String deviceId) => (delete(knownDevices)
        ..where((t) => t.userId.equals(userId) & t.deviceId.equals(deviceId)))
      .go();

  // --- group receipts ---------------------------------------------------------

  Future<List<Receipt>> receiptsFor(String messageId) =>
      (select(receipts)..where((t) => t.messageId.equals(messageId))).get();

  /// Records that [userId] reached [status] for one of this user's group messages (forward
  /// only), then moves the message to the lowest status across the current members.
  Future<void> applyReceipt(
    String messageId,
    String userId,
    MessageStatus status,
    String myUserId,
  ) =>
      transaction(() async {
        final m = await messageById(messageId);
        if (m == null) return;
        final existing = await (select(receipts)
              ..where((t) => t.messageId.equals(messageId) & t.userId.equals(userId)))
            .getSingleOrNull();
        if (existing == null || status.index > existing.status.index) {
          await into(receipts).insertOnConflictUpdate(
            ReceiptsCompanion.insert(messageId: messageId, userId: userId, status: status),
          );
        }
        await _aggregate(m, myUserId);
      });

  /// Re-applies the aggregate to this user's sent or delivered messages in
  /// [conversationId], e.g. after a member who held them back left.
  Future<void> reaggregate(String conversationId, String myUserId) =>
      transaction(() async {
        final mine = await (select(messages)
              ..where((t) =>
                  t.conversationId.equals(conversationId) &
                  t.senderUserId.equals(myUserId) &
                  t.kind.equalsValue(MessageKind.text) &
                  t.status.isInValues([MessageStatus.sent, MessageStatus.delivered])))
            .get();
        for (final m in mine) {
          await _aggregate(m, myUserId);
        }
      });

  Future<void> _aggregate(Message m, String myUserId) async {
    final others = [
      for (final mem in await membersOf(m.conversationId))
        if (mem.userId != myUserId) mem.userId,
    ];
    if (others.isEmpty) return;
    final byUser = {for (final r in await receiptsFor(m.id)) r.userId: r.status};
    var lowest = MessageStatus.read;
    for (final u in others) {
      final st = byUser[u];
      if (st == null) return; // not everyone has it yet
      if (st.index < lowest.index) lowest = st;
    }
    await updateMessageStatus(m.id, lowest);
  }

  Future<void> cacheUser(CachedUsersCompanion u) => into(cachedUsers).insertOnConflictUpdate(u);

  Future<CachedUser?> cachedUser(String id) =>
      (select(cachedUsers)..where((t) => t.id.equals(id))).getSingleOrNull();

  Stream<CachedUser?> watchCachedUser(String id) =>
      (select(cachedUsers)..where((t) => t.id.equals(id))).watchSingleOrNull();

  /// Moves a message forward only (sent → delivered → read). `failed` can always be set,
  /// and a failed message can move to any state when it is retried.
  Future<void> updateMessageStatus(String id, MessageStatus status) async {
    final row =
        await (select(messages)..where((t) => t.id.equals(id))).getSingleOrNull();
    if (row == null) return;
    final forward = status == MessageStatus.failed ||
        row.status == MessageStatus.failed ||
        status.index > row.status.index;
    if (!forward) return;
    await (update(messages)..where((t) => t.id.equals(id)))
        .write(MessagesCompanion(status: Value(status)));
  }

  Future<int> enqueueOutbox(OutboxCompanion o) => into(outbox).insert(o);

  /// Items due at [now], oldest first.
  Future<List<OutboxData>> dueOutbox(DateTime now) => (select(outbox)
        ..where((t) => t.nextAttemptAt.isSmallerOrEqualValue(now))
        ..orderBy([(t) => OrderingTerm.asc(t.id)]))
      .get();

  Future<void> removeOutbox(int id) => (delete(outbox)..where((t) => t.id.equals(id))).go();

  Future<void> rescheduleOutbox(int id, {required int attempts, required DateTime next}) =>
      (update(outbox)..where((t) => t.id.equals(id))).write(
        OutboxCompanion(attempts: Value(attempts), nextAttemptAt: Value(next)),
      );

  /// Makes every waiting item due now (the connection is back).
  Future<void> outboxDueNow(DateTime now) =>
      update(outbox).write(OutboxCompanion(nextAttemptAt: Value(now)));

  /// When the next outbox item becomes due, or null when the outbox is empty.
  Future<DateTime?> nextOutboxDue() async {
    final row = await (select(outbox)
          ..orderBy([(t) => OrderingTerm.asc(t.nextAttemptAt)])
          ..limit(1))
        .getSingleOrNull();
    return row?.nextAttemptAt;
  }
}
