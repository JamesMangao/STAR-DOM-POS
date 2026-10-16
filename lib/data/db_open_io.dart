import 'package:drift/native.dart';

import 'db.dart';
import 'db_storage.dart';

/// VM opener. The only shipping target is the web PWA (W2), so this exists so
/// the same drift code can run under `flutter test` and `dart run` without a
/// single `dart:io` import leaking into `lib/` (grep-verified).
///
/// It is deliberately IN MEMORY: a native build is not a supported deployment
/// path, and a memory database cannot silently pretend to persist a sale.
/// Tests build `AppDatabase(NativeDatabase.memory())` themselves; this is the
/// app-level equivalent.
Future<DatabaseOpenResult> openAppDatabase() async => DatabaseOpenResult(
  db: AppDatabase(NativeDatabase.memory()),
  storageMode: 'inMemory (Dart VM, tests only)',
  persistent: false,
  missingFeatures: const [],
);
