import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/error_messages.dart';
import '../../core/api/models/models.dart';
import 'devices_controller.dart';

/// Settings → Linked devices: every signed-in device, each of which can be signed out.
class LinkedDevicesScreen extends ConsumerStatefulWidget {
  const LinkedDevicesScreen({super.key});

  /// Same polling rate as the web page.
  static const pollInterval = Duration(seconds: 30);

  @override
  ConsumerState<LinkedDevicesScreen> createState() => _LinkedDevicesScreenState();
}

class _LinkedDevicesScreenState extends ConsumerState<LinkedDevicesScreen> {
  Timer? _poll;

  /// The device being signed out, if any.
  String? _revoking;

  @override
  void initState() {
    super.initState();
    _poll = Timer.periodic(LinkedDevicesScreen.pollInterval, (_) {
      if (_revoking == null) ref.read(devicesProvider.notifier).refresh();
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _signOut(Device device) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(device.current ? 'Sign out of this phone?' : 'Sign out ${device.name}?'),
        content: Text(device.current
            ? "You'll need a new code to sign in again."
            : 'This device will be signed out right away.'),
        actions: [
          TextButton(
            key: const Key('cancel'),
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('confirm-sign-out'),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    setState(() => _revoking = device.id);
    try {
      await ref.read(devicesProvider.notifier).revoke(device);
    } on ApiError catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(errorMessage(e))));
    } finally {
      if (mounted) setState(() => _revoking = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final devices = ref.watch(devicesProvider);
    final theme = Theme.of(context);

    final Widget body;
    if (devices.hasValue) {
      final list = devices.requireValue;
      final now = DateTime.now();
      body = RefreshIndicator(
        onRefresh: ref.read(devicesProvider.notifier).refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Text(
                'Devices signed in to your account.',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
            for (final d in list)
              _DeviceTile(
                key: ValueKey('device-${d.id}'),
                device: d,
                subtitle: '${d.type == DeviceType.android ? 'Android' : 'Web'} · '
                    '${d.current ? 'Active now' : lastActiveText(d.lastActiveAt, now)}',
                revoking: _revoking == d.id,
                enabled: _revoking == null,
                onSignOut: () => _signOut(d),
              ),
          ],
        ),
      );
    } else if (devices.hasError) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                errorMessage(devices.error!),
                key: const Key('devices-error'),
                textAlign: TextAlign.center,
                style: TextStyle(color: theme.colorScheme.error),
              ),
              const SizedBox(height: 16),
              OutlinedButton(
                key: const Key('retry'),
                onPressed: ref.read(devicesProvider.notifier).retry,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    } else {
      body = const Center(child: CircularProgressIndicator());
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Linked devices')),
      body: body,
    );
  }
}

class _DeviceTile extends StatelessWidget {
  const _DeviceTile({
    super.key,
    required this.device,
    required this.subtitle,
    required this.revoking,
    required this.enabled,
    required this.onSignOut,
  });

  final Device device;
  final String subtitle;
  final bool revoking;
  final bool enabled;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: scheme.surfaceContainerHighest,
        foregroundColor: scheme.onSurfaceVariant,
        child: Icon(device.type == DeviceType.android
            ? Icons.phone_android
            : Icons.laptop),
      ),
      title: Row(
        children: [
          Flexible(child: Text(device.name, overflow: TextOverflow.ellipsis)),
          if (device.current) ...[
            const SizedBox(width: 8),
            Container(
              key: const Key('this-phone'),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                'This phone',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ],
      ),
      subtitle: Text(subtitle),
      trailing: revoking
          ? const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : TextButton(
              key: Key('sign-out-${device.id}'),
              style: TextButton.styleFrom(foregroundColor: scheme.error),
              onPressed: enabled ? onSignOut : null,
              child: const Text('Sign out'),
            ),
    );
  }
}
