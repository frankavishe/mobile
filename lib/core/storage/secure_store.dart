import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Device-local secrets. The refresh token is the only thing that keeps the device signed in,
/// so it lives in the Android Keystore-backed storage, never in plain preferences.
abstract interface class SecureStore {
  Future<String?> readRefreshToken();
  Future<void> writeRefreshToken(String token);

  /// When the address book was last checked for contacts on the app (FR-013: at most hourly).
  Future<DateTime?> readContactsSyncedAt();
  Future<void> writeContactsSyncedAt(DateTime at);

  /// Removes everything this app stored (sign-out, revoked device).
  Future<void> clear();
}

class FlutterSecureStore implements SecureStore {
  FlutterSecureStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  static const _refreshTokenKey = 'refresh_token';
  static const _contactsSyncedAtKey = 'contacts_synced_at';

  final FlutterSecureStorage _storage;

  @override
  Future<String?> readRefreshToken() => _storage.read(key: _refreshTokenKey);

  @override
  Future<void> writeRefreshToken(String token) =>
      _storage.write(key: _refreshTokenKey, value: token);

  @override
  Future<DateTime?> readContactsSyncedAt() async {
    final v = await _storage.read(key: _contactsSyncedAtKey);
    return v == null ? null : DateTime.tryParse(v);
  }

  @override
  Future<void> writeContactsSyncedAt(DateTime at) =>
      _storage.write(key: _contactsSyncedAtKey, value: at.toUtc().toIso8601String());

  @override
  Future<void> clear() => _storage.deleteAll();
}

/// In-memory store for tests.
class MemorySecureStore implements SecureStore {
  MemorySecureStore([this.refreshToken]);

  String? refreshToken;
  DateTime? contactsSyncedAt;

  @override
  Future<String?> readRefreshToken() async => refreshToken;

  @override
  Future<void> writeRefreshToken(String token) async => refreshToken = token;

  @override
  Future<DateTime?> readContactsSyncedAt() async => contactsSyncedAt;

  @override
  Future<void> writeContactsSyncedAt(DateTime at) async => contactsSyncedAt = at;

  @override
  Future<void> clear() async {
    refreshToken = null;
    contactsSyncedAt = null;
  }
}

final secureStoreProvider = Provider<SecureStore>((ref) => FlutterSecureStore());
