// Manual helper, not part of the test suite: a headless second user for trying the app on one
// emulator. It signs in against a running API, then answers every text it receives.
//
//   flutter test tool/peer_bot_test.dart \
//     --dart-define=API_URL=http://localhost:3010 --dart-define=BOT_PHONE=+255700000222
//
// Prints one line per event. Runs for BOT_MINUTES (default 15).
import 'dart:async';
import 'dart:io';

import 'package:chat_app/core/api/api_client.dart';
import 'package:chat_app/core/api/models/models.dart';
import 'package:chat_app/core/crypto/envelope_cipher.dart';
import 'package:chat_app/core/crypto/key_manager.dart';
import 'package:chat_app/core/db/app_database.dart';
import 'package:chat_app/core/realtime/socket_service.dart';
import 'package:chat_app/core/storage/secure_store.dart';
import 'package:chat_app/features/chat/messaging_service.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

const apiUrl = String.fromEnvironment('API_URL', defaultValue: 'http://localhost:3010');
const phone = String.fromEnvironment('BOT_PHONE', defaultValue: '+255700000222');
const minutes = int.fromEnvironment('BOT_MINUTES', defaultValue: 15);

void log(String s) => stdout.writeln('[bot ${DateTime.now().toIso8601String().substring(11, 19)}] $s');

void main() {
  test('peer bot', () async {
    String? token;
    final api = ApiClient(
      store: MemorySecureStore(),
      baseUrl: '$apiUrl/v1',
      hooks: SessionHooks(
        accessToken: () => token,
        onAccessToken: (t) => token = t,
        onSessionLost: () => log('session lost'),
      ),
    );

    await api.requestCode(phone);
    final otp = await Dio().get<Map<String, dynamic>>(
      '$apiUrl/v1/dev/last-otp',
      queryParameters: {'phone': phone},
    );
    final auth = await api.verify(
      phone: phone,
      code: otp.data!['code'] as String,
      deviceName: 'Peer bot',
    );
    token = auth.accessToken;
    if (!auth.user.profileComplete) await api.updateMe(displayName: 'Bot Bob');
    final me = (userId: auth.user.id, deviceId: auth.device.id);
    log('signed in as $phone user=${me.userId} device=${me.deviceId}');

    final db = AppDatabase(NativeDatabase.memory());
    final keys = KeyManager(api: api, db: db);
    await keys.ensureKeys();
    log('keys uploaded');

    final socket = SocketService(
      accessToken: () => token,
      deviceId: () => me.deviceId,
      refresh: api.refresh,
      url: '$apiUrl/rt',
    );
    final service = MessagingService(
      api: api,
      db: db,
      cipher: EnvelopeCipher(keys.store),
      socket: socket,
      me: () => me,
    );
    socket.prekeysLow.listen((e) => keys.topUp(e.count));
    socket.typing.listen((e) => log('peer typing: ${e.state.name}'));
    socket.connect();
    service.start();

    // Report every change and answer each new text from someone else.
    final answered = <String>{};
    final lastStatus = <String, MessageStatus>{};
    final sub = db.select(db.messages).watch().listen((rows) async {
      for (final m in rows) {
        if (lastStatus[m.id] == m.status) continue;
        lastStatus[m.id] = m.status;
        final who = m.senderUserId == me.userId ? 'me' : 'peer';
        log('$who ${m.kind.name} "${m.body}" -> ${m.status.name}');
        if (who == 'peer' && m.kind == MessageKind.text && answered.add(m.id)) {
          unawaited(_reply(service, m));
        }
      }
    });

    await Future<void>.delayed(const Duration(minutes: minutes));
    await sub.cancel();
    service.dispose();
    socket.dispose();
    await db.close();
  }, timeout: const Timeout(Duration(minutes: minutes + 1)));
}

/// Reads after 2 s, types for 2 s, then answers.
Future<void> _reply(MessagingService service, Message m) async {
  await Future<void>.delayed(const Duration(seconds: 2));
  await service.openConversation(m.conversationId);
  service.composerChanged(m.conversationId, 'typing');
  await Future<void>.delayed(const Duration(seconds: 2));
  await service.sendText(m.conversationId, 'echo: ${m.body}');
  service.closeConversation(m.conversationId);
}
