import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/error_messages.dart';
import '../../core/auth/session.dart';
import '../auth/auth_controller.dart';
import 'avatar_actions.dart';
import 'profile_controller.dart';
import 'widgets/avatar_editor.dart';

/// Shown after sign-up while `profileComplete` is false: name (required) and photo (optional).
///
/// Saving a name makes the profile complete, and the router then moves on to home.
class ProfileSetupScreen extends ConsumerStatefulWidget {
  const ProfileSetupScreen({super.key});

  @override
  ConsumerState<ProfileSetupScreen> createState() => _ProfileSetupScreenState();
}

class _ProfileSetupScreenState extends ConsumerState<ProfileSetupScreen> {
  final _name = TextEditingController();

  @override
  void initState() {
    super.initState();
    _name.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (nameError(_name.text) != null) return;
    FocusScope.of(context).unfocus();
    await ref.read(profileControllerProvider.notifier).save(name: _name.text);
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(sessionProvider.select((s) => s.me));
    final profile = ref.watch(profileControllerProvider);
    final theme = Theme.of(context);
    final tooLong = _name.text.trim().length > maxNameLength;
    final canSubmit = nameError(_name.text) == null && !profile.busy;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Your profile'),
        automaticallyImplyLeading: false,
        actions: [
          PopupMenuButton<String>(
            key: const Key('setup-menu'),
            onSelected: (v) {
              if (v == 'sign-out') ref.read(authControllerProvider.notifier).signOut();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'sign-out', child: Text('Sign out')),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
          children: [
            Text(
              'Add your name and an optional photo. People you chat with will see them.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 24),
            Center(
              child: AvatarEditor(
                url: me?.avatarUrl,
                name: _name.text,
                busy: profile.uploading,
                onPick: (source) => pickAndUploadAvatar(context, ref, source),
                onRemove: () =>
                    ref.read(profileControllerProvider.notifier).removeAvatar(),
              ),
            ),
            const SizedBox(height: 24),
            TextField(
              key: const Key('name'),
              controller: _name,
              autofocus: true,
              enabled: !profile.saving,
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                labelText: 'Your name',
                counterText: '${_name.text.trim().length}/$maxNameLength',
                errorText: tooLong ? nameError(_name.text) : null,
              ),
            ),
            if (profile.error != null) ...[
              const SizedBox(height: 12),
              Text(
                errorMessage(profile.error!),
                key: const Key('profile-error'),
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ],
            const SizedBox(height: 24),
            FilledButton(
              key: const Key('next'),
              onPressed: canSubmit ? _submit : null,
              child: profile.saving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Next'),
            ),
          ],
        ),
      ),
    );
  }
}
