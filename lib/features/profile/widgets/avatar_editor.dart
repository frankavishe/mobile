import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

/// Up to two initials from [name], e.g. "Frank Kavishe" → "FK".
String initialsOf(String? name) {
  final parts = (name ?? '')
      .trim()
      .split(RegExp(r'\s+'))
      .where((p) => p.isNotEmpty)
      .toList();
  if (parts.isEmpty) return '';
  final first = parts.first.characters.first;
  final last = parts.length > 1 ? parts.last.characters.first : '';
  return (first + last).toUpperCase();
}

/// A round profile photo, or initials (or a person icon) when there is none.
class Avatar extends StatelessWidget {
  const Avatar({super.key, required this.url, required this.name, this.radius = 24});

  final String? url;
  final String? name;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final initials = initialsOf(name);
    final fallback = CircleAvatar(
      radius: radius,
      backgroundColor: scheme.primaryContainer,
      foregroundColor: scheme.onPrimaryContainer,
      child: initials.isEmpty
          ? Icon(Icons.person, size: radius)
          : Text(initials, style: TextStyle(fontSize: radius * 0.7)),
    );
    final u = url;
    if (u == null) return fallback;
    return CachedNetworkImage(
      imageUrl: u,
      imageBuilder: (_, image) => CircleAvatar(radius: radius, backgroundImage: image),
      placeholder: (_, _) => fallback,
      errorWidget: (_, _, _) => fallback,
    );
  }
}

/// Large avatar with a camera badge. Tapping opens Gallery / Camera / Remove.
class AvatarEditor extends StatelessWidget {
  const AvatarEditor({
    super.key,
    required this.url,
    required this.name,
    required this.busy,
    required this.onPick,
    required this.onRemove,
  });

  final String? url;
  final String? name;
  final bool busy;
  final void Function(ImageSource source) onPick;
  final VoidCallback onRemove;

  Future<void> _openSheet(BuildContext context) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              key: const Key('avatar-gallery'),
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose from gallery'),
              onTap: () => Navigator.pop(context, 'gallery'),
            ),
            ListTile(
              key: const Key('avatar-camera'),
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take a photo'),
              onTap: () => Navigator.pop(context, 'camera'),
            ),
            if (url != null)
              ListTile(
                key: const Key('avatar-remove'),
                leading: Icon(Icons.delete_outline,
                    color: Theme.of(context).colorScheme.error),
                title: Text('Remove photo',
                    style: TextStyle(color: Theme.of(context).colorScheme.error)),
                onTap: () => Navigator.pop(context, 'remove'),
              ),
          ],
        ),
      ),
    );
    switch (choice) {
      case 'gallery':
        onPick(ImageSource.gallery);
      case 'camera':
        onPick(ImageSource.camera);
      case 'remove':
        onRemove();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: 'Change profile photo',
      child: InkWell(
        key: const Key('avatar'),
        customBorder: const CircleBorder(),
        onTap: busy ? null : () => _openSheet(context),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Avatar(url: url, name: name, radius: 56),
            if (busy)
              const SizedBox(
                width: 112,
                height: 112,
                child: CircularProgressIndicator(strokeWidth: 3),
              ),
            Positioned(
              right: 0,
              bottom: 0,
              child: CircleAvatar(
                radius: 18,
                backgroundColor: scheme.primary,
                foregroundColor: scheme.onPrimary,
                child: const Icon(Icons.photo_camera, size: 18),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
