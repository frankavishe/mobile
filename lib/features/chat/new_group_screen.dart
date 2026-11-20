import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/error_messages.dart';
import '../../core/api/models/models.dart';
import '../../core/db/db_opener.dart';
import '../../core/phone.dart';
import '../../router.dart';
import '../contacts/contacts_repository.dart';
import '../profile/widgets/avatar_editor.dart';
import 'chat_format.dart';
import 'messaging_service.dart';

/// Most members a group can have, the creator included (the server enforces it too).
const groupMax = 64;

String _nameOf(PublicUser u) =>
    u.displayName?.isNotEmpty == true ? u.displayName! : formatPhone(u.phone);

/// [current] with [u] added or removed. Null when adding would go past [max].
List<PublicUser>? _toggled(List<PublicUser> current, PublicUser u, int max) {
  if (current.any((s) => s.id == u.id)) return [for (final s in current) if (s.id != u.id) s];
  if (current.length >= max) return null;
  return [...current, u];
}

void _tooMany(BuildContext context, int max) => ScaffoldMessenger.of(context)
  ..hideCurrentSnackBar()
  ..showSnackBar(SnackBar(content: Text('You can add up to $max people.')));

/// Contacts on Chat App with check boxes; the chosen ones show as chips on top.
class ContactPicker extends ConsumerWidget {
  const ContactPicker({
    super.key,
    required this.selected,
    required this.onToggle,
    this.exclude = const {},
  });

  final List<PublicUser> selected;

  /// The parent adds or removes the user (see [_toggled]) from its current state, so quick
  /// taps between rebuilds aren't lost.
  final ValueChanged<PublicUser> onToggle;

  /// Users that can't be picked (e.g. current members).
  final Set<String> exclude;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final contacts = ref.watch(contactsProvider);
    final list = [
      for (final u in contacts.contacts ?? const <PublicUser>[])
        if (!exclude.contains(u.id)) u,
    ];
    final ids = {for (final u in selected) u.id};
    final theme = Theme.of(context);
    final toggle = onToggle;

    return Column(
      children: [
        if (selected.isNotEmpty)
          SizedBox(
            height: 56,
            child: ListView(
              key: const Key('picked'),
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              children: [
                for (final u in selected)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: InputChip(
                      key: ValueKey('picked-${u.id}'),
                      label: Text(_nameOf(u)),
                      onDeleted: () => toggle(u),
                    ),
                  ),
              ],
            ),
          ),
        Expanded(
          child: contacts.contacts == null
              ? const Center(child: CircularProgressIndicator())
              : list.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text(
                          exclude.isEmpty
                              ? 'None of your contacts are on Chat App yet.'
                              : 'Everyone in your contacts is already here.',
                          key: const Key('picker-empty'),
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ),
                    )
                  : ListView.builder(
                      key: const Key('picker'),
                      itemCount: list.length,
                      itemBuilder: (context, i) {
                        final u = list[i];
                        return CheckboxListTile(
                          key: ValueKey('pick-${u.id}'),
                          value: ids.contains(u.id),
                          onChanged: (_) => toggle(u),
                          controlAffinity: ListTileControlAffinity.trailing,
                          secondary: Avatar(url: u.avatarThumbUrl ?? u.avatarUrl, name: u.displayName),
                          title: Text(_nameOf(u), maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: u.about.isEmpty
                              ? null
                              : Text(u.about, maxLines: 1, overflow: TextOverflow.ellipsis),
                        );
                      },
                    ),
        ),
      ],
    );
  }
}

/// Two steps: pick contacts, then name the group. The name travels end-to-end encrypted.
class NewGroupScreen extends ConsumerStatefulWidget {
  const NewGroupScreen({super.key});

  @override
  ConsumerState<NewGroupScreen> createState() => _NewGroupScreenState();
}

class _NewGroupScreenState extends ConsumerState<NewGroupScreen> {
  var _picked = <PublicUser>[];
  bool _naming = false;
  bool _busy = false;
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

