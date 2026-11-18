import 'dart:async';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';
import '../../core/api/models/models.dart';
import '../../core/auth/session.dart';
import '../../core/realtime/socket_service.dart';
import '../../core/storage/secure_store.dart';

/// Name shown in the device list, e.g. "Samsung SM-A546E".
final deviceNameProvider = Provider<Future<String> Function()>((ref) {
  return () async {
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      final maker = info.manufacturer.isEmpty
          ? ''
          : '${info.manufacturer[0].toUpperCase()}${info.manufacturer.substring(1)} ';
      final name = '$maker${info.model}'.trim();
      return name.isEmpty ? 'Android' : name;
    } catch (_) {
      return 'Android';
    }
  };
});

/// State of the phone → code sign-in flow.
@immutable
class SignInState {
  const SignInState({
    this.phone,
    this.resendAfter = 0,
    this.expiresIn = 0,
    this.sentAt,
    this.busy = false,
    this.error,
  });

  /// E.164 number the code was sent to.
  final String? phone;

  /// Seconds after [sentAt] before another code may be requested.
  final int resendAfter;

  /// Seconds after [sentAt] before the code expires.
  final int expiresIn;
  final DateTime? sentAt;
  final bool busy;
  final ApiError? error;

  SignInState copyWith({
    String? phone,
    int? resendAfter,
    int? expiresIn,
    DateTime? sentAt,
    bool? busy,
    ApiError? Function()? error,
  }) =>
      SignInState(
        phone: phone ?? this.phone,
        resendAfter: resendAfter ?? this.resendAfter,
        expiresIn: expiresIn ?? this.expiresIn,
        sentAt: sentAt ?? this.sentAt,
        busy: busy ?? this.busy,
        error: error != null ? error() : this.error,
      );
}

/// Drives sign-in: request a code, verify it, and sign out.
class AuthController extends Notifier<SignInState> {
  @override
  SignInState build() => const SignInState();

  ApiClient get _api => ref.read(apiClientProvider);

  /// Sends a code to [e164]. Returns true when the code was sent.
  Future<bool> requestCode(String e164) async {
    if (state.busy) return false;
    state = state.copyWith(busy: true, error: () => null);
    try {
      final res = await _api.requestCode(e164);
      state = SignInState(
        phone: e164,
        resendAfter: res.resendAfter,
        expiresIn: res.expiresIn,
        sentAt: DateTime.now(),
      );
      return true;
    } on ApiError catch (e) {
      state = state.copyWith(busy: false, error: () => e);
      return false;
    }
  }

  /// Sends a new code to the same number.
  Future<bool> resend() async {
    final phone = state.phone;
    if (phone == null) return false;
    return requestCode(phone);
  }

  /// Verifies [code]. On success the session is set and the router leaves the sign-in screens.
  Future<bool> verify(String code) async {
    final phone = state.phone;
    if (phone == null || state.busy) return false;
    state = state.copyWith(busy: true, error: () => null);
    try {
      final deviceName = await ref.read(deviceNameProvider)();
      final result = await _api.verify(
        phone: phone,
        code: code,
        deviceName: deviceName,
      );
      ref.read(sessionProvider.notifier).setSession(
            accessToken: result.accessToken,
            me: result.user,
            deviceId: result.device.id,
          );
      state = const SignInState();
      return true;
    } on ApiError catch (e) {
      state = state.copyWith(busy: false, error: () => e);
      return false;
    }
  }

  void clearError() => state = state.copyWith(error: () => null);

  /// Signs this device out on the server (best effort) and locally. No reason is recorded:
  /// the sign-in screen only explains sign-outs the user did not do here.
  Future<void> signOut() async {
    await _api.signOut();
    ref.read(sessionProvider.notifier).clear();
  }
}

final authControllerProvider =
    NotifierProvider<AuthController, SignInState>(AuthController.new);

/// Keeps the realtime connection in step with the session: connects while signed in and
/// applies `device:revoked` (wipe storage, back to sign-in) and `profile:updated`.
final sessionLifecycleProvider = Provider<void>((ref) {
  final socket = ref.watch(socketServiceProvider);
  final subs = <StreamSubscription<Object>>[];

  void stop() {
    for (final s in subs) {
      s.cancel();
    }
    subs.clear();
    socket.disconnect();
  }

  void start() {
    if (subs.isNotEmpty) return;
    subs
      ..add(socket.deviceRevoked.listen((e) async {
        await ref.read(secureStoreProvider).clear();
        ref
            .read(sessionProvider.notifier)
            .clear(SignOutReason.fromRevoked(e.reason));
      }))
      ..add(socket.profileUpdated.listen(
        ref.read(sessionProvider.notifier).applyProfileUpdate,
      ));
    socket.connect();
  }

  ref.listen<bool>(
    sessionProvider.select((s) => s.isSignedIn),
    (_, signedIn) => signedIn ? start() : stop(),
    fireImmediately: true,
  );
  ref.onDispose(stop);
});
