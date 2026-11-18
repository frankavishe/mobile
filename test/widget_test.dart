import 'package:chat_app/app.dart';
import 'package:chat_app/core/api/models/models.dart';
import 'package:chat_app/core/auth/session.dart';
import 'package:chat_app/core/realtime/socket_service.dart';
import 'package:chat_app/router.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

const _me = Me(
  id: 'u1',
  phone: '+255712345678',
  displayName: 'Frank',
  about: 'Hi',
  avatarUrl: null,
  profileComplete: true,
);

void main() {
  group('sessionRedirect', () {
    const unknown = SessionState.unknown();
    const signedOut = SessionState(status: SessionStatus.signedOut);
    const signedIn = SessionState(status: SessionStatus.signedIn, me: _me);
    final incomplete = SessionState(
      status: SessionStatus.signedIn,
      me: _me.copyWith(displayName: ''),
    );

    test('unknown → splash', () {
      expect(sessionRedirect(unknown, Routes.home), Routes.splash);
      expect(sessionRedirect(unknown, Routes.splash), isNull);
    });

    test('signed out → sign-in, keeping nested sign-in steps', () {
      expect(sessionRedirect(signedOut, Routes.home), Routes.signIn);
      expect(sessionRedirect(signedOut, '${Routes.signIn}/code'), isNull);
    });

    test('signed in without a name → profile setup', () {
      expect(sessionRedirect(incomplete, Routes.home), Routes.profileSetup);
      expect(sessionRedirect(incomplete, Routes.profileSetup), isNull);
    });

    test('signed in → leaves gate screens, stays elsewhere', () {
      expect(sessionRedirect(signedIn, Routes.splash), Routes.home);
      expect(sessionRedirect(signedIn, Routes.signIn), Routes.home);
      expect(sessionRedirect(signedIn, Routes.home), isNull);
      expect(sessionRedirect(signedIn, '/settings'), isNull);
    });
  });

  testWidgets('app follows the session from splash to sign-in', (tester) async {
    final container = ProviderContainer(overrides: [
      socketServiceProvider.overrideWithValue(FakeSocketService()),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const ChatApp()),
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    container.read(sessionProvider.notifier).clear();
    await tester.pumpAndSettle();
    expect(find.text('Sign in'), findsOneWidget);

    container.read(sessionProvider.notifier).setSession(accessToken: 'a', me: _me);
    await tester.pumpAndSettle();
    expect(find.text('Chats'), findsOneWidget);
  });

  test('deviceIdFromToken reads the did claim', () {
    // {"sub":"u1","did":"d1"}
    const token = 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ1MSIsImRpZCI6ImQxIn0.sig';
    expect(deviceIdFromToken(token), 'd1');
    expect(deviceIdFromToken('garbage'), isNull);
  });
}
