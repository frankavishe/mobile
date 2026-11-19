import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import 'avatar_picker.dart';
import 'profile_controller.dart';

/// Picks, crops and uploads a photo. Upload errors land in [ProfileState.error]; a failure to
/// open the camera or gallery (e.g. permission denied) is shown as a snack bar.
Future<void> pickAndUploadAvatar(
  BuildContext context,
  WidgetRef ref,
  ImageSource source,
) async {
  final messenger = ScaffoldMessenger.of(context);
  String? path;
  try {
    path = await ref.read(avatarPickerProvider)(source);
  } on PlatformException {
    messenger.showSnackBar(SnackBar(
      content: Text(source == ImageSource.camera
          ? "Couldn't open the camera. Check the app's permissions."
          : "Couldn't open your photos. Check the app's permissions."),
    ));
    return;
  }
  if (path == null) return;
  await ref.read(profileControllerProvider.notifier).setAvatar(path);
}
