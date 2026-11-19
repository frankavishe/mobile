import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:phone_numbers_parser/phone_numbers_parser.dart';

import '../../core/api/api_client.dart';
import '../../core/api/error_messages.dart';
import '../../core/api/models/models.dart';
import '../../core/auth/session.dart';
import '../../core/phone.dart';
import '../../core/widgets/country_picker.dart';
import '../../router.dart';
import '../chat/messaging_service.dart';
import '../profile/widgets/avatar_editor.dart';
import 'contacts_repository.dart';

/// Result of a single-number lookup (FR-014).
sealed class _Lookup {
  const _Lookup();
}

class _Idle extends _Lookup {
  const _Idle();
}

class _Busy extends _Lookup {
  const _Busy();
}

class _Found extends _Lookup {
  const _Found(this.user);
  final PublicUser user;
}

class _Missing extends _Lookup {
  const _Missing(this.phone);
  final String phone;
}

class _Failed extends _Lookup {
  const _Failed(this.text);
  final String text;
}

/// New chat (T065): contacts on the app, plus lookup of any number. Tapping someone opens the
/// direct chat with them.
class NewChatScreen extends ConsumerStatefulWidget {
  const NewChatScreen({super.key});

  @override
  ConsumerState<NewChatScreen> createState() => _NewChatScreenState();
}

class _NewChatScreenState extends ConsumerState<NewChatScreen> {
  final _number = TextEditingController();
  late IsoCode _country;
  _Lookup _lookup = const _Idle();
  late final AppLifecycleListener _lifecycle;

  /// The user whose chat is being opened.
  String? _opening;

  ContactsRepository get _contacts => ref.read(contactsProvider.notifier);

