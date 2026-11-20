import 'dart:async';

import 'package:chat_app/app.dart';
import 'package:chat_app/core/api/api_client.dart';
import 'package:chat_app/core/api/models/models.dart';
import 'package:chat_app/core/auth/session.dart';
import 'package:chat_app/core/db/app_database.dart';
import 'package:chat_app/core/db/db_opener.dart';
import 'package:chat_app/core/realtime/socket_service.dart';
import 'package:chat_app/core/storage/secure_store.dart';
import 'package:chat_app/features/chat/conversation_screen.dart';
import 'package:chat_app/features/chat/group_info_screen.dart';
import 'package:chat_app/features/chat/new_group_screen.dart';
import 'package:chat_app/features/contacts/contacts_repository.dart';
import 'package:chat_app/router.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../support/fakes.dart';

const _me = Me(
  id: 'me',
  phone: '+255712345678',
  displayName: 'Frank',
  about: '',
  avatarUrl: null,
  profileComplete: true,
);

const _amina = PublicUser(
  id: 'u2',
  phone: '+255713456789',
  displayName: 'Amina',
  about: '',
  avatarUrl: null,
);

const _baraka = PublicUser(
  id: 'u3',
  phone: '+255714567890',
  displayName: 'Baraka',
  about: '',
  avatarUrl: null,
);

