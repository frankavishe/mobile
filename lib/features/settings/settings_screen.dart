import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/session.dart';
import '../../router.dart';
import '../auth/auth_controller.dart';
import '../profile/widgets/avatar_editor.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(sessionProvider.select((s) => s.me));
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          ListTile(
            key: const Key('settings-profile'),
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            leading: Avatar(
              url: me?.avatarThumbUrl ?? me?.avatarUrl,
              name: me?.displayName,
              radius: 28,
            ),
            title: Text(me?.label ?? '', style: theme.textTheme.titleMedium),
            subtitle: Text(
              (me?.about.isNotEmpty ?? false) ? me!.about : 'Add an about',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push(Routes.settingsProfile),
          ),
          const Divider(),
          ListTile(
            key: const Key('settings-devices'),
            leading: const Icon(Icons.devices_outlined),
            title: const Text('Linked devices'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push(Routes.settingsDevices),
          ),
          ListTile(
            key: const Key('settings-sign-out'),
            leading: Icon(Icons.logout, color: theme.colorScheme.error),
            title: Text('Sign out', style: TextStyle(color: theme.colorScheme.error)),
            onTap: () => ref.read(authControllerProvider.notifier).signOut(),
          ),
        ],
      ),
    );
  }
}
