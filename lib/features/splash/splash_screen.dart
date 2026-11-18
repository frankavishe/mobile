import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';

/// Shown while the session is restored on start; offers a retry when offline.
class SplashScreen extends ConsumerWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final failed = ref.watch(sessionProvider.select((s) => s.restoreFailed));
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.forum_rounded, size: 64, color: theme.colorScheme.primary),
              const SizedBox(height: 24),
              if (!failed)
                const CircularProgressIndicator()
              else ...[
                Text(
                  "Can't reach the server. Check your connection.",
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyLarge,
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () => ref.read(sessionProvider.notifier).restore(),
                  child: const Text('Try again'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