void main() {
  late MockApiClient api;
  late ProviderContainer container;
  late FakeMessagingService messaging;
  late AppDatabase db;
  final now = DateTime.now();

  setUpAll(() => registerFallbackValue(<String>[]));

  Future<void> start(WidgetTester tester, {Future<void> Function()? seed}) async {
    api = MockApiClient();
    when(() => api.listContacts()).thenAnswer((_) async => [_amina, _baraka]);
    when(() => api.discoverContacts(any())).thenAnswer((_) async => []);
    messaging = FakeMessagingService();
    container = ProviderContainer(overrides: [
      apiClientProvider.overrideWithValue(api),
      socketServiceProvider.overrideWithValue(FakeSocketService()),
      secureStoreProvider.overrideWithValue(MemorySecureStore()),
      addressBookProvider.overrideWithValue(FakeAddressBook(current: ContactsAccess.granted)),
      ...localDataOverrides(messaging: messaging),
    ]);
    addTearDown(container.dispose);
    db = container.read(appDatabaseProvider);
    await seed?.call();
    container.read(sessionProvider.notifier).setSession(accessToken: 'a', me: _me, deviceId: 'd1');
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const ChatApp()));
    await tester.pumpAndSettle();
  }

  Future<void> go(WidgetTester tester, String location) async {
    unawaited(container.read(routerProvider).push(location));
    await tester.pumpAndSettle();
  }

  /// "Trip" with me, Amina and Baraka; [admin] says whether I am its admin.
  Future<void> seedGroup({bool admin = true, bool active = true}) async {
    await db.upsertConversation(ConversationsCompanion.insert(
      id: 'g1',
      kind: ConversationKind.group,
      name: const Value('Trip'),
      updatedAt: now.subtract(const Duration(minutes: 5)),
      active: Value(active),
    ));
    await db.setMembers('g1', [
      MembersCompanion.insert(
          conversationId: 'g1', userId: 'me', role: Value(admin ? 'admin' : 'member')),
      MembersCompanion.insert(
          conversationId: 'g1', userId: 'u2', role: Value(admin ? 'member' : 'admin')),
      MembersCompanion.insert(conversationId: 'g1', userId: 'u3'),
    ]);
    for (final u in [_amina, _baraka]) {
      await db.cacheUser(CachedUsersCompanion.insert(
        id: u.id,
        displayName: Value(u.displayName),
        phone: Value(u.phone),
      ));
    }
  }

  Future<void> message(String id, String sender, String body, int minute) =>
      db.insertMessage(MessagesCompanion.insert(
        id: id,
        conversationId: 'g1',
        senderUserId: sender,
        senderDeviceId: 'x',
        body: Value(body),
        sentAt: DateTime(now.year, now.month, now.day, 0, minute),
        status: MessageStatus.delivered,
      ));

  testWidgets('New group: pick contacts, name it, open the new chat', (tester) async {
    await start(tester);
    await tester.tap(find.byKey(const Key('new-chat')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('new-group')));
    await tester.pumpAndSettle();
    expect(find.byType(NewGroupScreen), findsOneWidget);
    expect(find.byKey(const Key('group-next')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('pick-u2')));
    await tester.tap(find.byKey(const ValueKey('pick-u3')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('picked-u2')), findsOneWidget);
    expect(find.text('2 of 63 selected'), findsOneWidget);

    await tester.tap(find.byKey(const Key('group-next')));
    await tester.pumpAndSettle();
    final create = find.byKey(const Key('create-group'));
    expect(tester.widget<FloatingActionButton>(create).onPressed, isNull);

    await tester.enterText(find.byKey(const Key('group-name')), '  Trip  ');
    await tester.pump();
    await tester.tap(create);
    await tester.pumpAndSettle();

    expect(messaging.createdGroups.single.$1, 'Trip');
    expect(messaging.createdGroups.single.$2, ['u2', 'u3']);
    final screen = tester.widget<ConversationScreen>(find.byType(ConversationScreen));
    expect(screen.conversationId, 'g-new');
    expect(find.byType(NewGroupScreen), findsNothing);
  });

  testWidgets('group conversation: sender names, typing names, header opens info',
      (tester) async {
    await start(tester, seed: () async {
      await seedGroup();
      await message('m1', 'u2', 'hi all', 1);
      await message('m2', 'u2', 'anyone?', 2);
      await message('m3', 'u3', 'here', 3);
      await message('m4', 'me', 'me too', 4);
    });
    await go(tester, Routes.chatOf('g1'));

    // A name above the first of each run of bubbles from someone else.
    expect(find.byKey(const Key('sender-u2')), findsOneWidget);
    expect(find.byKey(const Key('sender-u3')), findsOneWidget);
    expect(find.byKey(const Key('sender-me')), findsNothing);
    expect(find.text('Amina'), findsOneWidget);

    messaging.typing.add({'u3'});
    await tester.pumpAndSettle();
    expect(find.text('Baraka is typing…'), findsOneWidget);
    messaging.typing.add({'u2', 'u3'});
    await tester.pumpAndSettle();
    expect(find.text('2 people are typing…'), findsOneWidget);

    await tester.tap(find.byKey(const Key('conversation-header')));
    await tester.pumpAndSettle();
    expect(find.byType(GroupInfoScreen), findsOneWidget);
  });

  testWidgets('a group I left is read-only', (tester) async {
    await start(tester, seed: () => seedGroup(active: false));
    await go(tester, Routes.chatOf('g1'));
    expect(find.byKey(const Key('not-a-member')), findsOneWidget);
    expect(find.byKey(const Key('composer')), findsNothing);
  });

  testWidgets('group info as admin: rename, add, remove; members admin first', (tester) async {
    await start(tester, seed: seedGroup);
    await go(tester, Routes.groupInfoOf('g1'));

    expect(find.text('Trip'), findsOneWidget);
    expect(find.text('Group · 3 members'), findsOneWidget);
    expect(find.text('You'), findsOneWidget);
    expect(find.byKey(const Key('admin-badge')), findsOneWidget);
    expect(find.byKey(const Key('add-members-tile')), findsOneWidget);
    final order = tester
        .widgetList<Widget>(find.byWidgetPredicate(
            (w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('member-')))
        .map((w) => (w.key! as ValueKey<String>).value)
        .toList();
    expect(order, ['member-me', 'member-u2', 'member-u3']);

    await tester.tap(find.byKey(const Key('rename')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('rename-field')), 'Trip 2026');
    await tester.tap(find.byKey(const Key('rename-save')));
    await tester.pumpAndSettle();
    expect(messaging.renamed, [('g1', 'Trip 2026')]);

    await tester.longPress(find.byKey(const ValueKey('member-u3')));
    await tester.pumpAndSettle();
    expect(find.text('Remove Baraka?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('confirm')));
    await tester.pumpAndSettle();
    expect(messaging.removed, [('g1', 'u3')]);

    await tester.tap(find.byKey(const Key('add-members-tile')));
    await tester.pumpAndSettle();
    expect(find.byType(AddMembersScreen), findsOneWidget);
    // Everyone in my contacts is already in the group.
    expect(find.byKey(const Key('picker-empty')), findsOneWidget);
  });

  testWidgets('group info as a member: no admin actions; leave asks first', (tester) async {
    await start(tester, seed: () => seedGroup(admin: false));
    await go(tester, Routes.groupInfoOf('g1'));

    expect(find.byKey(const Key('rename')), findsNothing);
    expect(find.byKey(const Key('add-members-tile')), findsNothing);
    await tester.longPress(find.byKey(const ValueKey('member-u3')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);

    await tester.tap(find.byKey(const Key('leave-group')));
    await tester.pumpAndSettle();
    expect(find.text('Leave this group?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('confirm')));
    await tester.pumpAndSettle();
    expect(messaging.left, ['g1']);
  });

  testWidgets('after leaving, the chat can be deleted from this device', (tester) async {
    await start(tester, seed: () => seedGroup(active: false));
    await go(tester, Routes.groupInfoOf('g1'));

    expect(find.byKey(const Key('leave-group')), findsNothing);
    await tester.tap(find.byKey(const Key('delete-chat')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm')));
    await tester.pumpAndSettle();
    expect(messaging.deleted, ['g1']);
    expect(find.byType(GroupInfoScreen), findsNothing);
  });

  testWidgets('chat list: group icon and "Name: text" preview', (tester) async {
    await start(tester, seed: () async {
      await seedGroup();
      await message('m1', 'u2', 'hi all', 1);
    });
    expect(find.text('Trip'), findsOneWidget);
    expect(find.text('Amina: hi all'), findsOneWidget);
    expect(find.byIcon(Icons.group), findsOneWidget);
  });
}
