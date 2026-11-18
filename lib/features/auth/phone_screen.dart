import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:phone_numbers_parser/phone_numbers_parser.dart';

import '../../core/api/error_messages.dart';
import '../../core/auth/session.dart';
import '../../router.dart';
import 'auth_controller.dart';

const _fallbackCountry = IsoCode.TZ;

/// Country from the device locale (e.g. `sw_TZ`), else Tanzania (same rule as the web app).
IsoCode defaultCountry([String? region]) {
  final code = (region ?? WidgetsBinding.instance.platformDispatcher.locale.countryCode)?.toUpperCase();
  return IsoCode.values.asNameMap()[code] ?? _fallbackCountry;
}

/// `+255` for [IsoCode.TZ].
String dialCode(IsoCode iso) => '+${PhoneNumber(isoCode: iso, nsn: '').countryCode}';

/// Regional indicator flag, e.g. 🇹🇿.
String flagOf(IsoCode iso) => String.fromCharCodes(
      iso.name.codeUnits.map((c) => 0x1F1E6 + c - 0x41),
    );

/// The E.164 form of [national] in [country], or null when it is not a valid number.
String? toE164(IsoCode country, String national) {
  final digits = national.replaceAll(RegExp(r'\D'), '');
  if (digits.isEmpty) return null;
  try {
    final n = PhoneNumber.parse(digits, destinationCountry: country);
    return n.isoCode == country && n.isValid() ? n.international : null;
  } catch (_) {
    return null;
  }
}

String signOutReasonText(SignOutReason reason) => switch (reason) {
      SignOutReason.signedOut =>
        'This phone was signed out from another device.',
      SignOutReason.replaced =>
        'Your number was registered on another phone, so this one was signed out.',
      SignOutReason.evicted => 'This device was signed out.',
      SignOutReason.tokenReuse =>
        'You were signed out to keep your account safe. Sign in again.',
      SignOutReason.inactive =>
        'You were signed out after 30 days without activity.',
      SignOutReason.expired => 'Your session has ended. Sign in again.',
    };

/// Step 1 of sign-in: choose a country and enter the phone number.
class PhoneScreen extends ConsumerStatefulWidget {
  const PhoneScreen({super.key, this.initialCountry});

  /// For tests; defaults to the device locale's country.
  final IsoCode? initialCountry;

  @override
  ConsumerState<PhoneScreen> createState() => _PhoneScreenState();
}

class _PhoneScreenState extends ConsumerState<PhoneScreen> {
  final _number = TextEditingController();
  late IsoCode _country = widget.initialCountry ?? defaultCountry();
  SignOutReason? _reason;

  @override
  void initState() {
    super.initState();
    _number.addListener(() => setState(() {}));
    // Read once: the reason is cleared so it is not shown again.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final reason = ref.read(sessionProvider.notifier).consumeSignOutReason();
      if (reason != null) setState(() => _reason = reason);
    });
  }

  @override
  void dispose() {
    _number.dispose();
    super.dispose();
  }

  String? get _e164 => toE164(_country, _number.text);

  Future<void> _submit() async {
    final e164 = _e164;
    if (e164 == null) return;
    FocusScope.of(context).unfocus();
    final ok = await ref.read(authControllerProvider.notifier).requestCode(e164);
    if (ok && mounted) context.push(Routes.signInCode);
  }

  Future<void> _pickCountry() async {
    final picked = await showModalBottomSheet<IsoCode>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _CountrySheet(),
    );
    if (picked != null) setState(() => _country = picked);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(authControllerProvider);
    final theme = Theme.of(context);
    final valid = _e164 != null;
    final showInvalid = !valid && _number.text.replaceAll(RegExp(r'\D'), '').length >= 6;

    return Scaffold(
      appBar: AppBar(title: const Text('Sign in')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            if (_reason != null) ...[
              Material(
                color: theme.colorScheme.secondary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Icon(Icons.info_outline, color: theme.colorScheme.secondary),
                      const SizedBox(width: 12),
                      Expanded(child: Text(signOutReasonText(_reason!))),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
            ],
            Text('Enter your phone number', style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              "We'll send you a 6-digit code to confirm it's yours.",
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 24),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  height: 56,
                  child: OutlinedButton(
                    key: const Key('country'),
                    onPressed: state.busy ? null : _pickCountry,
                    child: Text('${flagOf(_country)} ${dialCode(_country)}'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    key: const Key('phone'),
                    controller: _number,
                    enabled: !state.busy,
                    autofocus: true,
                    keyboardType: TextInputType.phone,
                    autofillHints: const [AutofillHints.telephoneNumberNational],
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9 ]')),
                      LengthLimitingTextInputFormatter(20),
                    ],
                    decoration: InputDecoration(
                      labelText: 'Phone number',
                      errorText: showInvalid ? "That phone number isn't valid." : null,
                    ),
                    onSubmitted: (_) => _submit(),
                  ),
                ),
              ],
            ),
            if (state.error != null) ...[
              const SizedBox(height: 16),
              Text(
                errorMessage(state.error!),
                key: const Key('error'),
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ],
            const SizedBox(height: 32),
            FilledButton(
              key: const Key('continue'),
              onPressed: valid && !state.busy ? _submit : null,
              child: state.busy
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Continue'),
            ),
          ],
        ),
      ),
    );
  }
}

class _CountrySheet extends StatefulWidget {
  const _CountrySheet();

  @override
  State<_CountrySheet> createState() => _CountrySheetState();
}

class _CountrySheetState extends State<_CountrySheet> {
  static final _all = [
    for (final iso in IsoCode.values) (iso: iso, dial: dialCode(iso)),
  ]..sort((a, b) => a.iso.name.compareTo(b.iso.name));

  String _query = '';

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toUpperCase().replaceAll('+', '');
    final items = q.isEmpty
        ? _all
        : _all
            .where((c) => c.iso.name.contains(q) || c.dial.substring(1).startsWith(q))
            .toList();
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.75,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              autofocus: true,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Country code (TZ) or dial code (255)',
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: items.length,
              itemBuilder: (_, i) {
                final c = items[i];
                return ListTile(
                  leading: Text(flagOf(c.iso), style: const TextStyle(fontSize: 24)),
                  title: Text(c.iso.name),
                  trailing: Text(c.dial),
                  onTap: () => Navigator.pop(context, c.iso),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
