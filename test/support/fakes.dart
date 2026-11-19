import 'dart:async';

import 'package:chat_app/core/api/api_client.dart';
import 'package:chat_app/core/api/models/models.dart';
import 'package:chat_app/core/crypto/key_manager.dart';
import 'package:chat_app/core/db/app_database.dart';
import 'package:chat_app/core/db/db_opener.dart';
import 'package:chat_app/core/realtime/socket_service.dart';
import 'package:chat_app/features/chat/messaging_service.dart';
import 'package:chat_app/features/contacts/contacts_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:mocktail/mocktail.dart';

class MockApiClient extends Mock implements ApiClient {}

/// Never opens a connection; tests push events through the controllers below and read the
/// typing states sent in [typingSent].
class FakeSocketService extends SocketService {
  FakeSocketService()
      : super(accessToken: () => null, deviceId: () => null, refresh: () async => null);

  final revoked = StreamController<DeviceRevokedEvent>.broadcast();
  final profile = StreamController<ProfileUpdatedEvent>.broadcast();
  final prekeys = StreamController<PrekeysLowEvent>.broadcast();
  final envelopes = StreamController<Envelope>.broadcast();
  final conversations = StreamController<ConversationUpdatedEvent>.broadcast();
  final typingIn = StreamController<TypingEvent>.broadcast();
  final connectedEvents = StreamController<void>.broadcast();
  final typingSent = <(String, TypingState)>[];
  int connects = 0;
  int disconnects = 0;

  @override
  Stream<DeviceRevokedEvent> get deviceRevoked => revoked.stream;

  @override
  Stream<ProfileUpdatedEvent> get profileUpdated => profile.stream;

  @override
  Stream<PrekeysLowEvent> get prekeysLow => prekeys.stream;

  @override
  Stream<Envelope> get envelopeNew => envelopes.stream;

  @override
  Stream<ConversationUpdatedEvent> get conversationUpdated => conversations.stream;

  @override
  Stream<TypingEvent> get typing => typingIn.stream;

  @override
  Stream<void> get connected => connectedEvents.stream;

  @override
  void emitTyping(String conversationId, TypingState state) =>
      typingSent.add((conversationId, state));

  @override
  void connect() => connects++;

  @override
  void disconnect() => disconnects++;

  @override
  void dispose() {
    revoked.close();
    profile.close();
    prekeys.close();
    envelopes.close();
    conversations.close();
    typingIn.close();
    connectedEvents.close();
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

/// Records calls instead of syncing with the server. [startDirect] answers [directId].
class FakeMessagingService implements MessagingService {
  int starts = 0;
  int stops = 0;
  String directId = 'c-new';
  final startedWith = <PublicUser>[];
  final sentTexts = <(String, String)>[];
  final opened = <String>[];
  final closed = <String>[];
  final retried = <String>[];
  final typing = StreamController<Set<String>>.broadcast();

  @override
  Future<String> startDirect(PublicUser user) async {
    startedWith.add(user);
    return directId;
  }

  @override
  Future<String> sendText(String conversationId, String body) async {
    sentTexts.add((conversationId, body));
    return 'm${sentTexts.length}';
  }

  @override
  Future<void> openConversation(String conversationId) async => opened.add(conversationId);

  @override
  void closeConversation(String conversationId) => closed.add(conversationId);

  @override
  Future<void> retry(String messageId) async => retried.add(messageId);

  @override
  void composerChanged(String conversationId, String text) {}

  @override
  Stream<Set<String>> typingUsers(String conversationId) => typing.stream;

  @override
  void start() => starts++;

  @override
  void stop() => stops++;

  @override
  void dispose() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Keeps app-level tests off the disk and the servers: in-memory database, no file deletes,
/// [keys] (a [FakeKeyManager] by default) instead of the real key manager, and [messaging]
/// (a [FakeMessagingService] by default) unless [realMessaging] is set.
List<Override> localDataOverrides({
  FakeKeyManager? keys,
  FakeMessagingService? messaging,
  bool realMessaging = false,
  void Function()? onDeleteFiles,
}) =>
    [
      appDatabaseProvider.overrideWith((ref) => AppDatabase(NativeDatabase.memory())),
      deleteDatabaseFilesProvider.overrideWithValue(() async => onDeleteFiles?.call()),
      keyManagerProvider.overrideWithValue(keys ?? FakeKeyManager()),
      if (!realMessaging)
        messagingServiceProvider.overrideWithValue(messaging ?? FakeMessagingService()),
    ];
