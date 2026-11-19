import 'dart:async';

import 'package:chat_app/core/api/api_client.dart';
import 'package:chat_app/core/api/models/models.dart';
import 'package:chat_app/core/realtime/socket_service.dart';
import 'package:chat_app/features/contacts/contacts_repository.dart';
import 'package:mocktail/mocktail.dart';

class MockApiClient extends Mock implements ApiClient {}

/// Never opens a connection; tests push events through [revoked] and [profile].
class FakeSocketService extends SocketService {
  FakeSocketService()
      : super(accessToken: () => null, deviceId: () => null, refresh: () async => null);

  final revoked = StreamController<DeviceRevokedEvent>.broadcast();
  final profile = StreamController<ProfileUpdatedEvent>.broadcast();
  int connects = 0;
  int disconnects = 0;

  @override
  Stream<DeviceRevokedEvent> get deviceRevoked => revoked.stream;

  @override
  Stream<ProfileUpdatedEvent> get profileUpdated => profile.stream;

  @override
  void connect() => connects++;

  @override
  void disconnect() => disconnects++;

  @override
  void dispose() {
    revoked.close();
    profile.close();
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
