import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/session.dart';
import '../../core/db/app_database.dart';
import '../../core/db/db_opener.dart';
import '../../router.dart';
import '../profile/widgets/avatar_editor.dart';
import 'chat_format.dart';

/// Conversations, most recent activity first, straight from the local database.
final chatListProvider = StreamProvider<List<ChatSummary>>(
  (ref) => ref.watch(appDatabaseProvider).watchChatList(),
);

/// The Chats tab. [empty] is shown while there are no conversations.
class ChatList extends ConsumerWidget {
  const ChatList({super.key, required this.empty});

  final Widget empty;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chats = ref.watch(chatListProvider).value;
    if (chats == null) return const Center(child: CircularProgressIndicator());
    if (chats.isEmpty) return empty;
    final myId = ref.watch(sessionProvider.select((s) => s.me?.id));
    return ListView.builder(
      key: const Key('chat-list'),
      itemCount: chats.length,
      itemBuilder: (context, i) => _ChatTile(summary: chats[i], myId: myId),
    );
  }
}

class _ChatTile extends StatelessWidget {
  const _ChatTile({required this.summary, required this.myId});

  final ChatSummary summary;
  final String? myId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = summary.conversation;
    final last = summary.lastMessage;
    final title = chatTitle(c, summary.peer);
    final unread = c.unreadCount;
    final mine = last != null && last.senderUserId == myId && last.kind == MessageKind.text;
    final muted = theme.colorScheme.onSurfaceVariant;

    return ListTile(
      key: ValueKey('chat-${c.id}'),
      leading: Avatar(url: summary.peer?.avatarThumbUrl, name: title),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Row(
        children: [
          if (mine) ...[
            MessageTicks(status: last.status),
            const SizedBox(width: 4),
          ],
          Expanded(
            child: Text(
              last?.body ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: last?.kind == MessageKind.system
                  ? const TextStyle(fontStyle: FontStyle.italic)
                  : null,
            ),
          ),
        ],
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            listTime(last?.sentAt ?? c.updatedAt),
            style: theme.textTheme.labelSmall?.copyWith(
              color: unread > 0 ? theme.colorScheme.primary : muted,
            ),
          ),
          const SizedBox(height: 4),
          if (unread > 0)
            Badge(
              key: ValueKey('unread-${c.id}'),
              label: Text('$unread'),
              backgroundColor: theme.colorScheme.primary,
              textColor: theme.colorScheme.onPrimary,
            )
          else
            const SizedBox(height: 16),
        ],
      ),
      onTap: () => context.push(Routes.chatOf(c.id)),
    );
  }
}
