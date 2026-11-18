import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/auth/session.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final container = ProviderContainer();
  // Restore the session from the stored refresh token; the splash screen shows meanwhile.
  container.read(sessionProvider.notifier).restore();
  runApp(UncontrolledProviderScope(container: container, child: const ChatApp()));
}
