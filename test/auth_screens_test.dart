import 'package:chat_app/app.dart';
import 'package:chat_app/core/api/api_client.dart';
import 'package:chat_app/core/api/models/models.dart';
import 'package:chat_app/core/auth/session.dart';
import 'package:chat_app/core/realtime/socket_service.dart';
import 'package:chat_app/core/storage/secure_store.dart';
import 'package:chat_app/features/auth/auth_controller.dart';
import 'package:chat_app/features/auth/code_screen.dart';
import 'package:chat_app/features/auth/phone_screen.dart';
import 'package:chat_app/features/home/home_screen.dart';
import 'package:chat_app/router.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'support/fakes.dart';

const _phone = '+255712345678';

const _me = Me(
  id: 'u1',
  phone: _phone,
  displayName: 'Frank',
  about: '',
  avatarUrl: null,
  profileComplete: true,
);

final _authResult = AuthResult(
  accessToken: 'access',
  expiresIn: 900,
  refreshToken: 'refresh',
  isNewAccount: false,
  device: Device(
    id: 'd1',
    type: DeviceType.android,
    name: 'Pixel 9',
    createdAt: DateTime.utc(2026),
    lastActiveAt: DateTime.utc(2026),
    current: true,
  ),
  user: _me,
);

ApiError _err(ApiErrorCode code, {int status = 400, int? retryAfter}) =>
    ApiError(status: status, code: code, message: code.wire, retryAfter: retryAfter);

