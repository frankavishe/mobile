import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_contacts/flutter_contacts.dart' as fc;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phone_numbers_parser/phone_numbers_parser.dart';

import '../../core/api/api_client.dart';
import '../../core/api/models/models.dart';
import '../../core/auth/session.dart';
import '../../core/phone.dart';
import '../../core/storage/secure_store.dart';

/// Whether the app may read the address book.
/// - [unknown]: not asked yet, or the platform could not tell.
/// - [denied]: refused, but the app may ask again.
/// - [blocked]: refused for good; only system settings can change it.
enum ContactsAccess { unknown, granted, denied, blocked }

/// The phone's address book. Tests override [addressBookProvider].
abstract interface class AddressBook {
  /// Current access; asks the user first when [request] is true.
  Future<ContactsAccess> access({bool request = false});

  /// Every phone number in the address book, as stored (may be local, e.g. `0712 345 678`).
  Future<List<String>> rawNumbers();

  Future<void> openSettings();
}

class FlutterContactsAddressBook implements AddressBook {
  const FlutterContactsAddressBook();

  @override
  Future<ContactsAccess> access({bool request = false}) async {
    try {
      final p = fc.FlutterContacts.permissions;
      final status = request
          ? await p.request(fc.PermissionType.read)
          : await p.check(fc.PermissionType.read);
      return switch (status) {
        fc.PermissionStatus.granted || fc.PermissionStatus.limited => ContactsAccess.granted,
        fc.PermissionStatus.permanentlyDenied ||
        fc.PermissionStatus.restricted =>
          ContactsAccess.blocked,
        fc.PermissionStatus.denied => ContactsAccess.denied,
        fc.PermissionStatus.notDetermined => ContactsAccess.unknown,
      };
    } on PlatformException {
      return ContactsAccess.unknown;
    } on MissingPluginException {
      return ContactsAccess.unknown;
    }
  }

  @override
  Future<List<String>> rawNumbers() async {
    final contacts =
        await fc.FlutterContacts.getAll(properties: {fc.ContactProperty.phone});
    return [
      for (final c in contacts)
        for (final p in c.phones)
          (p.normalizedNumber?.isNotEmpty ?? false) ? p.normalizedNumber! : p.number,
    ];
  }

  @override
  Future<void> openSettings() => fc.FlutterContacts.permissions.openSettings();
}

final addressBookProvider =
    Provider<AddressBook>((ref) => const FlutterContactsAddressBook());

/// Address-book numbers in E.164, without duplicates, invalid numbers or [exclude] (the
/// user's own number). Local numbers are read as numbers in [home].
List<String> normalizeNumbers(
  Iterable<String> raw, {
  required IsoCode home,
  String? exclude,
}) {
  final out = <String>{};
  for (final r in raw) {
    var s = r.replaceAll(RegExp(r'[^\d+]'), '');
    if (s.startsWith('00')) s = '+${s.substring(2)}';
    if (s.replaceAll('+', '').length < 6) continue;
    try {
      final n = PhoneNumber.parse(s, callerCountry: home);
      if (n.isValid()) out.add(n.international);
    } catch (_) {
      // Not a phone number (e.g. a short code); skip it.
    }
  }
  if (exclude != null) out.remove(exclude);
  return out.toList();
}

/// The country of [e164], or null.
IsoCode? countryOf(String? e164) {
  if (e164 == null) return null;
  try {
    return PhoneNumber.parse(e164).isoCode;
  } catch (_) {
    return null;
  }
}

/// Max numbers per `POST /contacts/discover`.
const discoverBatchSize = 1000;

/// FR-013: the address book is checked again at most this often (unless the user asks).
const contactsSyncInterval = Duration(hours: 1);

/// Opening New chat re-checks the address book if the last check is older than this, so
/// people who joined since then show up. The server allows 10 discover calls per device per
/// hour (one per [discoverBatchSize] numbers), which this stays under for normal address books.
const newChatSyncInterval = Duration(minutes: 2);

@immutable
class ContactsState {
  const ContactsState({
    this.access = ContactsAccess.unknown,
    this.contacts,
    this.syncing = false,
    this.error,
  });

  final ContactsAccess access;

  /// Contacts on the app, from the server; null until loaded.
  final List<PublicUser>? contacts;
  final bool syncing;

  /// The last load or sync failure; the list shown is kept.
  final ApiError? error;

