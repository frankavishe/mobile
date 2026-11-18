import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../api/models/models.dart';

/// - [unknown]: app just started; a session may still be restored from the refresh token.
/// - [signedIn]: we hold an access token and the user's profile.
/// - [signedOut]: no session (never signed in, signed out, or revoked).
enum SessionStatus { unknown, signedIn, signedOut }

/// Why the last session ended, shown once on the sign-in screen.
enum SignOutReason {
  signedOut,
  replaced,
  evicted,
  tokenReuse,
  inactive,

  /// The refresh token was rejected (expired or revoked while offline).
  expired;

  static SignOutReason fromRevoked(DeviceRevokedReason r) => switch (r) {
        DeviceRevokedReason.signedOut => signedOut,
        DeviceRevokedReason.replaced => replaced,
        DeviceRevokedReason.evicted => evicted,
        DeviceRevokedReason.tokenReuse => tokenReuse,
        DeviceRevokedReason.inactive => inactive,
      };
}

@immutable
class SessionState {
  const SessionState({
    required this.status,
    this.accessToken,
    this.deviceId,
    this.me,
    this.signOutReason,
    this.restoreFailed = false,
  });

  const SessionState.unknown() : this(status: SessionStatus.unknown);

  final SessionStatus status;

  /// Kept in memory only; the refresh token is in [SecureStore].
  final String? accessToken;
  final String? deviceId;
  final Me? me;
  final SignOutReason? signOutReason;

  /// True when restoring failed because the server could not be reached.
  final bool restoreFailed;

  bool get isSignedIn => status == SessionStatus.signedIn;
}

/// Reads the `did` claim; the token is not verified here (the server does that).
String? deviceIdFromToken(String token) {
  try {
    final parts = token.split('.');
    if (parts.length < 2) return null;
    final payload = utf8.decode(base64Url.decode(base64Url.normalize(parts[1])));
    final did = (jsonDecode(payload) as Map<String, dynamic>)['did'];
    return did is String ? did : null;
  } catch (_) {
    return null;
  }
}

class SessionNotifier extends Notifier<SessionState> {
  @override
  SessionState build() => const SessionState.unknown();

  void setSession({
    required String accessToken,
    required Me me,
    String? deviceId,
  }) {
    state = SessionState(
      status: SessionStatus.signedIn,
      accessToken: accessToken,
      deviceId: deviceId ?? deviceIdFromToken(accessToken),
      me: me,
    );
  }

  /// Called after a token refresh. Keeps the status: during restore the profile is not loaded yet.
  void setAccessToken(String token) {
    state = SessionState(
      status: state.status,
      accessToken: token,
      deviceId: deviceIdFromToken(token) ?? state.deviceId,
      me: state.me,
    );
  }

  void setMe(Me me) {
    if (state.status != SessionStatus.signedIn) return;
    state = SessionState(
      status: SessionStatus.signedIn,
      accessToken: state.accessToken,
      deviceId: state.deviceId,
      me: me,
    );
  }

  void applyProfileUpdate(ProfileUpdatedEvent e) {
    final me = state.me;
    if (me == null || me.id != e.id) return;
    setMe(me.copyWith(
      displayName: e.displayName,
      about: e.about,
      avatarUrl: () => e.avatarUrl,
      avatarThumbUrl: () => e.avatarThumbUrl,
    ));
  }

  /// Ends the session in memory. Wiping storage is the caller's job (see [ApiClient]).
  void clear([SignOutReason? reason]) {
    state = SessionState(status: SessionStatus.signedOut, signOutReason: reason);
  }

  /// Returns the sign-out reason once, then forgets it.
  SignOutReason? consumeSignOutReason() {
    final reason = state.signOutReason;
    if (reason != null) {
      state = const SessionState(status: SessionStatus.signedOut);
    }
    return reason;
  }

  /// Restores the session on app start: refresh token → access token → profile.
  Future<void> restore() async {
    state = const SessionState.unknown();
    final api = ref.read(apiClientProvider);
    try {
      final token = await api.refresh();
      if (token == null) {
        clear();
        return;
      }
      final me = await api.getMe();
      setSession(accessToken: token, me: me);
    } on ApiError catch (e) {
      if (e.code == ApiErrorCode.network) {
        // Keep the stored token; the splash screen offers a retry.
        state = const SessionState(
          status: SessionStatus.unknown,
          restoreFailed: true,
        );
      } else {
        clear();
      }
    }
  }
}

final sessionProvider =
    NotifierProvider<SessionNotifier, SessionState>(SessionNotifier.new);
