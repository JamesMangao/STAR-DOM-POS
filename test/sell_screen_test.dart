import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:stardom_pos/data/db.dart';
import 'package:stardom_pos/data/db_open.dart';
import 'package:stardom_pos/data/device.dart';
import 'package:stardom_pos/main.dart';

/// Sell-screen rules that guard a live sale (Phase: UI/UX pro-max):
///
///  * the red "out of stock" overlay must also BLOCK the tap — before this,
///    a sold-out card still slipped into the cart;
///  * an exact barcode typed/scanned into the search box skips the grid and
///    adds the item, then clears the field.
void main() {
  Future<AppDatabase> seededDb({
    String stockStatus = 'In Stock',
    int stock = 5,
    String? barcode,
  }) async {
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
        barcode: barcode,
        // The boot sweep deactivates photo-less products, so the fixture
        // must carry art or the grid is legitimately empty.
        imagePath: 'product-images/test.png',
        stockQuantity: stock,
        isActive: true,
        stockStatus: stockStatus,
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

  Future<void> pumpShell(WidgetTester tester, AppDatabase db) async {
    tester.view.physicalSize = const Size(1620, 2160); // portrait iPad
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

  Future<void> disposeShell(WidgetTester tester, AppDatabase db) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await db.close();
  }

  testWidgets('out-of-stock tap is refused with a toast — cart stays empty', (
    tester,
  ) async {
    final db = await seededDb(stockStatus: 'Out of Stock', stock: 0);
    await pumpShell(tester, db);

    await tester.tap(find.text('Test Product').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.textContaining('out of stock'),
      findsOneWidget,
      reason: 'the refusal must SAY why and where to fix it',
    );
    expect(
      find.textContaining('View Cart'),
      findsNothing,
      reason: 'nothing may enter the cart through the overlay',
    );

    await disposeShell(tester, db);
  });

  testWidgets('in-stock tap still adds (the guard blocks nothing else)', (
    tester,
  ) async {
    final db = await seededDb();
    await pumpShell(tester, db);

    await tester.tap(find.text('Test Product').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('1 item · ₱30.00'), findsOneWidget);
    expect(find.textContaining('out of stock'), findsNothing);

    await disposeShell(tester, db);
  });

  testWidgets('exact barcode in search adds the item and clears the field', (
    tester,
  ) async {
    final db = await seededDb(barcode: '4801234567890');
    await pumpShell(tester, db);

    await tester.enterText(find.byType(TextField).first, '4801234567890');
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('1 item · ₱30.00'), findsOneWidget,
        reason: 'the scan went straight into the cart');
    expect(find.text('Added “Test Product”.'), findsOneWidget,
        reason: 'the add is confirmed out loud');
    final field = tester.widget<TextField>(find.byType(TextField).first);
    expect(field.controller!.text, isEmpty,
        reason: 'the box clears so the next scan is clean');

    await disposeShell(tester, db);
  });
}
