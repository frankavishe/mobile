import 'package:chat_app/app.dart';
import 'package:chat_app/core/api/api_client.dart';
import 'package:chat_app/core/api/models/models.dart';
import 'package:chat_app/core/auth/session.dart';
import 'package:chat_app/core/realtime/socket_service.dart';
import 'package:chat_app/core/storage/secure_store.dart';
import 'package:chat_app/features/home/home_screen.dart';
import 'package:chat_app/features/profile/avatar_picker.dart';
import 'package:chat_app/features/profile/profile_controller.dart';
import 'package:chat_app/features/profile/profile_edit_screen.dart';
import 'package:chat_app/features/profile/profile_setup_screen.dart';
import 'package:chat_app/features/profile/widgets/avatar_editor.dart';
import 'package:chat_app/features/settings/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mocktail/mocktail.dart';

import 'support/fakes.dart';

const _phone = '+255712345678';

const _newUser = Me(
  id: 'u1',
  phone: _phone,
  displayName: null,
  about: '',
  avatarUrl: null,
  profileComplete: false,
);

const _frank = Me(
  id: 'u1',
  phone: _phone,
  displayName: 'Frank',
  about: 'Hi there',
  avatarUrl: null,
  profileComplete: true,
);

ApiError _err(ApiErrorCode code, {int status = 400}) =>
    ApiError(status: status, code: code, message: code.wire);

