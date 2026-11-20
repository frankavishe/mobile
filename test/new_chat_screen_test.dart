import 'package:chat_app/app.dart';
import 'package:chat_app/core/api/api_client.dart';
import 'package:chat_app/core/api/models/models.dart';
import 'package:chat_app/core/auth/session.dart';
import 'package:chat_app/core/realtime/socket_service.dart';
import 'package:chat_app/core/storage/secure_store.dart';
import 'package:chat_app/features/chat/conversation_screen.dart';
import 'package:chat_app/features/contacts/contacts_repository.dart';
import 'package:chat_app/features/contacts/new_chat_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'support/fakes.dart';

const _me = Me(
  id: 'u1',
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
  about: 'At the beach',
  avatarUrl: null,
);

void main() {
  late MockApiClient api;
  late FakeAddressBook book;
  late ProviderContainer container;
  late FakeMessagingService messaging;

  setUpAll(() => registerFallbackValue(<String>[]));

  setUp(() {
    api = MockApiClient();
    messaging = FakeMessagingService();
    book = FakeAddressBook(numbers: ['0713 456 789']);
    when(() => api.listContacts()).thenAnswer((_) async => []);
    when(() => api.discoverContacts(any())).thenAnswer((_) async => [_amina]);
  });

  Future<void> open(WidgetTester tester, {MemorySecureStore? store}) async {
    container = ProviderContainer(overrides: [
      apiClientProvider.overrideWithValue(api),
      socketServiceProvider.overrideWithValue(FakeSocketService()),
      ...localDataOverrides(messaging: messaging),
      secureStoreProvider.overrideWithValue(store ?? MemorySecureStore()),
      addressBookProvider.overrideWithValue(book),
    ]);
    addTearDown(container.dispose);
    container.read(sessionProvider.notifier).setSession(accessToken: 'a', me: _me);
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const ChatApp()),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('new-chat')));
    await tester.pumpAndSettle();
    expect(find.byType(NewChatScreen), findsOneWidget);
  }

  Future<void> search(WidgetTester tester, String number) async {
    await tester.enterText(find.byKey(const Key('lookup-number')), number);
    await tester.tap(find.byKey(const Key('lookup-search')));
    await tester.pumpAndSettle();
  }

  testWidgets('Allow access finds contacts and shows them with their about line',
      (tester) async {
    when(() => api.listContacts()).thenAnswer((_) async => []);
    await open(tester);
    expect(find.byKey(const Key('contacts-allow-card')), findsOneWidget);
    expect(book.reads, 0, reason: 'nothing is read before the user allows it');

    when(() => api.listContacts()).thenAnswer((_) async => [_amina]);
    await tester.tap(find.byKey(const Key('allow-contacts')));
    await tester.pumpAndSettle();

    verify(() => api.discoverContacts(['+255713456789'])).called(1);
    expect(find.byKey(const Key('contacts-allow-card')), findsNothing);
    expect(find.text('Amina'), findsOneWidget);
    expect(find.text('At the beach'), findsOneWidget);
  });

  testWidgets('granted with no matches says so', (tester) async {
    book.current = ContactsAccess.granted;
    await open(tester);

    expect(find.byKey(const Key('contacts-empty')), findsOneWidget);
  });

  testWidgets('with access denied, a number can still be looked up', (tester) async {
    book
      ..current = ContactsAccess.denied
      ..onRequest = ContactsAccess.denied;
    when(() => api.lookupUser(any())).thenAnswer((_) async => _amina);
    await open(tester);

    expect(find.byKey(const Key('contacts-allow-card')), findsOneWidget);
    await search(tester, '713 456 789');

    verify(() => api.lookupUser('+255713456789')).called(1);
    expect(find.byKey(const Key('lookup-result')), findsOneWidget);
    expect(find.text('Amina'), findsOneWidget);
  });

  testWidgets('a number without an account is reported', (tester) async {
    when(() => api.lookupUser(any())).thenThrow(const ApiError(
      status: 404,
      code: ApiErrorCode.userNotFound,
      message: 'USER_NOT_FOUND',
    ));
    await open(tester);

    await search(tester, '0715 111 222');

    expect(find.text("+255 715 111 222 isn't on Chat App yet."), findsOneWidget);
  });

  testWidgets('empty, invalid and own numbers are caught before the request',
      (tester) async {
    await open(tester);

    await search(tester, '');
    expect(find.text('Enter a phone number.'), findsOneWidget);

    await search(tester, '12345');
    expect(find.text("That number isn't valid for this country."), findsOneWidget);

    await search(tester, '0712 345 678');
    expect(find.text("That's your own number."), findsOneWidget);

    verifyNever(() => api.lookupUser(any()));
  });

  testWidgets('blocked access offers system settings', (tester) async {
    book.current = ContactsAccess.blocked;
    await open(tester);

    expect(find.byKey(const Key('contacts-allow-card')), findsNothing);
    await tester.tap(find.byKey(const Key('open-settings')));
    await tester.pumpAndSettle();

    expect(book.settingsOpened, 1);
  });

  testWidgets('tapping a contact opens the direct chat in place of this screen',
      (tester) async {
    when(() => api.listContacts()).thenAnswer((_) async => [_amina]);
    await open(tester);

    await tester.tap(find.byKey(const ValueKey('contact-u2')));
    await tester.pumpAndSettle();

    expect(messaging.startedWith.map((u) => u.id), ['u2']);
    final screen = tester.widget<ConversationScreen>(find.byType(ConversationScreen));
    expect(screen.conversationId, 'c-new');
    expect(find.byType(NewChatScreen), findsNothing);
    expect(messaging.opened, ['c-new']);
  });

  testWidgets('a looked-up number opens the chat too', (tester) async {
    when(() => api.lookupUser(any())).thenAnswer((_) async => _amina);
    await open(tester);
    await search(tester, '713 456 789');

    await tester.tap(find.byKey(const Key('lookup-result')));
    await tester.pumpAndSettle();

    expect(find.byType(ConversationScreen), findsOneWidget);
  });

  testWidgets('opening the app with access checks the address book once', (tester) async {
    book.current = ContactsAccess.granted;
    await open(tester);

    expect(book.reads, 1);
    verify(() => api.discoverContacts(['+255713456789'])).called(1);
  });

  testWidgets('opening New chat finds contacts who joined since the last check',
      (tester) async {
    book.current = ContactsAccess.granted;
    // Checked 5 minutes ago: the hourly app-open check skips, New chat does not.
    final store = MemorySecureStore()
      ..contactsSyncedAt = DateTime.now().subtract(const Duration(minutes: 5));
    when(() => api.listContacts()).thenAnswer((_) async => [_amina]);
    await open(tester, store: store);

    expect(book.reads, 1);
    verify(() => api.discoverContacts(['+255713456789'])).called(1);
    expect(find.text('Amina'), findsOneWidget);
  });
}
