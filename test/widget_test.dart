import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stardom_pos/core/icons.dart';
import 'package:stardom_pos/data/db.dart';
import 'package:stardom_pos/data/db_open.dart';
import 'package:stardom_pos/main.dart';
import 'package:stardom_pos/ui/settings.dart';

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
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// Dispose the tree so the 10s status ticker is cancelled before the test
  /// framework asserts there are no pending timers.
  Future<void> disposeShell(WidgetTester tester, AppDatabase db) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await db.close();
  }

  testWidgets('shell boots and auto-seeds the catalogue store', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    await pumpShell(tester, db, storageMode: 'unsafeIndexedDb');

    // The catalogue is auto-seeded into the empty database on boot.
    // The default test surface is 800×600 — the MEDIUM tier (600–899), so
    // navigation is the compact left rail; the bottom bar is phone-only.
    expect(find.byType(PosNavRailCompact), findsOneWidget);
    expect(find.byIcon(AppIcons.sell), findsOneWidget);

    await disposeShell(tester, db);
  });

  testWidgets('seeded store lands on Sell and Settings reports the device', (
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

    // The five tabs are there and Sell is the landing tab.
    expect(find.byType(PosNavRailCompact), findsOneWidget);
    expect(find.byIcon(AppIcons.sell), findsOneWidget);
    expect(find.text('No products yet'), findsOneWidget);
    // No stale sales → the data-loss banner stays away.
    expect(find.textContaining('Unsynced sales'), findsNothing);

    // W2: the storage mode WebKit actually picked is on screen, in Settings.
    await tester.tap(find.byIcon(AppIcons.settings));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Shop'), findsOneWidget);

    // The device facts sit below the fold of the settings list.
    final settingsScrollable = find
        .descendant(
          of: find.byType(SettingsScreen),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.textContaining('unsafeIndexedDb'),
      300,
      scrollable: settingsScrollable,
    );
    expect(find.textContaining('unsafeIndexedDb'), findsOneWidget);
    // The row's own sentence, not a bare 'data survives reloads': the
    // persistent-storage line below it says that too, so the loose
    // contains-finder matches two widgets.
    expect(
      find.text('unsafeIndexedDb — data survives reloads'),
      findsOneWidget,
    );

    await tester.scrollUntilVisible(
      find.text('Sync details'),
      300,
      scrollable: settingsScrollable,
    );
    expect(find.text('Sync details'), findsOneWidget);

    await disposeShell(tester, db);
  });
}
