import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/session.dart';
import '../../core/db/app_database.dart';
import '../../core/db/db_opener.dart';
import '../../router.dart';
import '../profile/widgets/avatar_editor.dart';
import 'chat_format.dart';
import 'messaging_service.dart';

final _conversationProvider = StreamProvider.family<LocalConversation?, String>(
  (ref, id) => ref.watch(appDatabaseProvider).watchConversation(id),
);

final _messagesProvider = StreamProvider.family<List<Message>, String>(
  (ref, id) => ref.watch(appDatabaseProvider).watchMessages(id),
);

final _userProvider = StreamProvider.family<CachedUser?, String>(
  (ref, id) => ref.watch(appDatabaseProvider).watchCachedUser(id),
);

final _typingProvider = StreamProvider.family<Set<String>, String>(
  (ref, id) => ref.watch(messagingServiceProvider).typingUsers(id),
);

/// One chat: bubbles with delivery ticks, a "typing…" header and the composer.
/// While it is visible, incoming messages are marked read (and a read receipt is sent).
class ConversationScreen extends ConsumerStatefulWidget {
  const ConversationScreen({super.key, required this.conversationId});

  final String conversationId;

  @override
  ConsumerState<ConversationScreen> createState() => _ConversationScreenState();
}

class _ConversationScreenState extends ConsumerState<ConversationScreen> {
  final _text = TextEditingController();
  late final MessagingService _messaging;
  late final AppLifecycleListener _lifecycle;

  String get _id => widget.conversationId;

  @override
  void initState() {
    super.initState();
    _messaging = ref.read(messagingServiceProvider);
    _lifecycle = AppLifecycleListener(
      onResume: () => _messaging.openConversation(_id),
      onInactive: () => _messaging.closeConversation(_id),
    );
    _text.addListener(() => setState(() {}));
    _messaging.openConversation(_id);
  }

  @override
  void dispose() {
    _messaging.closeConversation(_id);
    _lifecycle.dispose();
    _text.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final body = _text.text.trim();
    if (body.isEmpty) return;
    _text.clear();
    await _messaging.sendText(_id, body);
  }

