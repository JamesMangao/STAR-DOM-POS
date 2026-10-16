import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stardom_pos/data/db.dart';
import 'package:stardom_pos/data/db_open.dart';
import 'package:stardom_pos/main.dart';

/// The shell boots against an in-memory database, so these tests exercise the
/// real boot sequence (open → storage mode → seeded or unseeded store) rather
/// than a placeholder screen.
void main() {
  Future<void> pumpShell(
    WidgetTester tester,
    AppDatabase db, {
    required String storageMode,
  }) async {
    await tester.pumpWidget(
      StardomApp(
        opened: DatabaseOpenResult(
          db: db,
          storageMode: storageMode,
          persistent: storageMode != 'inMemory',
          missingFeatures: const [],
        ),
        storagePersisted: false,
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Dispose the tree so the 10s status ticker is cancelled before the test
  /// framework asserts there are no pending timers.
  Future<void> disposeShell(WidgetTester tester, AppDatabase db) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await db.close();
  }

  testWidgets('shell boots and reports the unseeded state', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    await pumpShell(tester, db, storageMode: 'unsafeIndexedDb');

    expect(find.text('STAR:DOM POS'), findsOneWidget);
    // No store row → the runbook notice, not a crash or a blank screen.
    expect(find.textContaining('No store yet'), findsOneWidget);

    await disposeShell(tester, db);
  });

  testWidgets('shell reports the storage backend and the outbox state', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    await db.upsertStore(
      Store(
        id: 'store-1',
        name: 'STAR:DOM',
        tagline: 't',
        ownerId: '',
        receiptName: '',
        receiptTin: '',
        receiptAddress: '',
        receiptAccreditation: '',
        receiptFooter: '',
        currency: 'PHP',
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 1),
      ),
    );

    await pumpShell(tester, db, storageMode: 'unsafeIndexedDb');

    // W2: the mode WebKit actually picked is on screen, not assumed.
    expect(find.textContaining('unsafeIndexedDb'), findsOneWidget);
    expect(find.textContaining('data survives reloads'), findsOneWidget);
    // The outbox guard is present (zero pending, so no banner).
    expect(find.text('Pending sales'), findsOneWidget);
    expect(find.textContaining('Unsynced sales'), findsNothing);

    await disposeShell(tester, db);
  });
}
