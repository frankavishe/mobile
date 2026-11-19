import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/session.dart';
import '../config.dart';
import '../storage/secure_store.dart';
import 'models/models.dart';

/// How [ApiClient] reads and updates the session without depending on Riverpod.
class SessionHooks {
  const SessionHooks({
    required this.accessToken,
    required this.onAccessToken,
    required this.onSessionLost,
  });

  /// Current access token, or null.
  final String? Function() accessToken;

  /// A refresh produced a new access token.
  final void Function(String token) onAccessToken;

  /// The server rejected the refresh token; storage is already wiped.
  final void Function() onSessionLost;
}

const _retriedKey = 'chat.retried';

/// REST client for `api/contracts/openapi.yaml`.
///
/// Adds the bearer token, and on a 401 from a non-`/auth/` route refreshes once and retries.
/// Concurrent 401s share one refresh: the server rotates the refresh token and treats reuse
/// as theft (it would revoke this device).
class ApiClient {
  ApiClient({
    required this._store,
    required this._hooks,
    String? baseUrl,
    HttpClientAdapter? adapter,
  }) {
    final options = BaseOptions(
      baseUrl: baseUrl ?? AppConfig.apiBaseUrl,
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 20),
      contentType: Headers.jsonContentType,
    );
    // Refresh calls go through a separate instance so they never hit the retry interceptor.
    _raw = Dio(options);
    dio = Dio(options);
    if (adapter != null) {
      _raw.httpClientAdapter = adapter;
      dio.httpClientAdapter = adapter;
    }
    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (o, h) {
        final token = _hooks.accessToken();
        if (token != null && !_isAuthRoute(o)) {
          o.headers['Authorization'] = 'Bearer $token';
        }
        h.next(o);
      },
      onError: _onError,
    ));
  }

  final SecureStore _store;
  final SessionHooks _hooks;
  late final Dio _raw;

  /// Exposed for tests and for uploads that need custom options.
  late final Dio dio;

  Future<String?>? _refreshInFlight;

  static bool _isAuthRoute(RequestOptions o) => o.path.startsWith('/auth/');

  Future<void> _onError(DioException err, ErrorInterceptorHandler h) async {
    final o = err.requestOptions;
    if (err.response?.statusCode != 401 ||
        _isAuthRoute(o) ||
        o.extra[_retriedKey] == true) {
      return h.next(err);
    }
    String? token;
    try {
      token = await refresh();
    } on ApiError {
      token = null; // Network failure: report the original 401.
    }
    if (token == null) return h.next(err);
    try {
      o.extra[_retriedKey] = true;
      o.headers['Authorization'] = 'Bearer $token';
      h.resolve(await dio.fetch<dynamic>(o));
    } on DioException catch (e) {
      h.next(e);
    }
  }

  /// Exchanges the stored refresh token for a new access token.
  ///
  /// Returns null when there is no session (no token, or the server rejected it; storage is
  /// then wiped and [SessionHooks.onSessionLost] is called). Throws [ApiError] with
  /// [ApiErrorCode.network] when the server could not be reached; the session is kept.
  Future<String?> refresh() {
    return _refreshInFlight ??= _doRefresh().whenComplete(() {
      _refreshInFlight = null;
    });
  }

  Future<String?> _doRefresh() async {
    final refreshToken = await _store.readRefreshToken();
    if (refreshToken == null) return null;
    try {
      final res = await _raw.post<Map<String, dynamic>>(
        '/auth/refresh',
        data: {'refreshToken': refreshToken},
      );
      final pair = TokenPair.fromJson(res.data!);
      if (pair.refreshToken != null) {
        await _store.writeRefreshToken(pair.refreshToken!);
      }
      _hooks.onAccessToken(pair.accessToken);
      return pair.accessToken;
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status == 401) {
        await _store.clear();
        _hooks.onSessionLost();
        return null;
      }
      throw _toApiError(e);
    }
  }

  // ---- auth ----

  Future<RequestCodeResponse> requestCode(String phone) => _call(() async {
        final res = await dio.post<Map<String, dynamic>>(
          '/auth/request-code',
          data: {'phone': phone},
        );
        return RequestCodeResponse.fromJson(res.data!);
      });

  /// Verifies the code as an Android device and stores the refresh token.
  Future<AuthResult> verify({
    required String phone,
    required String code,
    required String deviceName,
  }) =>
      _call(() async {
        final res = await dio.post<Map<String, dynamic>>(
          '/auth/verify',
          data: {
            'phone': phone,
            'code': code,
            'deviceType': DeviceType.android.toJson(),
            'deviceName': deviceName,
          },
        );
        final result = AuthResult.fromJson(res.data!);
        if (result.refreshToken != null) {
          await _store.writeRefreshToken(result.refreshToken!);
        }
        return result;
      });

  /// Signs this device out on the server (best effort) and wipes local storage.
  Future<void> signOut() async {
    final token = _hooks.accessToken();
    try {
      if (token != null) {
        await dio.post<void>(
          '/auth/sign-out',
          options: Options(headers: {'Authorization': 'Bearer $token'}),
        );
      }
    } on DioException {
      // Already revoked or offline: the local wipe below is what matters.
    } finally {
      await _store.clear();
    }
  }

  // ---- devices ----

  Future<List<Device>> listDevices() => _call(() async {
        final res = await dio.get<List<dynamic>>('/devices');
        return res.data!
            .map((j) => Device.fromJson(j as Map<String, dynamic>))
            .toList();
      });

  Future<void> revokeDevice(String deviceId) =>
      _call(() => dio.delete<void>('/devices/$deviceId'));

  // ---- profile ----

  Future<Me> getMe() => _call(() async {
        final res = await dio.get<Map<String, dynamic>>('/me');
        return Me.fromJson(res.data!);
      });

  Future<Me> updateMe({String? displayName, String? about}) => _call(() async {
        final res = await dio.patch<Map<String, dynamic>>('/me', data: {
          'displayName': ?displayName,
          'about': ?about,
        });
        return Me.fromJson(res.data!);
      });

  /// Uploads a JPEG, PNG or WebP (max 5 MB).
  Future<Me> uploadAvatar(String filePath, {String? contentType}) =>
      _call(() async {
        final form = FormData.fromMap({
          'file': await MultipartFile.fromFile(
            filePath,
            contentType:
                contentType != null ? DioMediaType.parse(contentType) : null,
          ),
        });
        final res = await dio.put<Map<String, dynamic>>('/me/avatar', data: form);
        return Me.fromJson(res.data!);
      });

  Future<Me> deleteAvatar() => _call(() async {
        final res = await dio.delete<Map<String, dynamic>>('/me/avatar');
        return Me.fromJson(res.data!);
      });

  // ---- contacts ----

  /// Up to 1,000 E.164 numbers; returns only the ones with accounts.
  Future<List<PublicUser>> discoverContacts(List<String> phones) =>
      _call(() async {
        final res = await dio.post<List<dynamic>>(
          '/contacts/discover',
          data: {'phones': phones},
        );
        return _users(res.data!);
      });

  Future<List<PublicUser>> listContacts() => _call(() async {
        final res = await dio.get<List<dynamic>>('/contacts');
        return _users(res.data!);
      });

  /// Throws [ApiError] with [ApiErrorCode.userNotFound] when the number is not on the app.
  Future<PublicUser> lookupUser(String phone) => _call(() async {
        final res = await dio.get<Map<String, dynamic>>(
          '/users/lookup',
          queryParameters: {'phone': phone},
        );
        return PublicUser.fromJson(res.data!);
      });

  // ---- keys ----

  /// `PUT /keys`. The first upload (or a new identity key) must include the signed prekey.
  Future<void> uploadKeys(UploadKeysBody body) =>
      _call(() => dio.put<void>('/keys', data: body.toJson()));

  /// Unused one-time prekeys the server still holds for this device.
  Future<int> getKeyCount() => _call(() async {
        final res = await dio.get<Map<String, dynamic>>('/keys/count');
        return res.data!['count'] as int;
      });

  /// Max `deviceId` filters per `GET /users/{id}/keys`.
  static const keysDeviceFilterMax = 5;

  /// Prekey bundles for [userId]'s devices (consumes one one-time prekey each). With
  /// [deviceIds], only those devices; more than [keysDeviceFilterMax] are fetched in chunks.
  Future<UserKeys> getUserKeys(String userId, {List<String>? deviceIds}) =>
      _call(() async {
        Future<UserKeys> one(List<String>? ids) async {
          final res = await dio.get<Map<String, dynamic>>(
            '/users/$userId/keys',
            queryParameters: {'deviceId': ?ids},
            options: Options(listFormat: ListFormat.multi),
          );
          return UserKeys.fromJson(res.data!);
        }

        if (deviceIds == null) return one(null);
        final devices = <DeviceBundle>[];
        for (var i = 0; i < deviceIds.length; i += keysDeviceFilterMax) {
          final end = i + keysDeviceFilterMax;
          final chunk =
              deviceIds.sublist(i, end > deviceIds.length ? deviceIds.length : end);
          devices.addAll((await one(chunk)).devices);
        }
        return UserKeys(userId: userId, devices: devices);
      });

  // ---- conversations ----

  Future<List<Conversation>> listConversations() => _call(() async {
        final res = await dio.get<List<dynamic>>('/conversations');
        return [
          for (final j in res.data!) Conversation.fromJson(j as Map<String, dynamic>),
        ];
      });

  Future<Conversation> getConversation(String id) => _call(() async {
        final res = await dio.get<Map<String, dynamic>>('/conversations/$id');
        return Conversation.fromJson(res.data!);
      });

  /// Direct chats are idempotent: the existing one is returned.
  Future<Conversation> createConversation(CreateConversationBody body) =>
      _call(() async {
        final res =
            await dio.post<Map<String, dynamic>>('/conversations', data: body.toJson());
        return Conversation.fromJson(res.data!);
      });

  // ---- messages ----

  /// Returns the server timestamp. A stale device list throws [ApiError] with
  /// [ApiErrorCode.deviceMismatch]; read it with [deviceMismatchOf].
  Future<DateTime> sendMessage(SendMessageBody body) => _call(() async {
        final res =
            await dio.post<Map<String, dynamic>>('/messages', data: body.toJson());
        return DateTime.parse(res.data!['serverTimestamp'] as String);
      });

  /// Envelopes waiting for this device, oldest first.
  Future<List<Envelope>> listEnvelopes({int limit = 100}) => _call(() async {
        final res = await dio.get<List<dynamic>>(
          '/envelopes',
          queryParameters: {'limit': limit},
        );
        return [for (final j in res.data!) Envelope.fromJson(j as Map<String, dynamic>)];
      });

  /// Max ids per `POST /envelopes/ack`.
  static const ackBatchMax = 500;

  Future<void> ackEnvelopes(List<String> ids) => _call(() async {
        for (var i = 0; i < ids.length; i += ackBatchMax) {
          final end = i + ackBatchMax;
          await dio.post<void>(
            '/envelopes/ack',
            data: {'ids': ids.sublist(i, end > ids.length ? ids.length : end)},
          );
        }
      });

  static List<PublicUser> _users(List<dynamic> data) =>
      data.map((j) => PublicUser.fromJson(j as Map<String, dynamic>)).toList();

  // ---- errors ----

  Future<T> _call<T>(Future<T> Function() fn) async {
    try {
      return await fn();
    } on DioException catch (e) {
      throw _toApiError(e);
    }
  }

  static ApiError _toApiError(DioException e) {
    final res = e.response;
    if (res == null) return const ApiError.network();
    final retryAfter = int.tryParse(res.headers.value('retry-after') ?? '');
    final data = res.data;
    if (data is Map<String, dynamic>) {
      return ApiError.fromJson(res.statusCode ?? 0, data, retryAfter: retryAfter);
    }
    return ApiError(
      status: res.statusCode ?? 0,
      code: ApiErrorCode.unknown,
      message: 'Request failed (${res.statusCode})',
      retryAfter: retryAfter,
    );
  }
}

final apiClientProvider = Provider<ApiClient>((ref) {
  return ApiClient(
    store: ref.watch(secureStoreProvider),
    hooks: SessionHooks(
      accessToken: () => ref.read(sessionProvider).accessToken,
      onAccessToken: (t) => ref.read(sessionProvider.notifier).setAccessToken(t),
      onSessionLost: () {
        final wasSignedIn = ref.read(sessionProvider).isSignedIn;
        ref
            .read(sessionProvider.notifier)
            .clear(wasSignedIn ? SignOutReason.expired : null);
      },
    ),
  );
});
