import 'package:chat_app/core/api/api_client.dart';
import 'package:chat_app/core/api/models/models.dart';
import 'package:chat_app/core/auth/session.dart';
import 'package:chat_app/core/storage/secure_store.dart';
import 'package:chat_app/features/contacts/contacts_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:phone_numbers_parser/phone_numbers_parser.dart';

import 'support/fakes.dart';

const _own = '+255712345678';

const _me = Me(
  id: 'u1',
  phone: _own,
  displayName: 'Frank',
  about: '',
  avatarUrl: null,
  profileComplete: true,
);

const _amina = PublicUser(
  id: 'u2',
  phone: '+255713456789',
  displayName: 'Amina',
  about: 'Hello',
  avatarUrl: null,
);

const _baraka = PublicUser(
  id: 'u3',
  phone: '+255714000001',
  displayName: 'baraka',
  about: '',
  avatarUrl: null,
);

void main() {
  setUpAll(() => registerFallbackValue(<String>[]));

  group('normalizeNumbers', () {
    test('reads local numbers in the home country and keeps international ones', () {
      expect(
        normalizeNumbers(
          ['0713 456 789', '+254 712 345 678', '(0714) 000-001'],
          home: IsoCode.TZ,
        ),
        unorderedEquals(['+255713456789', '+254712345678', '+255714000001']),
      );
    });

    test('drops duplicates, invalid numbers, short codes and the own number', () {
      expect(
        normalizeNumbers(
          [
            '+254712345678',
            '00254712345678',
            '0712 345 678', // own number, local form
            '123',
            '*100#',
            'not a number',
            '0713456789',
            '+255 713 456 789',
          ],
          home: IsoCode.TZ,
          exclude: _own,
        ),
        unorderedEquals(['+254712345678', '+255713456789']),
      );
    });
  });

  group('ContactsRepository', () {
    late MockApiClient api;
    late FakeAddressBook book;
    late MemorySecureStore store;
    late ProviderContainer container;

    ContactsRepository repo() => container.read(contactsProvider.notifier);
    ContactsState state() => container.read(contactsProvider);

    setUp(() {
      api = MockApiClient();
      book = FakeAddressBook(
        current: ContactsAccess.granted,
        numbers: ['0713 456 789', '0714 000 001', '0799 999 999'],
      );
      store = MemorySecureStore();
      when(() => api.discoverContacts(any())).thenAnswer((_) async => [_amina]);
      when(() => api.listContacts()).thenAnswer((_) async => [_baraka, _amina]);
      container = ProviderContainer(overrides: [
        apiClientProvider.overrideWithValue(api),
        addressBookProvider.overrideWithValue(book),
        secureStoreProvider.overrideWithValue(store),
      ]);
      addTearDown(container.dispose);
      container.read(sessionProvider.notifier).setSession(accessToken: 'a', me: _me);
    });

    test('without permission the address book is not read', () async {
      book.current = ContactsAccess.denied;
      await repo().sync(force: true);

      expect(book.reads, 0);
      expect(book.requests, 0, reason: 'sync never prompts');
      verifyNever(() => api.discoverContacts(any()));
      expect(state().access, ContactsAccess.denied);
    });

    test('sends normalised numbers, records the time and loads the list by name',
        () async {
      await repo().sync();

      verify(() => api.discoverContacts(
          ['+255713456789', '+255714000001', '+255799999999'])).called(1);
      expect(store.contactsSyncedAt, isNotNull);
      expect(state().contacts!.map((u) => u.id), ['u2', 'u3']);
      expect(state().syncing, isFalse);
    });

    test('runs at most once an hour unless forced', () async {
      await repo().sync();
      await repo().sync();
      expect(book.reads, 1);

      await repo().sync(force: true);
      expect(book.reads, 2);

      store.contactsSyncedAt = DateTime.now().subtract(const Duration(minutes: 61));
      await repo().sync();
      expect(book.reads, 3);
    });

    test('maxAge shortens the limit (New chat re-checks after 2 minutes)', () async {
      store.contactsSyncedAt = DateTime.now().subtract(const Duration(minutes: 1));
      await repo().sync(maxAge: newChatSyncInterval);
      expect(book.reads, 0, reason: 'checked a minute ago');

      store.contactsSyncedAt = DateTime.now().subtract(const Duration(minutes: 3));
      await repo().sync(maxAge: newChatSyncInterval);
      expect(book.reads, 1);

      store.contactsSyncedAt = DateTime.now().subtract(const Duration(minutes: 3));
      await repo().sync();
      expect(book.reads, 1, reason: 'the default stays hourly');
    });

    test('large address books go out in batches of 1,000', () async {
      book.numbers = [
        for (var i = 0; i < 2300; i++) '+25571${i.toString().padLeft(7, '0')}',
      ];
      await repo().sync();

      final batches = verify(() => api.discoverContacts(captureAny())).captured;
      expect(batches.map((b) => (b as List).length), [1000, 1000, 300]);
    });

    test('a rate limit keeps the shown list and reports the error', () async {
      await repo().load();
      when(() => api.discoverContacts(any())).thenThrow(const ApiError(
        status: 429,
        code: ApiErrorCode.rateLimited,
        message: 'slow down',
        retryAfter: 600,
      ));

      await repo().sync(force: true);

      expect(state().contacts, hasLength(2));
      expect(state().error?.code, ApiErrorCode.rateLimited);
      expect(state().syncing, isFalse);
      expect(store.contactsSyncedAt, isNull);
    });

    test('requestAccess syncs straight away when granted', () async {
      book
        ..current = ContactsAccess.unknown
        ..onRequest = ContactsAccess.granted;
      store.contactsSyncedAt = DateTime.now(); // the hourly limit must not block it

      await repo().requestAccess();

      expect(book.requests, 1);
      expect(book.reads, 1);
      expect(state().access, ContactsAccess.granted);
    });

    test('a different account starts from an empty state', () async {
      await repo().load();
      expect(state().contacts, isNotNull);

      container.read(sessionProvider.notifier).clear();
      expect(state().contacts, isNull);
    });
  });
}
