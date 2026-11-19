import 'package:chat_app/core/api/api_client.dart';
import 'package:chat_app/core/api/models/models.dart';
import 'package:chat_app/core/auth/session.dart';
import 'package:chat_app/core/db/db_opener.dart';
import 'package:chat_app/core/realtime/socket_service.dart';
import 'package:chat_app/core/storage/secure_store.dart';
import 'package:chat_app/features/auth/auth_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

const _me = Me(
  id: 'u1',
  phone: '+255712345678',
  displayName: 'Asha',
  about: '',
  avatarUrl: null,
  avatarThumbUrl: null,
  profileComplete: true,
);

void main() {
  late ProviderContainer container;
  late FakeSocketService socket;
  late FakeKeyManager keys;
  late FakeMessagingService messaging;
  late MemorySecureStore store;
  late int fileDeletes;

  setUp(() {
    socket = FakeSocketService();
    keys = FakeKeyManager();
    messaging = FakeMessagingService();
    store = MemorySecureStore('refresh')..dbKey = 'ab' * 32;
    fileDeletes = 0;
    container = ProviderContainer(overrides: [
      apiClientProvider.overrideWithValue(MockApiClient()),
      socketServiceProvider.overrideWithValue(socket),
      secureStoreProvider.overrideWithValue(store),
      ...localDataOverrides(
        keys: keys,
        messaging: messaging,
        onDeleteFiles: () => fileDeletes++,
      ),
    ]);
    container.listen(sessionLifecycleProvider, (_, _) {});
  });
  tearDown(() => container.dispose());

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('signing in connects and sets up keys', () async {
    container.read(sessionProvider.notifier).setSession(accessToken: 'a', me: _me, deviceId: 'd1');
    await settle();

    expect(socket.connects, 1);
    expect(keys.ensures, 1);
  });

  test('prekeys:low tops up while signed in', () async {
    container.read(sessionProvider.notifier).setSession(accessToken: 'a', me: _me, deviceId: 'd1');
    socket.prekeys.add(const PrekeysLowEvent(count: 3));
    await settle();

    expect(keys.topUps, [3]);
  });

  test('ending the session wipes the database, its key and the tokens', () async {
    container.read(sessionProvider.notifier).setSession(accessToken: 'a', me: _me, deviceId: 'd1');
    final db = container.read(appDatabaseProvider);
    await settle();

    container.read(sessionProvider.notifier).clear(SignOutReason.inactive);
    await settle();
    await settle();

    expect(socket.disconnects, greaterThanOrEqualTo(1));
    expect(fileDeletes, 1);
    expect(store.dbKey, isNull);
    expect(store.refreshToken, isNull);
    expect(container.read(appDatabaseProvider), isNot(same(db)));
  });

  test('device:revoked ends the session and wipes', () async {
    container.read(sessionProvider.notifier).setSession(accessToken: 'a', me: _me, deviceId: 'd1');
    await settle();

    socket.revoked.add(const DeviceRevokedEvent(deviceId: 'd1', reason: DeviceRevokedReason.replaced));
    await settle();
    await settle();

    expect(container.read(sessionProvider).signOutReason, SignOutReason.replaced);
    expect(fileDeletes, 1);
    expect(store.dbKey, isNull);
  });

  test('a new sign-in after a wipe sets up keys again', () async {
    final session = container.read(sessionProvider.notifier);
    session.setSession(accessToken: 'a', me: _me, deviceId: 'd1');
    await settle();
    session.clear();
    session.setSession(accessToken: 'b', me: _me, deviceId: 'd2');
    await settle();
    await settle();

    expect(fileDeletes, 1);
    expect(keys.ensures, 2);
  });

  test('messaging starts with the session and stops when it ends', () async {
    final session = container.read(sessionProvider.notifier);
    session.setSession(accessToken: 'a', me: _me, deviceId: 'd1');
    await settle();
    expect(messaging.starts, 1);

    session.clear();
    await settle();
    expect(messaging.stops, 1);
  });
}
