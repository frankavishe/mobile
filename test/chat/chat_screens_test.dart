import 'package:chat_app/app.dart';
import 'package:chat_app/core/api/api_client.dart';
import 'package:chat_app/core/api/models/models.dart';
import 'package:chat_app/core/auth/session.dart';
import 'package:chat_app/core/db/app_database.dart';
import 'package:chat_app/core/db/db_opener.dart';
import 'package:chat_app/core/realtime/socket_service.dart';
import 'package:chat_app/core/storage/secure_store.dart';
import 'package:chat_app/features/chat/conversation_screen.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fakes.dart';

const _me = Me(
  id: 'me',
  phone: '+255712345678',
  displayName: 'Frank',
  about: '',
  avatarUrl: null,
  profileComplete: true,
);

void main() {
  late ProviderContainer container;
  late FakeMessagingService messaging;
  late AppDatabase db;
  final now = DateTime.now();

  Future<void> start(WidgetTester tester, {Future<void> Function()? seed}) async {
    messaging = FakeMessagingService();
    container = ProviderContainer(overrides: [
      apiClientProvider.overrideWithValue(MockApiClient()),
      socketServiceProvider.overrideWithValue(FakeSocketService()),
      secureStoreProvider.overrideWithValue(MemorySecureStore()),
      ...localDataOverrides(messaging: messaging),
    ]);
    addTearDown(container.dispose);
    db = container.read(appDatabaseProvider);
    await seed?.call();
    container.read(sessionProvider.notifier).setSession(accessToken: 'a', me: _me, deviceId: 'd1');
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const ChatApp()));
    await tester.pumpAndSettle();
  }

  Future<void> chat(String id, String peer, {int unread = 0}) => db.upsertConversation(
        ConversationsCompanion.insert(
          id: id,
          kind: ConversationKind.direct,
          peerUserId: Value(peer),
          updatedAt: now.subtract(const Duration(days: 30)),
          unreadCount: Value(unread),
        ),
      );

  Future<void> message(
    String id,
    String conversationId,
    String sender,
    String body,
    DateTime at, {
    MessageStatus status = MessageStatus.sent,
    MessageKind kind = MessageKind.text,
  }) =>
      db.insertMessage(MessagesCompanion.insert(
        id: id,
        conversationId: conversationId,
        senderUserId: sender,
        senderDeviceId: 'x',
        kind: Value(kind),
        body: Value(body),
        sentAt: at,
        status: status,
      ));

  Future<void> user(String id, String name) => db.cacheUser(
        CachedUsersCompanion.insert(id: id, displayName: Value(name), phone: const Value('+255713456789')),
      );

  testWidgets('no conversations shows the empty state', (tester) async {
    await start(tester);
    expect(find.text('No conversations yet'), findsOneWidget);
    expect(find.byKey(const Key('chat-list')), findsNothing);
  });

  testWidgets('chat list: newest first, last message, own ticks and unread badge',
      (tester) async {
    await start(tester, seed: () async {
      await user('amina', 'Amina');
      await chat('c1', 'amina', unread: 2);
      await message('m1', 'c1', 'amina', 'see you soon', now.subtract(const Duration(hours: 2)));
      await chat('c2', 'stranger');
      await message('m2', 'c2', 'me', 'who is this?', now.subtract(const Duration(minutes: 5)),
          status: MessageStatus.read);
    });

    final tiles = tester.widgetList<ListTile>(find.byType(ListTile)).toList();
    expect(tiles.map((t) => t.key), [const ValueKey('chat-c2'), const ValueKey('chat-c1')]);

    expect(find.text('Amina'), findsOneWidget);
    expect(find.text('see you soon'), findsOneWidget);
    expect(find.byKey(const ValueKey('unread-c1')), findsOneWidget);
    expect(find.text('2'), findsOneWidget);

    // A peer we know nothing about.
    expect(find.text('Unknown'), findsOneWidget);
    expect(find.byKey(const ValueKey('unread-c2')), findsNothing);
    expect(
      find.descendant(of: find.byKey(const ValueKey('chat-c2')), matching: find.byKey(const Key('tick-read'))),
      findsOneWidget,
    );
  });

  testWidgets('conversation: bubbles with ticks per status, typing, send and retry',
      (tester) async {
    await start(tester, seed: () async {
      await user('amina', 'Amina');
      await chat('c1', 'amina');
      final t = now.subtract(const Duration(minutes: 10));
      await message('in1', 'c1', 'amina', 'hello', t, status: MessageStatus.delivered);
      await message('p', 'c1', 'me', 'pending one', t.add(const Duration(minutes: 1)),
          status: MessageStatus.pending);
      await message('s', 'c1', 'me', 'sent one', t.add(const Duration(minutes: 2)));
      await message('d', 'c1', 'me', 'delivered one', t.add(const Duration(minutes: 3)),
          status: MessageStatus.delivered);
      await message('r', 'c1', 'me', 'read one', t.add(const Duration(minutes: 4)),
          status: MessageStatus.read);
      await message('f', 'c1', 'me', 'failed one', t.add(const Duration(minutes: 5)),
          status: MessageStatus.failed);
      await message('sys', 'c1', 'amina', "A message couldn't be decrypted.",
          t.add(const Duration(minutes: 6)),
          kind: MessageKind.system);
    });

    await tester.tap(find.byKey(const ValueKey('chat-c1')));
    await tester.pumpAndSettle();
    expect(find.byType(ConversationScreen), findsOneWidget);
    expect(messaging.opened, ['c1']);

    Finder inBubble(String id, Finder f) =>
        find.descendant(of: find.byKey(ValueKey('msg-$id')), matching: f);
    expect(inBubble('in1', find.text('hello')), findsOneWidget);
    expect(inBubble('in1', find.byType(Icon)), findsNothing, reason: 'no ticks on incoming');
    expect(inBubble('p', find.byKey(const Key('tick-pending'))), findsOneWidget);
    expect(inBubble('s', find.byKey(const Key('tick-sent'))), findsOneWidget);
    expect(inBubble('d', find.byKey(const Key('tick-delivered'))), findsOneWidget);
    expect(inBubble('r', find.byKey(const Key('tick-read'))), findsOneWidget);
    expect(inBubble('f', find.byKey(const Key('tick-failed'))), findsOneWidget);
    expect(find.text("A message couldn't be decrypted."), findsOneWidget);
    expect(find.text('Today'), findsOneWidget);

    // Typing indicator follows the service.
    expect(find.byKey(const Key('typing')), findsNothing);
    messaging.typing.add({'amina'});
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('typing')), findsOneWidget);
    messaging.typing.add({});
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('typing')), findsNothing);

    // Send is disabled until there is text; sending clears the composer.
    IconButton send() => tester.widget<IconButton>(find.byKey(const Key('send')));
    expect(send().onPressed, isNull);
    await tester.enterText(find.byKey(const Key('composer')), '  hi there  ');
    await tester.pump();
    await tester.tap(find.byKey(const Key('send')));
    await tester.pump();
    expect(messaging.sentTexts, [('c1', 'hi there')]);
    expect(tester.widget<TextField>(find.byKey(const Key('composer'))).controller!.text, isEmpty);

    // A failed message can be retried.
    await tester.tap(find.byKey(const Key('retry-f')));
    expect(messaging.retried, ['f']);

    // Leaving marks the conversation closed.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(messaging.closed, contains('c1'));
  });
}
