import 'dart:io';

import 'package:chat_app/core/db/app_database.dart';
import 'package:chat_app/core/db/db_opener.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AppDatabase', () {
    late AppDatabase db;
    final t0 = DateTime.utc(2026, 11, 19, 10);

    setUp(() => db = AppDatabase(NativeDatabase.memory()));
    tearDown(() => db.close());

    Future<void> seedConversation() => db.upsertConversation(ConversationsCompanion.insert(
          id: 'c1',
          kind: ConversationKind.direct,
          peerUserId: const Value('u2'),
          updatedAt: t0,
        ));

    MessagesCompanion msg(String id, DateTime at, {MessageStatus status = MessageStatus.pending}) =>
        MessagesCompanion.insert(
          id: id,
          conversationId: 'c1',
          senderUserId: 'u1',
          senderDeviceId: 'd1',
          body: Value('hello $id'),
          sentAt: at,
          status: status,
        );

    test('stores conversations and replaces members', () async {
      await seedConversation();
      await db.setMembers('c1', [
        MembersCompanion.insert(conversationId: 'c1', userId: 'u1', role: const Value('admin')),
        MembersCompanion.insert(conversationId: 'c1', userId: 'u2'),
      ]);
      await db.setMembers('c1', [MembersCompanion.insert(conversationId: 'c1', userId: 'u3')]);

      final members = await db.membersOf('c1');
      expect(members.map((m) => m.userId), ['u3']);
      expect(members.single.role, 'member');
    });

    test('lists messages by time and ignores duplicate ids', () async {
      await seedConversation();
      await db.insertMessage(msg('m2', t0.add(const Duration(minutes: 1))));
      await db.insertMessage(msg('m1', t0));
      await db.insertMessage(msg('m1', t0.add(const Duration(hours: 1))));

      final list = await db.messagesIn('c1');
      expect(list.map((m) => m.id), ['m1', 'm2']);
      expect(list.first.sentAt.toUtc(), t0);
      expect(list.first.body, 'hello m1');
    });

    test('message status only moves forward, except failed', () async {
      await seedConversation();
      await db.insertMessage(msg('m1', t0));
      Future<MessageStatus> status() async => (await db.messagesIn('c1')).single.status;

      await db.updateMessageStatus('m1', MessageStatus.read);
      await db.updateMessageStatus('m1', MessageStatus.delivered);
      expect(await status(), MessageStatus.read);

      await db.updateMessageStatus('m1', MessageStatus.failed);
      expect(await status(), MessageStatus.failed);
      await db.updateMessageStatus('m1', MessageStatus.sent);
      expect(await status(), MessageStatus.sent);
    });

    test('deleting a conversation removes its members and messages', () async {
      await seedConversation();
      await db.setMembers('c1', [MembersCompanion.insert(conversationId: 'c1', userId: 'u1')]);
      await db.insertMessage(msg('m1', t0));

      await (db.delete(db.conversations)..where((t) => t.id.equals('c1'))).go();

      expect(await db.membersOf('c1'), isEmpty);
      expect(await db.messagesIn('c1'), isEmpty);
    });

    test('outbox returns due items oldest first', () async {
      OutboxCompanion item(String id, DateTime due) => OutboxCompanion.insert(
            messageId: id,
            conversationId: 'c1',
            payload: '{}',
            nextAttemptAt: due,
            createdAt: t0,
          );
      await db.enqueueOutbox(item('a', t0));
      await db.enqueueOutbox(item('later', t0.add(const Duration(minutes: 5))));
      final third = await db.enqueueOutbox(item('b', t0));

      expect((await db.dueOutbox(t0)).map((o) => o.messageId), ['a', 'b']);
      await db.removeOutbox(third);
      expect((await db.dueOutbox(t0.add(const Duration(hours: 1)))).map((o) => o.messageId),
          ['a', 'later']);
    });

    test('key/value settings round-trip', () async {
      expect(await db.readKv('x'), isNull);
      await db.writeKv('x', '1');
      await db.writeKv('x', '2');
      expect(await db.readKv('x'), '2');
    });
  });

  group('encrypted file', () {
    late Directory dir;

    setUp(() async => dir = await Directory.systemTemp.createTemp('chat_db_test'));
    tearDown(() => dir.delete(recursive: true));

    test('is unreadable without the key and readable with it', () async {
      final file = File('${dir.path}/chat.db');
      final key = generateDbKey();

      final db = AppDatabase(openEncryptedFile(file, key));
      await db.writeKv('secret', 'plaintext-marker');
      await db.close();

      final raw = await file.readAsBytes();
      expect(String.fromCharCodes(raw).contains('plaintext-marker'), isFalse);
      expect(String.fromCharCodes(raw.take(15)), isNot('SQLite format 3'));

      final wrong = AppDatabase(openEncryptedFile(file, generateDbKey()));
      await expectLater(wrong.readKv('secret'), throwsA(anything));
      await wrong.close();

      final again = AppDatabase(openEncryptedFile(file, key));
      expect(await again.readKv('secret'), 'plaintext-marker');
      await again.close();

      await deleteDatabaseFiles(file);
      expect(await file.exists(), isFalse);
    });

    test('rejects malformed keys', () {
      expect(() => openEncryptedFile(File('${dir.path}/x.db'), 'not-hex'), throwsArgumentError);
    });
  });
}
