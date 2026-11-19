import 'dart:async';

import 'package:chat_app/core/api/api_client.dart';
import 'package:chat_app/core/api/models/models.dart';
import 'package:chat_app/core/crypto/key_manager.dart';
import 'package:chat_app/core/db/app_database.dart';
import 'package:chat_app/core/db/db_opener.dart';
import 'package:chat_app/core/realtime/socket_service.dart';
import 'package:chat_app/features/contacts/contacts_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:mocktail/mocktail.dart';

class MockApiClient extends Mock implements ApiClient {}

/// Never opens a connection; tests push events through [revoked], [profile] and [prekeys].
class FakeSocketService extends SocketService {
  FakeSocketService()
      : super(accessToken: () => null, deviceId: () => null, refresh: () async => null);

  final revoked = StreamController<DeviceRevokedEvent>.broadcast();
  final profile = StreamController<ProfileUpdatedEvent>.broadcast();
  final prekeys = StreamController<PrekeysLowEvent>.broadcast();
  int connects = 0;
  int disconnects = 0;

  @override
  Stream<DeviceRevokedEvent> get deviceRevoked => revoked.stream;

  @override
  Stream<ProfileUpdatedEvent> get profileUpdated => profile.stream;

  @override
  Stream<PrekeysLowEvent> get prekeysLow => prekeys.stream;

  @override
  void connect() => connects++;

  @override
  void disconnect() => disconnects++;

  @override
  void dispose() {
    revoked.close();
    profile.close();
    prekeys.close();
  }
}

/// Address book with a scripted permission and contents.
class FakeAddressBook implements AddressBook {
  FakeAddressBook({
    this.current = ContactsAccess.unknown,
    this.onRequest = ContactsAccess.granted,
    this.numbers = const [],
  });

  ContactsAccess current;

  /// What the permission becomes when the user is asked.
  ContactsAccess onRequest;
  List<String> numbers;
  int requests = 0;
  int reads = 0;
  int settingsOpened = 0;

  @override
  Future<ContactsAccess> access({bool request = false}) async {
    if (request) {
      requests++;
      current = onRequest;
    }
    return current;
  }

  @override
  Future<List<String>> rawNumbers() async {
    reads++;
    return numbers;
  }

  @override
  Future<void> openSettings() async => settingsOpened++;
}

/// Records key work instead of generating keys and calling the API.
class FakeKeyManager implements KeyManager {
  int ensures = 0;
  final topUps = <int>[];

  @override
  Future<void> ensureKeys() async => ensures++;

  @override
  Future<void> topUp(int remaining) async => topUps.add(remaining);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Keeps app-level tests off the disk and the key server: in-memory database, no file deletes,
/// and [keys] (a [FakeKeyManager] by default) instead of the real key manager.
List<Override> localDataOverrides({FakeKeyManager? keys, void Function()? onDeleteFiles}) => [
      appDatabaseProvider.overrideWith((ref) => AppDatabase(NativeDatabase.memory())),
      deleteDatabaseFilesProvider.overrideWithValue(() async => onDeleteFiles?.call()),
      keyManagerProvider.overrideWithValue(keys ?? FakeKeyManager()),
    ];
