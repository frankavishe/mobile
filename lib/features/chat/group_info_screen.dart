import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/error_messages.dart';
import '../../core/api/models/models.dart' show ApiError;
import '../../core/auth/session.dart';
import '../../core/db/app_database.dart';
import '../../core/db/db_opener.dart';
import '../../core/phone.dart';
import '../../router.dart';
import '../profile/widgets/avatar_editor.dart';
import 'chat_format.dart';
import 'messaging_service.dart';

final _conversationProvider = StreamProvider.family<LocalConversation?, String>(
  (ref, id) => ref.watch(appDatabaseProvider).watchConversation(id),
);

final groupMembersProvider = StreamProvider.family<List<MemberInfo>, String>(
  (ref, id) => ref.watch(appDatabaseProvider).watchMembers(id),
);

/// Name, members and membership actions of a group. Admins rename, add and remove;
/// anyone can leave. After leaving (or being removed) the chat can be deleted here.
class GroupInfoScreen extends ConsumerStatefulWidget {
  const GroupInfoScreen({super.key, required this.conversationId});

  final String conversationId;

  @override
  ConsumerState<GroupInfoScreen> createState() => _GroupInfoScreenState();
}

class _GroupInfoScreenState extends ConsumerState<GroupInfoScreen> {
  bool _busy = false;

  String get _id => widget.conversationId;
  MessagingService get _messaging => ref.read(messagingServiceProvider);

  /// Runs [action] with a spinner, showing API errors as a snack bar.
  Future<bool> _run(Future<void> Function() action) async {
    if (_busy) return false;
    setState(() => _busy = true);
    try {
      await action();
      return true;
    } on ApiError catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(errorMessage(e))));
      }
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirm(String title, String body, String action) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const Key('confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(action),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<void> _rename(String? current) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _RenameDialog(initial: current ?? ''),
    );
    final trimmed = name?.trim();
    if (trimmed == null || trimmed.isEmpty || trimmed == current) return;
    await _run(() => _messaging.renameGroup(_id, trimmed));
  }

  Future<void> _remove(MemberInfo m) async {
    final name = userLabel(m.user);
    if (!await _confirm('Remove $name?', '$name will no longer get messages in this group.',
        'Remove')) {
      return;
    }
    await _run(() => _messaging.removeMember(_id, m.member.userId));
  }

  Future<void> _leave() async {
    if (!await _confirm('Leave this group?',
        "You won't get its messages any more. The chat stays on this device.", 'Leave')) {
      return;
    }
    await _run(() => _messaging.leaveGroup(_id));
  }

  Future<void> _delete() async {
    if (!await _confirm('Delete this chat?', 'Its messages are removed from this device.',
        'Delete')) {
      return;
    }
    if (await _run(() => _messaging.deleteConversation(_id)) && mounted) {
      context.go(Routes.home);
    }
  }

  @override
  Widget build(BuildContext context) {
    final conversation = ref.watch(_conversationProvider(_id)).value;
    final members = ref.watch(groupMembersProvider(_id)).value ?? const <MemberInfo>[];
    final myId = ref.watch(sessionProvider.select((s) => s.me?.id));
    final theme = Theme.of(context);
    final active = conversation?.active ?? false;
    final amAdmin = active && members.any((m) => m.member.userId == myId && m.isAdmin);
    final title = conversation == null ? '' : chatTitle(conversation, null);
    final danger = theme.colorScheme.error;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Group info'),
        bottom: _busy
            ? const PreferredSize(
                preferredSize: Size.fromHeight(4),
                child: LinearProgressIndicator(key: Key('group-busy')),
              )
            : null,
      ),
      body: ListView(
        children: [
          const SizedBox(height: 24),
          const Center(child: GroupAvatar(radius: 48)),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: Text(
                  title,
                  key: const Key('group-title'),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineSmall,
                ),
              ),
              if (amAdmin)
                IconButton(
                  key: const Key('rename'),
                  tooltip: 'Change group name',
                  onPressed: _busy ? null : () => _rename(conversation?.name),
                  icon: const Icon(Icons.edit_outlined),
                ),
            ],
          ),
          Text(
            active
                ? 'Group · ${members.length} ${members.length == 1 ? 'member' : 'members'}'
                : "You're no longer a member",
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          const Divider(),
          if (active) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                '${members.length} MEMBERS',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.8,
                ),
              ),
            ),
            if (amAdmin)
              ListTile(
                key: const Key('add-members-tile'),
                leading: CircleAvatar(
                  backgroundColor: theme.colorScheme.primary,
                  foregroundColor: theme.colorScheme.onPrimary,
                  child: const Icon(Icons.person_add_alt_1),
                ),
                title: const Text('Add members'),
                enabled: !_busy,
                onTap: () => context.push(Routes.groupAddOf(_id)),
              ),
            for (final m in members)
              _MemberTile(
                key: ValueKey('member-${m.member.userId}'),
                info: m,
                isMe: m.member.userId == myId,
                // Admins remove others with a long press.
                onLongPress: amAdmin && m.member.userId != myId && !_busy
                    ? () => _remove(m)
                    : null,
              ),
            const Divider(),
            ListTile(
              key: const Key('leave-group'),
              leading: Icon(Icons.logout, color: danger),
              title: Text('Leave group', style: TextStyle(color: danger)),
              enabled: !_busy,
              onTap: _leave,
            ),
          ] else
            ListTile(
              key: const Key('delete-chat'),
              leading: Icon(Icons.delete_outline, color: danger),
              title: Text('Delete chat', style: TextStyle(color: danger)),
              enabled: !_busy,
              onTap: _delete,
            ),
        ],
      ),
    );
  }
}

/// Owns its text controller so it outlives the closing animation.
class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.initial});

  final String initial;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Group name'),
        content: TextField(
          key: const Key('rename-field'),
          controller: _controller,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          inputFormatters: [LengthLimitingTextInputFormatter(groupNameMax)],
          onSubmitted: (v) => Navigator.of(context).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const Key('rename-save'),
            onPressed: () => Navigator.of(context).pop(_controller.text),
            child: const Text('Save'),
          ),
        ],
      );
}

class _MemberTile extends StatelessWidget {
  const _MemberTile({super.key, required this.info, required this.isMe, this.onLongPress});

  final MemberInfo info;
  final bool isMe;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final phone = info.user?.phone;
    return ListTile(
      leading: Avatar(url: info.user?.avatarThumbUrl, name: info.user?.displayName),
      title: Text(isMe ? 'You' : userLabel(info.user), maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: !isMe && phone != null && info.user?.displayName?.isNotEmpty == true
          ? Text(formatPhone(phone))
          : null,
      trailing: info.isAdmin
          ? Container(
              key: const Key('admin-badge'),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                'Admin',
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.onPrimaryContainer),
              ),
            )
          : null,
      onTap: onLongPress,
      onLongPress: onLongPress,
    );
  }
}