  Future<void> _create() async {
    final name = _name.text.trim();
    if (name.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      final id = await ref.read(messagingServiceProvider).createGroup(name, _picked);
      if (mounted) context.pushReplacement(Routes.chatOf(id));
    } on ApiError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(errorMessage(e))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      canPop: !_naming,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_busy) setState(() => _naming = false);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_naming ? 'Name the group' : 'New group'),
              Text(
                _picked.isEmpty
                    ? 'Add members'
                    : '${_picked.length} of ${groupMax - 1} selected',
                style: theme.textTheme.labelMedium,
              ),
            ],
          ),
        ),
        body: _naming
            ? ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Row(
                    children: [
                      const GroupAvatar(radius: 28),
                      const SizedBox(width: 16),
                      Expanded(
                        child: TextField(
                          key: const Key('group-name'),
                          controller: _name,
                          autofocus: true,
                          enabled: !_busy,
                          textCapitalization: TextCapitalization.sentences,
                          inputFormatters: [LengthLimitingTextInputFormatter(groupNameMax)],
                          decoration: const InputDecoration(labelText: 'Group name'),
                          onSubmitted: (_) => _create(),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Only members can see the group name; it is end-to-end encrypted.',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 24),
                  Text('Members: ${_picked.map(_nameOf).join(', ')}',
                      style: theme.textTheme.bodyMedium),
                ],
              )
            : ContactPicker(
                selected: _picked,
                onToggle: (u) {
                  final next = _toggled(_picked, u, groupMax - 1);
                  if (next == null) return _tooMany(context, groupMax - 1);
                  setState(() => _picked = next);
                },
              ),
        floatingActionButton: _naming
            ? FloatingActionButton(
                key: const Key('create-group'),
                tooltip: 'Create group',
                onPressed: _name.text.trim().isEmpty || _busy ? null : _create,
                child: _busy
                    ? const SizedBox.square(
                        dimension: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.check),
              )
            : _picked.isEmpty
                ? null
                : FloatingActionButton(
                    key: const Key('group-next'),
                    tooltip: 'Next',
                    onPressed: () => setState(() => _naming = true),
                    child: const Icon(Icons.arrow_forward),
                  ),
      ),
    );
  }
}

/// Admins pick contacts to add to an existing group.
class AddMembersScreen extends ConsumerStatefulWidget {
  const AddMembersScreen({super.key, required this.conversationId});

  final String conversationId;

  @override
  ConsumerState<AddMembersScreen> createState() => _AddMembersScreenState();
}

class _AddMembersScreenState extends ConsumerState<AddMembersScreen> {
  var _picked = <PublicUser>[];
  bool _busy = false;
  Set<String>? _members;

  @override
  void initState() {
    super.initState();
    ref.read(appDatabaseProvider).membersOf(widget.conversationId).then((list) {
      if (mounted) setState(() => _members = {for (final m in list) m.userId});
    });
  }

  Future<void> _add() async {
    if (_busy || _picked.isEmpty) return;
    setState(() => _busy = true);
    try {
      await ref.read(messagingServiceProvider).addMembers(widget.conversationId, _picked);
      if (mounted) context.pop();
    } on ApiError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(errorMessage(e))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final members = _members;
    return Scaffold(
      appBar: AppBar(title: const Text('Add members')),
      body: members == null
          ? const Center(child: CircularProgressIndicator())
          : ContactPicker(
              selected: _picked,
              exclude: members,
              onToggle: (u) {
                final max = groupMax - members.length;
                final next = _toggled(_picked, u, max);
                if (next == null) return _tooMany(context, max);
                setState(() => _picked = next);
              },
            ),
      floatingActionButton: _picked.isEmpty
          ? null
          : FloatingActionButton(
              key: const Key('add-members'),
              tooltip: 'Add',
              onPressed: _busy ? null : _add,
              child: _busy
                  ? const SizedBox.square(
                      dimension: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.check),
            ),
    );
  }
}
