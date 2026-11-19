import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';
import '../../core/api/models/models.dart';
import '../../core/auth/session.dart';

/// Same limits as `PATCH /me` (`api/src/users/me.controller.ts`).
const maxNameLength = 25;
const maxAboutLength = 140;

/// Why [name] can't be saved, or null when it is fine. Checked after trimming.
String? nameError(String name) {
  final n = name.trim();
  if (n.isEmpty) return 'Enter your name.';
  if (n.length > maxNameLength) return 'Use $maxNameLength characters or fewer.';
  return null;
}

String? aboutError(String about) => about.trim().length > maxAboutLength
    ? 'Use $maxAboutLength characters or fewer.'
    : null;

@immutable
class ProfileState {
  const ProfileState({this.saving = false, this.uploading = false, this.error});

  /// Name/about are being saved.
  final bool saving;

  /// The photo is being uploaded or removed.
  final bool uploading;
  final ApiError? error;

  bool get busy => saving || uploading;
}

/// Saves the signed-in user's profile and photo, and puts the result in the session.
///
/// Other devices learn about the change from the server's `profile:updated` event, which
/// [SessionNotifier.applyProfileUpdate] applies.
class ProfileController extends Notifier<ProfileState> {
  @override
  ProfileState build() => const ProfileState();

  ApiClient get _api => ref.read(apiClientProvider);

  Future<bool> _run(
    Future<Me> Function() call, {
    bool upload = false,
  }) async {
    if (state.busy) return false;
    state = ProfileState(saving: !upload, uploading: upload);
    try {
      final me = await call();
      ref.read(sessionProvider.notifier).setMe(me);
      state = const ProfileState();
      return true;
    } on ApiError catch (e) {
      state = ProfileState(error: e);
      return false;
    }
  }

  /// Sends only what is given. Returns true on success.
  Future<bool> save({String? name, String? about}) {
    if (name != null && nameError(name) != null) return Future.value(false);
    if (about != null && aboutError(about) != null) return Future.value(false);
    return _run(() => _api.updateMe(
          displayName: name?.trim(),
          about: about?.trim(),
        ));
  }

  Future<bool> setAvatar(String filePath) => _run(
        () => _api.uploadAvatar(filePath, contentType: _contentType(filePath)),
        upload: true,
      );

  Future<bool> removeAvatar() => _run(_api.deleteAvatar, upload: true);

  void clearError() => state = const ProfileState();

  static String? _contentType(String path) {
    final p = path.toLowerCase();
    if (p.endsWith('.png')) return 'image/png';
    if (p.endsWith('.webp')) return 'image/webp';
    if (p.endsWith('.jpg') || p.endsWith('.jpeg')) return 'image/jpeg';
    return null;
  }
}

final profileControllerProvider =
    NotifierProvider<ProfileController, ProfileState>(ProfileController.new);
