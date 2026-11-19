import 'package:chat_app/app.dart';
import 'package:chat_app/core/api/api_client.dart';
import 'package:chat_app/core/api/models/models.dart';
import 'package:chat_app/core/auth/session.dart';
import 'package:chat_app/core/realtime/socket_service.dart';
import 'package:chat_app/core/storage/secure_store.dart';
import 'package:chat_app/features/auth/phone_screen.dart';
import 'package:chat_app/features/devices/devices_controller.dart';
import 'package:chat_app/features/devices/linked_devices_screen.dart';
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

Device _device(String id, DeviceType type, String name,
        {bool current = false, Duration ago = Duration.zero}) =>
    Device(
      id: id,
      type: type,
      name: name,
      createdAt: DateTime.utc(2026),
      lastActiveAt: DateTime.now().subtract(ago),
      current: current,
    );

ApiError _err(ApiErrorCode code, {int status = 400}) =>
    ApiError(status: status, code: code, message: code.wire);

void main() {
  late MockApiClient api;
  late ProviderContainer container;

  final phone = _device('d1', DeviceType.android, 'Pixel 9', current: true);
  final chrome = _device('d2', DeviceType.web, 'Chrome on Windows',
      ago: const Duration(minutes: 5));
  final firefox = _device('d3', DeviceType.web, 'Firefox on Linux',
      ago: const Duration(hours: 3));

  setUp(() {
    api = MockApiClient();
    when(() => api.signOut()).thenAnswer((_) async {});
    // Web first in the response: the screen must still put this phone on top.
    when(() => api.listDevices()).thenAnswer((_) async => [chrome, firefox, phone]);
  });

  Future<void> open(WidgetTester tester) async {
    container = ProviderContainer(overrides: [
      apiClientProvider.overrideWithValue(api),
      socketServiceProvider.overrideWithValue(FakeSocketService()),
      ...localDataOverrides(),
      secureStoreProvider.overrideWithValue(MemorySecureStore()),
    ]);
    addTearDown(container.dispose);
    container.read(sessionProvider.notifier).setSession(accessToken: 'a', me: _me);
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const ChatApp()),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('home-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-devices')));
    await tester.pumpAndSettle();
    expect(find.byType(LinkedDevicesScreen), findsOneWidget);
  }

  Future<void> signOut(WidgetTester tester, String id, {bool confirm = true}) async {
    await tester.tap(find.byKey(Key('sign-out-$id')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key(confirm ? 'confirm-sign-out' : 'cancel')));
    await tester.pumpAndSettle();
  }

  group('lastActiveText', () {
    final now = DateTime(2026, 11, 19, 12);
    test('wording matches the web page', () {
      expect(lastActiveText(now.subtract(const Duration(seconds: 90)), now), 'Active now');
      expect(lastActiveText(now.add(const Duration(minutes: 1)), now), 'Active now');
      expect(lastActiveText(now.subtract(const Duration(minutes: 2)), now),
          'Active 2 minutes ago');
      expect(lastActiveText(now.subtract(const Duration(minutes: 59)), now),
          'Active 59 minutes ago');
      expect(lastActiveText(now.subtract(const Duration(minutes: 60)), now),
          'Active 1 hour ago');
      expect(lastActiveText(now.subtract(const Duration(hours: 23)), now),
          'Active 23 hours ago');
      expect(lastActiveText(DateTime(2026, 11, 12, 9), now), 'Last active 12 Nov 2026');
    });
  });

  testWidgets('lists this phone first, then the other devices', (tester) async {
    await open(tester);

    double top(String id) => tester.getTopLeft(find.byKey(ValueKey('device-$id'))).dy;
    expect(top('d1'), lessThan(top('d2')));
    expect(top('d2'), lessThan(top('d3')));
    expect(find.byKey(const Key('this-phone')), findsOneWidget);
    expect(find.text('Android · Active now'), findsOneWidget);
    expect(find.text('Web · Active 5 minutes ago'), findsOneWidget);
    expect(find.text('Web · Active 3 hours ago'), findsOneWidget);
  });

  testWidgets('signing out another device removes it', (tester) async {
    when(() => api.revokeDevice(any())).thenAnswer((_) async {});
    await open(tester);

    await signOut(tester, 'd2');

    verify(() => api.revokeDevice('d2')).called(1);
    expect(find.text('Chrome on Windows'), findsNothing);
    expect(find.text('Firefox on Linux'), findsOneWidget);
  });

  testWidgets('cancelling the dialog does nothing', (tester) async {
    await open(tester);

    await signOut(tester, 'd2', confirm: false);

    verifyNever(() => api.revokeDevice(any()));
    expect(find.text('Chrome on Windows'), findsOneWidget);
  });

  testWidgets('a device that is already gone is removed and explained', (tester) async {
    when(() => api.revokeDevice(any()))
        .thenThrow(_err(ApiErrorCode.deviceNotFound, status: 404));
    await open(tester);

    await signOut(tester, 'd3');

    expect(find.text('Firefox on Linux'), findsNothing);
    expect(find.text('That device is no longer signed in.'), findsOneWidget);
  });

  testWidgets('other errors keep the device and show a message', (tester) async {
    when(() => api.revokeDevice(any())).thenThrow(const ApiError.network());
    await open(tester);

    await signOut(tester, 'd2');

    expect(find.text('Chrome on Windows'), findsOneWidget);
    expect(find.text("Can't reach the server. Check your connection."), findsOneWidget);
  });

  testWidgets('signing out this phone returns to sign-in', (tester) async {
    await open(tester);

    await signOut(tester, 'd1');

    verify(() => api.signOut()).called(1);
    verifyNever(() => api.revokeDevice(any()));
    expect(find.byType(PhoneScreen), findsOneWidget);
  });

  testWidgets('a failed load shows the error and Retry reloads', (tester) async {
    var calls = 0;
    when(() => api.listDevices()).thenAnswer((_) async {
      if (calls++ == 0) throw const ApiError.network();
      return [phone];
    });
    await open(tester);

    expect(find.byKey(const Key('devices-error')), findsOneWidget);
    await tester.tap(find.byKey(const Key('retry')));
    await tester.pumpAndSettle();

    expect(find.text('Pixel 9'), findsOneWidget);
    expect(find.byKey(const Key('devices-error')), findsNothing);
  });

  testWidgets('the list refreshes every 30 seconds', (tester) async {
    await open(tester);
    verify(() => api.listDevices()).called(1);

    when(() => api.listDevices()).thenAnswer((_) async => [phone]);
    await tester.pump(LinkedDevicesScreen.pollInterval);
    await tester.pumpAndSettle();

    verify(() => api.listDevices()).called(1);
    expect(find.text('Chrome on Windows'), findsNothing);
  });
}