void main() {
  late MockApiClient api;
  late FakeSocketService socket;
  late MemorySecureStore store;
  late ProviderContainer container;

  setUp(() {
    api = MockApiClient();
    socket = FakeSocketService();
    store = MemorySecureStore();
    when(() => api.requestCode(any())).thenAnswer(
      (_) async => const RequestCodeResponse(expiresIn: 300, resendAfter: 30),
    );
    when(() => api.signOut()).thenAnswer((_) async {});
  });

  /// Boots the real app signed out (so it lands on the phone screen), in Tanzania.
  Future<void> boot(WidgetTester tester) async {
    tester.platformDispatcher.localeTestValue = const Locale('sw', 'TZ');
    addTearDown(tester.platformDispatcher.clearLocaleTestValue);
    container = ProviderContainer(overrides: [
      apiClientProvider.overrideWithValue(api),
      socketServiceProvider.overrideWithValue(socket),
      secureStoreProvider.overrideWithValue(store),
      deviceNameProvider.overrideWithValue(() async => 'Pixel 9'),
    ]);
    addTearDown(container.dispose);
    container.read(sessionProvider.notifier).clear();
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const ChatApp()),
    );
    await tester.pumpAndSettle();
    expect(find.byType(PhoneScreen), findsOneWidget);
  }

  Future<void> toCodeScreen(WidgetTester tester) async {
    await tester.enterText(find.byKey(const Key('phone')), '712 345 678');
    await tester.pump();
    await tester.tap(find.byKey(const Key('continue')));
    await tester.pumpAndSettle();
    expect(find.byType(CodeScreen), findsOneWidget);
  }

  FilledButton continueButton(WidgetTester tester) =>
      tester.widget<FilledButton>(find.byKey(const Key('continue')));

  group('phone screen', () {
    testWidgets('defaults to the locale country and validates the number', (tester) async {
      await boot(tester);
      expect(find.text('🇹🇿 +255'), findsOneWidget);
      expect(continueButton(tester).onPressed, isNull);

      await tester.enterText(find.byKey(const Key('phone')), '12345678');
      await tester.pump();
      expect(continueButton(tester).onPressed, isNull);
      expect(find.text("That phone number isn't valid."), findsOneWidget);

      await tester.enterText(find.byKey(const Key('phone')), '0712 345 678');
      await tester.pump();
      expect(continueButton(tester).onPressed, isNotNull);
    });

    testWidgets('sends the number in E.164 and opens the code screen', (tester) async {
      await boot(tester);
      await toCodeScreen(tester);
      verify(() => api.requestCode(_phone)).called(1);
      expect(find.textContaining('+255 712 345 678'), findsOneWidget);
    });

    testWidgets('shows the wait time when rate limited', (tester) async {
      when(() => api.requestCode(any())).thenThrow(
        _err(ApiErrorCode.rateLimited, status: 429, retryAfter: 90),
      );
      await boot(tester);
      await tester.enterText(find.byKey(const Key('phone')), '712345678');
      await tester.pump();
      await tester.tap(find.byKey(const Key('continue')));
      await tester.pumpAndSettle();
      expect(find.byType(CodeScreen), findsNothing);
      expect(find.text('Too many requests. Try again in 2 minutes.'), findsOneWidget);
    });

    testWidgets('picks another country from the sheet', (tester) async {
      await boot(tester);
      await tester.tap(find.byKey(const Key('country')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'KE');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, 'KE'));
      await tester.pumpAndSettle();
      expect(find.text('🇰🇪 +254'), findsOneWidget);
    });
  });

  group('code screen', () {
    testWidgets('six digits verify and sign in', (tester) async {
      when(() => api.verify(
            phone: any(named: 'phone'),
            code: any(named: 'code'),
            deviceName: any(named: 'deviceName'),
          )).thenAnswer((_) async => _authResult);
      await boot(tester);
      await toCodeScreen(tester);

      await tester.enterText(find.byKey(const Key('code')), '123456');
      await tester.pumpAndSettle();

      verify(() => api.verify(phone: _phone, code: '123456', deviceName: 'Pixel 9'))
          .called(1);
      final session = container.read(sessionProvider);
      expect(session.isSignedIn, isTrue);
      expect(session.deviceId, 'd1');
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(socket.connects, 1);
    });

    testWidgets('a wrong code shows a message and clears the field', (tester) async {
      when(() => api.verify(
            phone: any(named: 'phone'),
            code: any(named: 'code'),
            deviceName: any(named: 'deviceName'),
          )).thenThrow(_err(ApiErrorCode.invalidCode));
      await boot(tester);
      await toCodeScreen(tester);

      await tester.enterText(find.byKey(const Key('code')), '000000');
      await tester.pumpAndSettle();

      expect(find.text("That code isn't right. Check it and try again."), findsOneWidget);
      expect(tester.widget<TextField>(find.byKey(const Key('code'))).controller!.text, '');
      expect(container.read(sessionProvider).isSignedIn, isFalse);
    });

    for (final (code, text) in [
      (ApiErrorCode.codeExpired, 'That code has expired. Request a new one.'),
      (ApiErrorCode.tooManyAttempts, 'Too many attempts. Request a new code.'),
    ]) {
      testWidgets('${code.wire} locks entry and offers a new code', (tester) async {
        when(() => api.verify(
              phone: any(named: 'phone'),
              code: any(named: 'code'),
              deviceName: any(named: 'deviceName'),
            )).thenThrow(_err(code));
        await boot(tester);
        await toCodeScreen(tester);

        await tester.enterText(find.byKey(const Key('code')), '123456');
        await tester.pumpAndSettle();

        expect(find.text(text), findsOneWidget);
        expect(tester.widget<TextField>(find.byKey(const Key('code'))).enabled, isFalse);
        expect(find.byKey(const Key('new-code')), findsOneWidget);
      });
    }

    testWidgets('resend is disabled until the countdown ends', (tester) async {
      await boot(tester);
      await toCodeScreen(tester);

      TextButton resend() => tester.widget<TextButton>(find.byKey(const Key('resend')));
      expect(find.text('Resend code in 0:30'), findsOneWidget);
      expect(resend().onPressed, isNull);

      await tester.pump(const Duration(seconds: 10));
      expect(find.text('Resend code in 0:20'), findsOneWidget);

      await tester.pump(const Duration(seconds: 20));
      expect(find.text('Resend code'), findsOneWidget);
      expect(resend().onPressed, isNotNull);

      await tester.tap(find.byKey(const Key('resend')));
      await tester.pump();
      verify(() => api.requestCode(_phone)).called(2);
      expect(find.text('Resend code in 0:30'), findsOneWidget);
    });
  });

  group('session lifecycle', () {
    testWidgets('device:revoked wipes storage and explains why on sign-in', (tester) async {
      await boot(tester);
      store.refreshToken = 'refresh';
      container.read(sessionProvider.notifier).setSession(accessToken: 'a', me: _me);
      await tester.pumpAndSettle();
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(socket.connects, 1);

      socket.revoked.add(const DeviceRevokedEvent(
        deviceId: 'd1',
        reason: DeviceRevokedReason.replaced,
      ));
      await tester.pumpAndSettle();

      expect(store.refreshToken, isNull);
      expect(find.byType(PhoneScreen), findsOneWidget);
      expect(find.textContaining('registered on another phone'), findsOneWidget);
      expect(socket.disconnects, greaterThan(0));
    });

    testWidgets('sign out from settings returns to sign-in without a banner', (tester) async {
      await boot(tester);
      container.read(sessionProvider.notifier).setSession(accessToken: 'a', me: _me);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('home-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('settings-sign-out')));
      await tester.pumpAndSettle();

      verify(() => api.signOut()).called(1);
      expect(find.byType(PhoneScreen), findsOneWidget);
      expect(find.byIcon(Icons.info_outline), findsNothing);
    });
  });

  test('signed in with a profile leaves the code step for home', () {
    const s = SessionState(status: SessionStatus.signedIn, me: _me);
    expect(sessionRedirect(s, Routes.signInCode), Routes.home);
  });
}
