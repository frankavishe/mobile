import 'dart:async';

import 'package:drift/drift.dart';

/// Runs before every test file. Tests open many separate in-memory databases on purpose, which
/// trips drift's "created AppDatabase multiple times" debug warning.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  await testMain();
}
