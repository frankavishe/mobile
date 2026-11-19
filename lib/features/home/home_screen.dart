import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:go_router/go_router.dart';

import '../../router.dart';

/// Signed-in home: Chats, Updates and Calls tabs (content arrives in later features).
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _Tab {
  const _Tab(this.label, this.icon, this.selectedIcon, this.emptyTitle, this.emptyBody);

  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final String emptyTitle;
  final String emptyBody;
}

const _tabs = [
  _Tab('Chats', Icons.chat_bubble_outline, Icons.chat_bubble, 'No conversations yet',
      'Messages you send and receive will show up here.'),
  _Tab('Updates', Icons.donut_large_outlined, Icons.donut_large, 'Nothing new',
      'Status updates from your contacts will appear here.'),
  _Tab('Calls', Icons.call_outlined, Icons.call, 'No calls yet',
      'Your recent voice and video calls will be listed here.'),
];

class _HomeScreenState extends ConsumerState<HomeScreen> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final tab = _tabs[_index];
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Chat App'),
        actions: [
          PopupMenuButton<String>(
            key: const Key('home-menu'),
            onSelected: (v) {
              if (v == 'settings') context.push(Routes.settings);
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'settings', child: Text('Settings')),
            ],
          ),
        ],
      ),
      body: Center(
        key: ValueKey(tab.label),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(tab.icon, size: 56, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(height: 16),
              Text(tab.emptyTitle, style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(
                tab.emptyBody,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
      floatingActionButton: _index == 0
          ? FloatingActionButton(
              key: const Key('new-chat'),
              tooltip: 'New chat',
              onPressed: () => context.push(Routes.newChat),
              child: const Icon(Icons.add_comment_outlined),
            )
          : null,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: [
          for (final t in _tabs)
            NavigationDestination(
              icon: Icon(t.icon),
              selectedIcon: Icon(t.selectedIcon),
              label: t.label,
            ),
        ],
      ),
    );
  }
}