void main() {
  late MockApiClient api;
  late FakeSocketService socket;
  late ProviderContainer container;
  final picked = <ImageSource>[];
  String? pickResult;

  setUp(() {
    api = MockApiClient();
    socket = FakeSocketService();
    picked.clear();
    pickResult = '/tmp/cropped.jpg';
    when(() => api.signOut()).thenAnswer((_) async {});
  });

  /// Boots the real app signed in as [me].
  Future<void> boot(WidgetTester tester, Me me) async {
    container = ProviderContainer(overrides: [
      apiClientProvider.overrideWithValue(api),
      socketServiceProvider.overrideWithValue(socket),
      secureStoreProvider.overrideWithValue(MemorySecureStore()),
      avatarPickerProvider.overrideWithValue((source) async {
        picked.add(source);
        return pickResult;
      }),
    ]);
    addTearDown(container.dispose);
    container.read(sessionProvider.notifier).setSession(accessToken: 'a', me: me);
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const ChatApp()),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openEdit(WidgetTester tester) async {
    await boot(tester, _frank);
    await tester.tap(find.byKey(const Key('home-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
    await tester.tap(find.byKey(const Key('settings-profile')));
    await tester.pumpAndSettle();
    expect(find.byType(ProfileEditScreen), findsOneWidget);
  }

  Widget button(WidgetTester tester, String key) =>
      tester.widget(find.byKey(Key(key)));

  group('validation', () {
    test('name is required and at most 25 characters after trimming', () {
      expect(nameError('   '), isNotNull);
      expect(nameError('A'), isNull);
      expect(nameError('  ${'a' * 25}  '), isNull);
      expect(nameError('a' * 26), isNotNull);
    });

    test('about is at most 140 characters', () {
      expect(aboutError(''), isNull);
      expect(aboutError('a' * 140), isNull);
      expect(aboutError('a' * 141), isNotNull);
    });

    test('initials', () {
      expect(initialsOf('frank kavishe'), 'FK');
      expect(initialsOf('Frank'), 'F');
      expect(initialsOf(null), '');
    });
  });

  group('profile setup', () {
    testWidgets('an incomplete profile lands on setup; Next needs a valid name',
        (tester) async {
      await boot(tester, _newUser);
      expect(find.byType(ProfileSetupScreen), findsOneWidget);
      FilledButton next() => button(tester, 'next') as FilledButton;
      expect(next().onPressed, isNull);

      await tester.enterText(find.byKey(const Key('name')), '   ');
      await tester.pump();
      expect(next().onPressed, isNull);

      await tester.enterText(find.byKey(const Key('name')), 'a' * 26);
      await tester.pump();
      expect(next().onPressed, isNull);
      expect(find.text('Use 25 characters or fewer.'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('name')), 'Frank');
      await tester.pump();
      expect(next().onPressed, isNotNull);
    });

    testWidgets('saving the name completes the profile and goes home', (tester) async {
      when(() => api.updateMe(displayName: any(named: 'displayName'), about: any(named: 'about')))
          .thenAnswer((_) async => _frank);
      await boot(tester, _newUser);

      await tester.enterText(find.byKey(const Key('name')), '  Frank ');
      await tester.pump();
      await tester.tap(find.byKey(const Key('next')));
      await tester.pumpAndSettle();

      verify(() => api.updateMe(displayName: 'Frank', about: null)).called(1);
      expect(container.read(sessionProvider).me!.profileComplete, isTrue);
      expect(find.byType(HomeScreen), findsOneWidget);
    });

    testWidgets('an API error is shown and the user stays on setup', (tester) async {
      when(() => api.updateMe(displayName: any(named: 'displayName'), about: any(named: 'about')))
          .thenThrow(const ApiError.network());
      await boot(tester, _newUser);

      await tester.enterText(find.byKey(const Key('name')), 'Frank');
      await tester.pump();
      await tester.tap(find.byKey(const Key('next')));
      await tester.pumpAndSettle();

      expect(find.text("Can't reach the server. Check your connection."), findsOneWidget);
      expect(find.byType(ProfileSetupScreen), findsOneWidget);
    });

    testWidgets('picking a photo uploads the cropped file', (tester) async {
      when(() => api.uploadAvatar(any(), contentType: any(named: 'contentType')))
          .thenAnswer((_) async => _newUser);
      await boot(tester, _newUser);

      await tester.tap(find.byKey(const Key('avatar')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('avatar-remove')), findsNothing);
      await tester.tap(find.byKey(const Key('avatar-gallery')));
      await tester.pumpAndSettle();

      expect(picked, [ImageSource.gallery]);
      verify(() => api.uploadAvatar('/tmp/cropped.jpg', contentType: 'image/jpeg'))
          .called(1);
    });

    testWidgets('a cancelled pick uploads nothing', (tester) async {
      pickResult = null;
      await boot(tester, _newUser);

      await tester.tap(find.byKey(const Key('avatar')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('avatar-camera')));
      await tester.pumpAndSettle();

      expect(picked, [ImageSource.camera]);
      verifyNever(() => api.uploadAvatar(any(), contentType: any(named: 'contentType')));
    });

    testWidgets('a rejected photo shows the server reason', (tester) async {
      when(() => api.uploadAvatar(any(), contentType: any(named: 'contentType')))
          .thenThrow(_err(ApiErrorCode.fileTooLarge, status: 413));
      await boot(tester, _newUser);

      await tester.tap(find.byKey(const Key('avatar')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('avatar-gallery')));
      await tester.pumpAndSettle();

      expect(find.text('That photo is too large. The limit is 5 MB.'), findsOneWidget);
    });
  });

  group('profile edit', () {
    testWidgets('shows the saved profile; Save is enabled only after a change',
        (tester) async {
      await openEdit(tester);
      TextButton save() => button(tester, 'save') as TextButton;

      expect(find.widgetWithText(TextField, 'Frank'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Hi there'), findsOneWidget);
      expect(find.text(_phone), findsOneWidget);
      expect(save().onPressed, isNull);

      await tester.enterText(find.byKey(const Key('about')), 'a' * 141);
      await tester.pump();
      expect(save().onPressed, isNull);
      expect(find.text('Use 140 characters or fewer.'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('name')), '');
      await tester.enterText(find.byKey(const Key('about')), 'Busy');
      await tester.pump();
      expect(save().onPressed, isNull);
      expect(find.text('Enter your name.'), findsOneWidget);
    });

    testWidgets('saves only the changed field', (tester) async {
      when(() => api.updateMe(displayName: any(named: 'displayName'), about: any(named: 'about')))
          .thenAnswer((_) async => _frank.copyWith(about: 'Busy'));
      await openEdit(tester);

      await tester.enterText(find.byKey(const Key('about')), 'Busy ');
      await tester.pump();
      await tester.tap(find.byKey(const Key('save')));
      await tester.pumpAndSettle();

      verify(() => api.updateMe(displayName: null, about: 'Busy')).called(1);
      expect(container.read(sessionProvider).me!.about, 'Busy');
      expect(find.text('Profile saved'), findsOneWidget);
      expect((button(tester, 'save') as TextButton).onPressed, isNull);
    });

    testWidgets('profile:updated from another device refreshes untouched fields',
        (tester) async {
      await openEdit(tester);

      // The user is editing "about"; the name was changed elsewhere.
      await tester.enterText(find.byKey(const Key('about')), 'Typing…');
      await tester.pump();
      socket.profile.add(const ProfileUpdatedEvent(
        id: 'u1',
        displayName: 'Frankie',
        about: 'Changed on web',
        avatarUrl: null,
      ));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(TextField, 'Frankie'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Typing…'), findsOneWidget);
    });

    testWidgets('remove photo is offered when there is one', (tester) async {
      const withPhoto = Me(
        id: 'u1',
        phone: _phone,
        displayName: 'Frank',
        about: '',
        avatarUrl: 'http://localhost:3000/v1/avatars/x.webp',
        profileComplete: true,
      );
      when(() => api.deleteAvatar()).thenAnswer((_) async => _frank);
      await boot(tester, withPhoto);
      container.read(sessionProvider.notifier).setMe(withPhoto);
      await tester.tap(find.byKey(const Key('home-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('settings-profile')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('avatar')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('avatar-remove')));
      await tester.pumpAndSettle();

      verify(() => api.deleteAvatar()).called(1);
      expect(container.read(sessionProvider).me!.avatarUrl, isNull);
    });
  });
}