  @override
  Widget build(BuildContext context) {
    final conversation = ref.watch(_conversationProvider(_id)).value;
    final peerId = conversation?.peerUserId;
    final peer = peerId == null ? null : ref.watch(_userProvider(peerId)).value;
    final typing = ref.watch(_typingProvider(_id)).value ?? const {};
    final messages = ref.watch(_messagesProvider(_id)).value;
    final myId = ref.watch(sessionProvider.select((s) => s.me?.id));
    final title = conversation == null ? '' : chatTitle(conversation, peer);
    final theme = Theme.of(context);
    final isGroup = conversation?.kind == ConversationKind.group;
    final active = conversation?.active ?? true;
    final typingLabel = typing.isEmpty
        ? null
        : !isGroup
            ? 'typing…'
            : typing.length == 1
                ? '${userLabel(ref.watch(_userProvider(typing.first)).value)} is typing…'
                : '${typing.length} people are typing…';

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: InkWell(
          key: const Key('conversation-header'),
          onTap: isGroup ? () => context.push(Routes.groupInfoOf(_id)) : null,
          child: Row(
            children: [
              if (isGroup)
                const GroupAvatar(radius: 18)
              else
                Avatar(url: peer?.avatarThumbUrl, name: title, radius: 18),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
                    if (typingLabel != null)
                      Text(
                        typingLabel,
                        key: const Key('typing'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelMedium
                            ?.copyWith(color: theme.colorScheme.primary),
                      )
                    else if (isGroup)
                      Text(
                        'Tap for group info',
                        style: theme.textTheme.labelMedium
                            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: messages == null
                ? const Center(child: CircularProgressIndicator())
                : _MessageList(
                    messages: messages,
                    myId: myId,
                    showSenders: isGroup,
                    onRetry: _messaging.retry,
                  ),
          ),
          if (active)
            _Composer(
              controller: _text,
              onChanged: (t) => _messaging.composerChanged(_id, t),
              onSend: _send,
            )
          else
            SafeArea(
              top: false,
              child: Container(
                key: const Key('not-a-member'),
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                color: theme.colorScheme.surfaceContainer,
                child: Text(
                  "You're no longer a member of this group.",
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _MessageList extends StatelessWidget {
  const _MessageList({
    required this.messages,
    required this.myId,
    required this.onRetry,
    this.showSenders = false,
  });

  final List<Message> messages;
  final String? myId;
  final void Function(String id) onRetry;

  /// Groups: name the sender above the first of their consecutive bubbles.
  final bool showSenders;

  @override
  Widget build(BuildContext context) {
    if (messages.isEmpty) {
      final theme = Theme.of(context);
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            'Messages are end-to-end encrypted. Say hello!',
            key: const Key('conversation-empty'),
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      );
    }
    // Newest at the bottom: the list is reversed, so index 0 is the last message.
    return ListView.builder(
      key: const Key('messages'),
      reverse: true,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: messages.length,
      itemBuilder: (context, i) {
        final index = messages.length - 1 - i;
        final m = messages[index];
        final previous = index > 0 ? messages[index - 1] : null;
        final newDay = previous == null || !sameDay(previous.sentAt, m.sentAt);
        final mine = m.senderUserId == myId;
        final continued = !newDay &&
            previous.kind == MessageKind.text &&
            previous.senderUserId == m.senderUserId;
        return Column(
          children: [
            if (newDay) _DaySeparator(label: dayLabel(m.sentAt)),
            if (m.kind == MessageKind.system)
              _SystemNote(key: ValueKey('msg-${m.id}'), text: m.body ?? '')
            else
              _Bubble(
                key: ValueKey('msg-${m.id}'),
                message: m,
                mine: mine,
                senderId: showSenders && !mine && !continued ? m.senderUserId : null,
                onRetry: () => onRetry(m.id),
              ),
          ],
        );
      },
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({
    super.key,
    required this.message,
    required this.mine,
    required this.onRetry,
    this.senderId,
  });

  final Message message;
  final bool mine;
  final VoidCallback onRetry;

  /// Shown as a colored name on top (incoming group messages).
  final String? senderId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final failed = mine && message.status == MessageStatus.failed;
    final bubble = Container(
      constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.78),
      margin: const EdgeInsets.symmetric(vertical: 2),
      padding: const EdgeInsets.fromLTRB(12, 8, 10, 6),
      decoration: BoxDecoration(
        color: mine ? scheme.primaryContainer : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(16),
          topRight: const Radius.circular(16),
          bottomLeft: Radius.circular(mine ? 16 : 4),
          bottomRight: Radius.circular(mine ? 4 : 16),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (senderId != null)
            Align(
              alignment: Alignment.centerLeft,
              widthFactor: 1,
              child: _SenderName(userId: senderId!),
            ),
          Align(
            alignment: Alignment.centerLeft,
            widthFactor: 1,
            child: Text(
              message.body ?? '',
              style: theme.textTheme.bodyLarge?.copyWith(
                color: mine ? scheme.onPrimaryContainer : scheme.onSurface,
              ),
            ),
          ),
          const SizedBox(height: 2),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                clockTime(message.sentAt),
                style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
              if (mine) ...[
                const SizedBox(width: 4),
                MessageTicks(status: message.status, size: 14),
              ],
            ],
          ),
        ],
      ),
    );
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: failed
          ? Tooltip(
              message: 'Not sent. Tap to retry.',
              child: InkWell(
                key: Key('retry-${message.id}'),
                borderRadius: BorderRadius.circular(16),
                onTap: onRetry,
                child: bubble,
              ),
            )
          : bubble,
    );
  }
}

class _SenderName extends ConsumerWidget {
  const _SenderName({required this.userId});

  final String userId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final user = ref.watch(_userProvider(userId)).value;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Text(
        userLabel(user),
        key: Key('sender-$userId'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.labelMedium?.copyWith(
          color: senderColor(userId, theme.colorScheme),
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _DaySeparator extends StatelessWidget {
  const _DaySeparator({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Chip(
        label: Text(label, style: theme.textTheme.labelSmall),
        visualDensity: VisualDensity.compact,
        side: BorderSide.none,
        backgroundColor: theme.colorScheme.surfaceContainer,
      ),
    );
  }
}

class _SystemNote extends StatelessWidget {
  const _SystemNote({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: theme.textTheme.bodySmall?.copyWith(
          fontStyle: FontStyle.italic,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({required this.controller, required this.onChanged, required this.onSend});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final canSend = controller.text.trim().isNotEmpty;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                key: const Key('composer'),
                controller: controller,
                onChanged: onChanged,
                minLines: 1,
                maxLines: 6,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  hintText: 'Message',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.all(Radius.circular(24)),
                  ),
                  contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              key: const Key('send'),
              tooltip: 'Send',
              onPressed: canSend ? onSend : null,
              icon: const Icon(Icons.send),
            ),
          ],
        ),
      ),
    );
  }
}
