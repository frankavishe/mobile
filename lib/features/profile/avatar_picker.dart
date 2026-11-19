import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';

/// Picks a photo and lets the user crop it square. Returns the cropped JPEG's path, or null
/// when the user cancelled. Tests override [avatarPickerProvider].
typedef AvatarPicker = Future<String?> Function(ImageSource source);

final avatarPickerProvider = Provider<AvatarPicker>((ref) {
  return (source) async {
    final picked = await ImagePicker().pickImage(
      source: source,
      maxWidth: 2048,
      maxHeight: 2048,
      imageQuality: 92,
    );
    if (picked == null) return null;
    final cropped = await ImageCropper().cropImage(
      sourcePath: picked.path,
      aspectRatio: const CropAspectRatio(ratioX: 1, ratioY: 1),
      // The server re-encodes to 640 px WebP; keep the upload well under 5 MB.
      maxWidth: 1080,
      maxHeight: 1080,
      compressFormat: ImageCompressFormat.jpg,
      compressQuality: 90,
      uiSettings: [
        AndroidUiSettings(
          toolbarTitle: 'Crop photo',
          lockAspectRatio: true,
          hideBottomControls: false,
          cropStyle: CropStyle.circle,
          aspectRatioPresets: [CropAspectRatioPreset.square],
          toolbarColor: const Color(0xFF151A2D),
          toolbarWidgetColor: Colors.white,
          activeControlsWidgetColor: const Color(0xFF3550D6),
        ),
      ],
    );
    return cropped?.path;
  };
});
