import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stardom_pos/data/db.dart';
import 'package:stardom_pos/data/db_open.dart';
import 'package:stardom_pos/data/device.dart';
import 'package:stardom_pos/main.dart';
import 'package:stardom_pos/ui/widgets.dart';

/// Adaptive layout, verified at the exact target device: iPad (9th gen,
/// 10.2", 1620×2160 physical px @2x → 810×1080 logical points).
///
/// Navigation is three-tier (see PosShell): the BOTTOM NavigationBar is
/// phone-only (< 600 logical px). From 600 up the sidebar takes over —
/// compact left rail at 600–899 (portrait iPad), full rail at ≥ 900
/// (landscape iPad / desktop), which is where these screens came from.
/// Landscape (1080×810) therefore shows the wide enhancements — left
/// NavigationRail, the pinned Sell cart panel, capped form widths — while
/// portrait (810×1080) keeps the single-column flow (sticky cart bar,
/// centred and capped forms) with the COMPACT rail for navigation instead
/// of a bottom bar.
void main() {
  const landscapePhysical = Size(2160, 1620); // → 1080×810 logical
  const portraitPhysical = Size(1620, 2160); // → 810×1080 logical

  Future<AppDatabase> seededDb() async {
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
    final device = await DeviceRegistry(db).ensureRegistered('store-1');
    await db.upsertProduct(
      Product(
        id: 'product-1',
        storeId: 'store-1',
        categoryId: null,
        name: 'Test Product',
        price: 30,
        barcode: null,
        // Sell hides a product until it has a photo (see sell.dart), so the
        // fixture must carry one or the grid is legitimately empty.
        imagePath: 'product-images/test.png',
        stockQuantity: 5,
        isActive: true,
        stockStatus: 'In Stock',
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 1),
        deletedAt: null,
        syncedAt: null,
      ),
      deviceId: device.id,
      storeId: 'store-1',
    );
    return db;
  }

  Future<void> pumpShell(
    WidgetTester tester,
    AppDatabase db, {
    required Size physical,
  }) async {
    tester.view.physicalSize = physical;
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      StardomApp(
        opened: DatabaseOpenResult(
          db: db,
          storageMode: 'unsafeIndexedDb',
          persistent: true,
          missingFeatures: const [],
        ),
        storagePersisted: true,
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

  testWidgets('landscape iPad: left nav rail, not the bottom bar', (
    tester,
  ) async {
    final db = await seededDb();
    await pumpShell(tester, db, physical: landscapePhysical);

    expect(find.byType(PosNavRail), findsOneWidget);
    expect(find.byType(PosNavBar), findsNothing);

    await disposeShell(tester, db);
  });

  testWidgets('portrait iPad: compact left rail, not the bottom bar', (
    tester,
  ) async {
    final db = await seededDb();
    await pumpShell(tester, db, physical: portraitPhysical);

    expect(find.byType(PosNavRailCompact), findsOneWidget);
    expect(find.byType(PosNavBar), findsNothing);

    await disposeShell(tester, db);
  });

  testWidgets('phone (390×844): bottom nav bar, no rail', (tester) async {
    final db = await seededDb();
    // 780×1688 physical @2x → 390×844 logical, under the 600 breakpoint.
    await pumpShell(tester, db, physical: const Size(780, 1688));

    expect(find.byType(PosNavBar), findsOneWidget);
    expect(find.byType(PosNavRail), findsNothing);
    expect(find.byType(PosNavRailCompact), findsNothing);

    await disposeShell(tester, db);
  });

  testWidgets('narrow phone (360×800): bottom bar fits, labels never overflow', (
    tester,
  ) async {
    final db = await seededDb();
    // 720×1600 physical @2x → 360×800 logical: the tightest phone the five
    // tabs must fit. A Row-style pill overflows horizontally here, and a
    // RenderFlex overflow fails the test on its own.
    await pumpShell(tester, db, physical: const Size(720, 1600));

    expect(find.byType(PosNavBar), findsOneWidget);
    expect(find.byType(PosNavRail), findsNothing);
    expect(find.text('Sell'), findsWidgets);
    expect(find.text('Settings'), findsWidgets);
    expect(tester.takeException(), isNull);

    await disposeShell(tester, db);
  });

  testWidgets('landscape iPad: cart panel is pinned beside the grid', (
    tester,
  ) async {
    final db = await seededDb();
    await pumpShell(tester, db, physical: landscapePhysical);

    // Empty cart state lives in the pinned panel — no navigation needed.
    expect(find.text('Cart is empty'), findsOneWidget);

    // Tap a product: the panel header updates in place. `.first` is the Sell
    // grid's card (tree order) — the offstage Products tab holds the same text.
    await tester.tap(find.text('Test Product').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('CART · 1 item'), findsOneWidget);

    // The narrow-only sticky cart bar is NOT used in the split layout.
    expect(find.textContaining('View Cart'), findsNothing);

    await disposeShell(tester, db);
  });

  testWidgets('portrait iPad: tapping a product raises the sticky cart bar', (
    tester,
  ) async {
    final db = await seededDb();
    await pumpShell(tester, db, physical: portraitPhysical);

    expect(find.text('Cart is empty'), findsNothing);

    await tester.tap(find.text('Test Product').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // The sticky bar above the nav shows count · total, then opens Cart.
    expect(find.text('1 item · ₱30.00'), findsOneWidget);
    expect(find.text('View Cart'), findsOneWidget);
    // No pinned panel in portrait.
    expect(find.text('CART · 1 item'), findsNothing);

    await disposeShell(tester, db);
  });

  testWidgets('Settings form is capped and centred, not edge-to-edge', (
    tester,
  ) async {
    final db = await seededDb();
    await pumpShell(tester, db, physical: landscapePhysical);

    // Go to Settings — works for both the rail (landscape) and the bar.
    final nav = find.byWidgetPredicate(
      (w) => w is PosNavRail || w is PosNavBar,
    );
    await tester.tap(find.descendant(of: nav, matching: find.text('Settings')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // A form field must sit inside the 560 pt cap on the 1080 pt canvas —
    // 560 + 16pt padding on each side is the ceiling.
    final field = find.byType(PosField).first;
    final fieldBox = tester.getRect(field);
    final canvasWidth = tester.getSize(find.byType(Scaffold).first).width;
    expect(canvasWidth, greaterThan(900), reason: 'landscape is wide');
    expect(
      fieldBox.width,
      lessThanOrEqualTo(562),
      reason: 'form fields must be capped, not stretched to 1080pt',
    );
    // Centred within the content area (right of the rail): the field's centre
    // must sit on the midpoint between the rail edge and the canvas edge.
    final railRight = tester.getRect(find.byType(PosNavRail)).right;
    final contentCenter = (railRight + canvasWidth) / 2;
    expect(
      (fieldBox.center.dx - contentCenter).abs(),
      lessThan(2.0),
      reason: 'the capped column must be centred in the content area',
    );

    await disposeShell(tester, db);
  });
}
