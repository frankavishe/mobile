import 'dart:io';
import 'dart:math';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../storage/secure_store.dart';
import 'app_database.dart';

const dbFileName = 'chat.db';

/// A random 256-bit key as 64 hex characters.
String generateDbKey([Random? random]) {
  final r = random ?? Random.secure();
  return List.generate(32, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

/// Opens [file] with SQLCipher using the raw [hexKey]. Fails instead of silently opening a
/// plaintext database when the linked SQLite has no cipher support.
QueryExecutor openEncryptedFile(File file, String hexKey) {
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(hexKey)) {
    throw ArgumentError('Database key must be 64 lowercase hex characters');
  }
  return NativeDatabase.createInBackground(
    file,
    setup: (db) {
      final cipher = db.select('PRAGMA cipher_version');
      if (cipher.isEmpty || (cipher.first.values.first as String?)?.isEmpty != false) {
        throw StateError('SQLCipher is not available; refusing to open an unencrypted database');
      }
      db.execute("PRAGMA key = \"x'$hexKey'\"");
      // Touch the schema so a wrong key fails here rather than on the first query.
      db.select('SELECT count(*) FROM sqlite_master');
      db.execute('PRAGMA journal_mode = WAL');
    },
  );
}

Future<File> databaseFile() async {
  final dir = await getApplicationSupportDirectory();
  return File(p.join(dir.path, dbFileName));
}

/// The app's database in the support directory, keyed from [SecureStore]. The key is created on
/// first use; without it (after a wipe) the old file is useless, so it is deleted.
QueryExecutor openAppDatabase(SecureStore store) => LazyDatabase(() async {
      final file = await databaseFile();
      var key = await store.readDbKey();
      if (key == null) {
        await deleteDatabaseFiles(file);
        key = generateDbKey();
        await store.writeDbKey(key);
      }
      return openEncryptedFile(file, key);
    });

/// Removes the database and its WAL/SHM side files.
Future<void> deleteDatabaseFiles([File? file]) async {
  final f = file ?? await databaseFile();
  for (final path in [f.path, '${f.path}-wal', '${f.path}-shm']) {
    final candidate = File(path);
    if (await candidate.exists()) await candidate.delete();
  }
}

/// The local encrypted database. It lives as long as the session; [wipeLocalData] closes it.
/// Tests override this with `AppDatabase(NativeDatabase.memory())`.
final appDatabaseProvider = Provider<AppDatabase>(
  (ref) => AppDatabase(openAppDatabase(ref.read(secureStoreProvider))),
);

/// Deletes the database file. Overridden in tests, where the database is in memory.
final deleteDatabaseFilesProvider =
    Provider<Future<void> Function()>((ref) => () => deleteDatabaseFiles());

/// Erases everything this device stored: messages, Signal keys and sessions, the database key
/// and the tokens. Used whenever the session ends, since the server has dropped this device.
Future<void> wipeLocalData(Ref ref) async {
  final db = ref.read(appDatabaseProvider);
  await db.close();
  ref.invalidate(appDatabaseProvider);
  await ref.read(deleteDatabaseFilesProvider)();
  await ref.read(secureStoreProvider).clear();
}
