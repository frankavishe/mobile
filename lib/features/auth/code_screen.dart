import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/error_messages.dart';
import '../../core/api/models/models.dart';
import '../../core/phone.dart';
import 'auth_controller.dart';

const codeLength = 6;

/// `0:42` for a countdown.
String formatCountdown(int seconds) =>
    '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';

/// Step 2 of sign-in: enter the 6-digit code.
class CodeScreen extends ConsumerStatefulWidget {
  const CodeScreen({super.key});

  @override
  ConsumerState<CodeScreen> createState() => _CodeScreenState();
}

class _CodeScreenState extends ConsumerState<CodeScreen> {
  final _code = TextEditingController();
  final _focus = FocusNode();
  Timer? _timer;
  int _resendIn = 0;

  @override
  void initState() {
    super.initState();
    _startCountdown(ref.read(authControllerProvider).resendAfter);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _code.dispose();
    _focus.dispose();
    super.dispose();
  }

  // Counts down with a timer rather than wall-clock time so it also works in widget tests.
  void _startCountdown(int seconds) {
    _timer?.cancel();
    setState(() => _resendIn = seconds);
    if (seconds <= 0) return;
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      setState(() => _resendIn--);
      if (_resendIn <= 0) t.cancel();
    });
  }

  /// The code can no longer be used; only a new one helps.
  static bool _isDeadEnd(ApiError? e) =>
      e?.code == ApiErrorCode.codeExpired || e?.code == ApiErrorCode.tooManyAttempts;

  Future<void> _verify() async {
    final code = _code.text;
    if (code.length != codeLength) return;
    final ok = await ref.read(authControllerProvider.notifier).verify(code);
    if (ok || !mounted) return;
    final error = ref.read(authControllerProvider).error;
    if (error?.code == ApiErrorCode.invalidCode) {
      _code.clear();
      _focus.requestFocus();
    }
  }

  Future<void> _resend() async {
    final ok = await ref.read(authControllerProvider.notifier).resend();
    if (!ok || !mounted) return;
    _code.clear();
    _startCountdown(ref.read(authControllerProvider).resendAfter);
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(authControllerProvider);
    final theme = Theme.of(context);
    final phone = state.phone;
    final deadEnd = _isDeadEnd(state.error);
    final canResend = _resendIn <= 0 && !state.busy;

    return Scaffold(
      appBar: AppBar(title: const Text('Enter code')),
      body: SafeArea(
        child: phone == null
            ? const SizedBox.shrink()
            : ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  Text('Check your messages', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 8),
                  Text(
                    'We sent a $codeLength-digit code to ${formatPhone(phone)}.',
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: state.busy ? null : () => Navigator.of(context).maybePop(),
                      child: const Text('Wrong number?'),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    key: const Key('code'),
                    controller: _code,
                    focusNode: _focus,
                    autofocus: true,
                    enabled: !state.busy && !deadEnd,
                    keyboardType: TextInputType.number,
                    autofillHints: const [AutofillHints.oneTimeCode],
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineMedium?.copyWith(letterSpacing: 12),
                    maxLength: codeLength,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(codeLength),
                    ],
                    decoration: const InputDecoration(counterText: '', hintText: '------'),
                    onChanged: (v) {
                      if (state.error != null) {
                        ref.read(authControllerProvider.notifier).clearError();
                      }
                      if (v.length == codeLength) _verify();
                    },
                  ),
                  const SizedBox(height: 16),
                  if (state.busy)
                    const Center(child: CircularProgressIndicator())
                  else if (state.error != null)
                    Text(
                      errorMessage(state.error!),
                      key: const Key('error'),
                      textAlign: TextAlign.center,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  const SizedBox(height: 24),
                  if (deadEnd)
                    FilledButton(
                      key: const Key('new-code'),
                      onPressed: canResend ? _resend : null,
                      child: Text(
                        _resendIn > 0
                            ? 'Request a new code in ${formatCountdown(_resendIn)}'
                            : 'Request a new code',
                      ),
                    )
                  else
                    Center(
                      child: TextButton(
                        key: const Key('resend'),
                        onPressed: canResend ? _resend : null,
                        child: Text(
                          _resendIn > 0
                              ? 'Resend code in ${formatCountdown(_resendIn)}'
                              : 'Resend code',
                        ),
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}