  ContactsState copyWith({
    ContactsAccess? access,
    List<PublicUser>? contacts,
    bool? syncing,
    ApiError? Function()? error,
  }) =>
      ContactsState(
        access: access ?? this.access,
        contacts: contacts ?? this.contacts,
        syncing: syncing ?? this.syncing,
        error: error != null ? error() : this.error,
      );
}

/// Finds which address-book contacts are on the app (T064, FR-013) and keeps the list the
/// server holds. Numbers are sent only to `POST /contacts/discover`; nothing is stored here.
class ContactsRepository extends Notifier<ContactsState> {
  @override
  ContactsState build() {
    // A different account must not see the previous one's contacts.
    ref.listen(sessionProvider.select((s) => s.me?.id), (prev, next) {
      if (prev != next) state = const ContactsState();
    });
    return const ContactsState();
  }

  ApiClient get _api => ref.read(apiClientProvider);
  AddressBook get _book => ref.read(addressBookProvider);
  SecureStore get _store => ref.read(secureStoreProvider);

  /// Re-reads the permission (e.g. after the user returns from system settings).
  Future<ContactsAccess> checkAccess() async {
    final access = await _book.access();
    state = state.copyWith(access: access);
    return access;
  }

  /// Loads the contacts the server knows. Returns false on failure ([ContactsState.error]).
  Future<bool> load() async {
    try {
      final list = await _api.listContacts();
      list.sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
      state = state.copyWith(contacts: list, error: () => null);
      return true;
    } on ApiError catch (e) {
      state = state.copyWith(error: () => e);
      return false;
    }
  }

  /// Asks for access; when granted, checks the address book straight away.
  Future<void> requestAccess() async {
    final access = await _book.access(request: true);
    state = state.copyWith(access: access);
    if (access == ContactsAccess.granted) await sync(force: true);
  }

  /// Checks the address book against the server. Without [force] this runs at most once per
  /// [maxAge] (default [contactsSyncInterval]). Never asks for permission.
  Future<void> sync({bool force = false, Duration maxAge = contactsSyncInterval}) async {
    if (state.syncing) return;
    final access = await checkAccess();
    if (access != ContactsAccess.granted) return;
    if (!force) {
      final last = await _store.readContactsSyncedAt();
      if (last != null && DateTime.now().difference(last) < maxAge) return;
    }

    state = state.copyWith(syncing: true, error: () => null);
    try {
      final me = ref.read(sessionProvider).me;
      final home = countryOf(me?.phone) ?? defaultCountry();
      final numbers = normalizeNumbers(
        await _book.rawNumbers(),
        home: home,
        exclude: me?.phone,
      );
      for (var i = 0; i < numbers.length; i += discoverBatchSize) {
        final end = i + discoverBatchSize;
        await _api.discoverContacts(
          numbers.sublist(i, end > numbers.length ? numbers.length : end),
        );
      }
      await _store.writeContactsSyncedAt(DateTime.now());
      await load();
    } on ApiError catch (e) {
      state = state.copyWith(error: () => e);
    } on PlatformException {
      state = state.copyWith(error: () => const ApiError(
            status: 0,
            code: ApiErrorCode.unknown,
            message: "Couldn't read your contacts.",
          ));
    } finally {
      state = state.copyWith(syncing: false);
    }
  }

  Future<void> openSettings() => _book.openSettings();
}

final contactsProvider =
    NotifierProvider<ContactsRepository, ContactsState>(ContactsRepository.new);

/// FR-013: checks the address book when the app opens (signed in with a profile) and each
/// time it comes back to the foreground. [ContactsRepository.sync] keeps it to once an hour
/// and does nothing without permission (it never prompts).
final contactsAutoSyncProvider = Provider<void>((ref) {
  bool ready() {
    final s = ref.read(sessionProvider);
    return s.isSignedIn && s.me?.profileComplete == true;
  }

  void run() {
    if (ready()) ref.read(contactsProvider.notifier).sync();
  }

  ref.listen<bool>(
    sessionProvider.select((s) => s.isSignedIn && s.me?.profileComplete == true),
    (_, isReady) {
      if (isReady) run();
    },
    fireImmediately: true,
  );
  final lifecycle = AppLifecycleListener(onResume: run);
  ref.onDispose(lifecycle.dispose);
});
