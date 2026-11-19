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

class Conversations extends Table {
  TextColumn get id => text()();
  TextColumn get kind => textEnum<ConversationKind>()();

  /// Group name, learnt from encrypted `group_update` payloads.
  TextColumn get name => text().nullable()();

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
])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
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

  // --- chats (minimal; repositories come with messaging) ---------------------

  Future<void> upsertConversation(ConversationsCompanion c) =>
      into(conversations).insertOnConflictUpdate(c);

  Future<void> setMembers(String conversationId, List<MembersCompanion> list) =>
      transaction(() async {
        await (delete(members)..where((t) => t.conversationId.equals(conversationId))).go();
        await batch((b) => b.insertAll(members, list));
      });

  Future<List<Member>> membersOf(String conversationId) =>
      (select(members)..where((t) => t.conversationId.equals(conversationId))).get();

  Future<void> insertMessage(MessagesCompanion m) =>
      into(messages).insert(m, mode: InsertMode.insertOrIgnore);

  Future<List<Message>> messagesIn(String conversationId) => (select(messages)
        ..where((t) => t.conversationId.equals(conversationId))
        ..orderBy([(t) => OrderingTerm.asc(t.sentAt)]))
      .get();

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
}