  @override
  void initState() {
    super.initState();
    _country = countryOf(ref.read(sessionProvider).me?.phone) ?? defaultCountry();
    // Coming back from system settings may have changed the permission.
    _lifecycle = AppLifecycleListener(onResume: _contacts.checkAccess);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _contacts.checkAccess();
      _contacts.load();
    });
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _number.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    if (_lookup is _Busy) return;
    FocusScope.of(context).unfocus();
    final digits = _number.text.replaceAll(RegExp(r'\D'), '');
    if (digits.isEmpty) {
      setState(() => _lookup = const _Failed('Enter a phone number.'));
      return;
    }
    final e164 = toE164(_country, _number.text);
    if (e164 == null) {
      setState(() => _lookup = const _Failed("That number isn't valid for this country."));
      return;
    }
    if (e164 == ref.read(sessionProvider).me?.phone) {
      setState(() => _lookup = const _Failed("That's your own number."));
      return;
    }
    setState(() => _lookup = const _Busy());
    _Lookup result;
    try {
      result = _Found(await ref.read(apiClientProvider).lookupUser(e164));
    } on ApiError catch (e) {
      result = e.code == ApiErrorCode.userNotFound
          ? _Missing(e164)
          : _Failed(errorMessage(e));
    }
    if (mounted) setState(() => _lookup = result);
  }

  Future<void> _pickCountry() async {
    final picked = await showCountryPicker(context);
    if (picked != null) setState(() => _country = picked);
  }

  Future<void> _refresh() async {
    await _contacts.sync(force: true);
    if (!mounted) return;
    final error = ref.read(contactsProvider).error;
    if (error != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(errorMessage(error))));
    }
  }

  /// Creates (or finds) the direct chat with [user] and replaces this screen with it.
  Future<void> _open(PublicUser user) async {
    if (_opening != null) return;
    setState(() => _opening = user.id);
    try {
      final id = await ref.read(messagingServiceProvider).startDirect(user);
      if (mounted) context.pushReplacement(Routes.chatOf(id));
    } on ApiError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(errorMessage(e))));
    } finally {
      if (mounted) setState(() => _opening = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final contacts = ref.watch(contactsProvider);
    final theme = Theme.of(context);

    Widget sectionTitle(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
          child: Text(
            text.toUpperCase(),
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.8,
            ),
          ),
        );

    return Scaffold(
      appBar: AppBar(title: const Text('New chat')),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            sectionTitle('Find by phone number'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    height: 56,
                    child: OutlinedButton(
                      key: const Key('lookup-country'),
                      onPressed: _lookup is _Busy ? null : _pickCountry,
                      child: Text('${flagOf(_country)} ${dialCode(_country)}'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      key: const Key('lookup-number'),
                      controller: _number,
                      keyboardType: TextInputType.phone,
                      textInputAction: TextInputAction.search,
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'[0-9 ]')),
                        LengthLimitingTextInputFormatter(20),
                      ],
                      decoration: const InputDecoration(labelText: 'Phone number'),
                      onSubmitted: (_) => _search(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    height: 56,
                    child: IconButton.filled(
                      key: const Key('lookup-search'),
                      tooltip: 'Search',
                      onPressed: _lookup is _Busy ? null : _search,
                      icon: _lookup is _Busy
                          ? const SizedBox.square(
                              dimension: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.search),
                    ),
                  ),
                ],
              ),
            ),
            switch (_lookup) {
              _Found(:final user) => _UserTile(
                  key: const Key('lookup-result'),
                  user: user,
                  busy: _opening == user.id,
                  onTap: () => _open(user),
                ),
              _Missing(:final phone) => _Note(
                  key: const Key('lookup-missing'),
                  text: "${formatPhone(phone)} isn't on Chat App yet.",
                ),
              _Failed(:final text) => _Note(
                  key: const Key('lookup-error'),
                  text: text,
                  error: true,
                ),
              _Idle() || _Busy() => const SizedBox.shrink(),
            },
            sectionTitle('Contacts on Chat App'),
            ..._contactsSection(contacts, theme),
          ],
        ),
      ),
    );
  }

  List<Widget> _contactsSection(ContactsState s, ThemeData theme) {
    final list = s.contacts;
    return [
      if (s.access == ContactsAccess.blocked)
        _AccessCard(
          key: const Key('contacts-blocked'),
          title: 'Contacts access is off',
          body: 'Turn on contacts access in Settings to see which of your contacts '
              'are on Chat App. You can still look up a number above.',
          action: 'Open settings',
          actionKey: const Key('open-settings'),
          onPressed: _contacts.openSettings,
        )
      else if (s.access != ContactsAccess.granted)
        _AccessCard(
          key: const Key('contacts-allow-card'),
          title: 'Find friends who are on Chat App',
          body: 'Allow access to your contacts to see who is already here. '
              'Only numbers with an account are kept.',
          action: 'Allow access',
          actionKey: const Key('allow-contacts'),
          onPressed: _contacts.requestAccess,
        ),
      if (s.syncing)
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: LinearProgressIndicator(key: Key('contacts-syncing')),
        ),
      if (list == null && s.error != null)
        _Note(key: const Key('contacts-error'), text: errorMessage(s.error!), error: true)
      else if (list == null)
        const Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: CircularProgressIndicator()),
        )
      else if (list.isEmpty && s.access == ContactsAccess.granted && !s.syncing)
        const _Note(
          key: Key('contacts-empty'),
          text: 'None of your contacts are on Chat App yet.',
        )
      else
        for (final u in list)
          _UserTile(
            key: ValueKey('contact-${u.id}'),
            user: u,
            busy: _opening == u.id,
            onTap: () => _open(u),
          ),
    ];
  }
}

class _UserTile extends StatelessWidget {
  const _UserTile({
    super.key,
    required this.user,
    required this.onTap,
    this.busy = false,
  });

  final PublicUser user;
  final VoidCallback onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) => ListTile(
        leading: Avatar(
          url: user.avatarThumbUrl ?? user.avatarUrl,
          name: user.displayName,
        ),
        title: Text(
          user.displayName?.isNotEmpty == true ? user.displayName! : formatPhone(user.phone),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: user.about.isEmpty
            ? null
            : Text(user.about, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: busy
            ? const SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : null,
        onTap: onTap,
      );
}

class _Note extends StatelessWidget {
  const _Note({super.key, required this.text, this.error = false});

  final String text;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Text(
        text,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: error ? theme.colorScheme.error : theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _AccessCard extends StatelessWidget {
  const _AccessCard({
    super.key,
    required this.title,
    required this.body,
    required this.action,
    required this.actionKey,
    required this.onPressed,
  });

  final String title;
  final String body;
  final String action;
  final Key actionKey;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.contacts_outlined, color: theme.colorScheme.primary),
                const SizedBox(width: 12),
                Expanded(child: Text(title, style: theme.textTheme.titleSmall)),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              body,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonal(
                key: actionKey,
                onPressed: onPressed,
                child: Text(action),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
