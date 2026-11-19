import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/error_messages.dart';
import '../../core/api/models/models.dart';
import '../../core/auth/session.dart';
import 'avatar_actions.dart';
import 'profile_controller.dart';
import 'widgets/avatar_editor.dart';

/// Settings → Profile: change photo, name and about.
///
/// When the profile changes on another device (`profile:updated`), fields the user hasn't
/// touched here pick up the new values.
class ProfileEditScreen extends ConsumerStatefulWidget {
  const ProfileEditScreen({super.key});

  @override
  ConsumerState<ProfileEditScreen> createState() => _ProfileEditScreenState();
}

class _ProfileEditScreenState extends ConsumerState<ProfileEditScreen> {
  final _name = TextEditingController();
  final _about = TextEditingController();

  /// The saved values the fields started from.
  String _baseName = '';
  String _baseAbout = '';

  @override
  void initState() {
    super.initState();
    final me = ref.read(sessionProvider).me;
    _reset(me, force: true);
    _name.addListener(() => setState(() {}));
    _about.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _name.dispose();
    _about.dispose();
    super.dispose();
  }

  /// Takes the saved values from [me]; a field the user has edited keeps their text unless
  /// [force] is set.
  void _reset(Me? me, {bool force = false}) {
    final name = me?.displayName ?? '';
    final about = me?.about ?? '';
    if (force || _name.text == _baseName) _name.text = name;
    if (force || _about.text == _baseAbout) _about.text = about;
    _baseName = name;
    _baseAbout = about;
  }

  bool get _nameChanged => _name.text.trim() != _baseName;
  bool get _aboutChanged => _about.text.trim() != _baseAbout;

  Future<void> _save() async {
    FocusScope.of(context).unfocus();
    final ok = await ref.read(profileControllerProvider.notifier).save(
          name: _nameChanged ? _name.text : null,
          about: _aboutChanged ? _about.text : null,
        );
    if (ok && mounted) {
      _reset(ref.read(sessionProvider).me, force: true);
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Profile saved')));
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<Me?>(sessionProvider.select((s) => s.me), (_, me) {
      if (me != null) setState(() => _reset(me));
    });
    final me = ref.watch(sessionProvider.select((s) => s.me));
    final profile = ref.watch(profileControllerProvider);
    final theme = Theme.of(context);

    final nameErr = _name.text.trim().isEmpty || _name.text.trim().length > maxNameLength
        ? nameError(_name.text)
        : null;
    final aboutErr = aboutError(_about.text);
    final canSave = (_nameChanged || _aboutChanged) &&
        nameErr == null &&
        aboutErr == null &&
        !profile.busy;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Profile'),
        actions: [
          TextButton(
            key: const Key('save'),
            onPressed: canSave ? _save : null,
            child: profile.saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Save'),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
          children: [
            Center(
              child: AvatarEditor(
                url: me?.avatarUrl,
                name: me?.displayName,
                busy: profile.uploading,
                onPick: (source) => pickAndUploadAvatar(context, ref, source),
                onRemove: () =>
                    ref.read(profileControllerProvider.notifier).removeAvatar(),
              ),
            ),
            const SizedBox(height: 32),
            TextField(
              key: const Key('name'),
              controller: _name,
              enabled: !profile.saving,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(
                labelText: 'Name',
                prefixIcon: const Icon(Icons.person_outline),
                counterText: '${_name.text.trim().length}/$maxNameLength',
                errorText: nameErr,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              key: const Key('about'),
              controller: _about,
              enabled: !profile.saving,
              minLines: 1,
              maxLines: 4,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                labelText: 'About',
                hintText: 'A few words about you',
                prefixIcon: const Icon(Icons.info_outline),
                counterText: '${_about.text.trim().length}/$maxAboutLength',
                errorText: aboutErr,
              ),
            ),
            const SizedBox(height: 16),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.phone_outlined),
              title: const Text('Phone'),
              subtitle: Text(me?.phone ?? '', key: const Key('phone-number')),
            ),
            if (profile.error != null) ...[
              const SizedBox(height: 12),
              Text(
                errorMessage(profile.error!),
                key: const Key('profile-error'),
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
