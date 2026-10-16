import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:sqlite3/sqlite3.dart';
// ignore: unused_import - loads the bundled sqlite3 native library for tests
import 'package:sqlite3_flutter_libs/sqlite3_flutter_libs.dart';

import 'package:stardom_pos/data/bundle.dart';
import 'package:stardom_pos/data/db.dart';
import 'package:stardom_pos/data/logic.dart';

/// Deterministic clock: tests must not depend on wall time (F6).
DateTime fixedClock() => DateTime.utc(2026, 1, 15, 10, 30, 0);

void main() {
  sqlite3.openInMemory();

  late AppDatabase db;

  setUp(() => db = AppDatabase(NativeDatabase.memory(), clock: fixedClock));
  tearDown(() async => db.close());

  // --------------------------------------------------------------- helpers

  Future<void> seedStore([String id = 'store-1']) async {
    final now = DateTime.utc(2026, 1, 1);
    await db.upsertStore(
      Store(
        id: id,
        name: 'STAR:DOM',
        tagline: 't',
        ownerId: 'owner-1',
        receiptName: 'STAR:DOM',
        receiptTin: '000-000-000-000',
        receiptAddress: 'Santa Rosa',
        receiptAccreditation: 'PTU-2026-00015',
        receiptFooter: 'Salamat!',
        currency: 'PHP',
        createdAt: now,
        updatedAt: now,
      ),
    );
  }

  Future<void> seedDevice([String id = 'device-1', String code = 'A1']) async {
    final now = DateTime.utc(2026, 1, 1);
    await db.upsertDevice(
      Device(
        id: id,
        storeId: 'store-1',
        deviceName: 'Phone',
        deviceCode: code,
        isActive: true,
        lastSyncAt: null,
        createdAt: now,
        updatedAt: now,
      ),
    );
  }

  /// Direct insert — no outbox noise, so outbox assertions stay exact.
  Future<void> seedProduct(
    String id, {
    String name = 'Sticker',
    double price = 100.0,
    int stock = 50,
  }) async {
    await db
        .into(db.products)
        .insert(
          ProductsCompanion.insert(
            id: id,
            storeId: 'store-1',
            name: name,
            price: price,
            stockQuantity: Value(stock),
            updatedAt: DateTime.utc(2026, 1, 1),
          ),
        );
  }

  Future<void> seedCashMethod([String id = 'pm-cash']) async {
    await db
        .into(db.paymentMethods)
        .insert(
          PaymentMethodsCompanion.insert(
            id: id,
            storeId: 'store-1',
            name: 'Cash',
            type: 'cash',
            updatedAt: DateTime.utc(2026, 1, 1),
          ),
        );
  }

  List<OrderItem> oneItem(
    String productId, {
    int qty = 2,
    String name = 'Sticker',
    double price = 100.0,
    String id = '',
  }) => [
    OrderItem(
      id: id,
      orderId: '',
      productId: productId,
      productName: name,
      unitPrice: price,
      quantity: qty,
      lineTotal: price * qty,
      createdAt: DateTime.utc(2026, 1, 1),
    ),
  ];

  Future<int> count(String table) async =>
      (await db.customSelect('SELECT COUNT(*) AS c FROM $table').getSingle())
          .read<int>('c');

  Future<int> saleOutboxCount() async =>
      (await db
              .customSelect(
                "SELECT COUNT(*) AS c FROM sync_outbox WHERE entity = 'sale'",
              )
              .getSingle())
          .read<int>('c');

  Future<Map<String, dynamic>> rawRow(String table, String id) async =>
      (await db
              .customSelect(
                'SELECT * FROM $table WHERE id = ?',
                variables: [Variable<String>(id)],
              )
              .getSingle())
          .data;

  // ------------------------------------------------------- createOrder (F1)

  group('createOrder — one transaction', () {
    test('writes order + items + payment + stock + outbox together', () async {
      await seedStore();
      await seedDevice();
      await seedProduct('p1');
      await seedCashMethod();

      final order = await db.createOrder(
        storeId: 'store-1',
        deviceId: 'device-1',
        orderNo: 'A1-260115-001',
        subtotal: 200,
        discount: 0,
        total: 200,
        paymentMethodId: 'pm-cash',
        amountReceived: 200,
        changeAmount: 0,
        items: oneItem('p1'),
      );

      expect(order.total, 200);
      expect(order.status, 'completed');
      expect(await count('orders'), 1);
      expect(await count('order_items'), 1);
      expect(await count('payments'), 1);
      expect(await count('stock_events'), 1);
      expect(await saleOutboxCount(), 1);
      expect(await db.stockOf('p1'), -2);

      // snapshot fields, set at sale time in the same txn
      final payment = await (db.select(
        db.payments,
      )..where((t) => t.orderId.equals(order.id))).getSingle();
      expect(payment.methodName, 'Cash');
      expect(payment.methodType, 'cash');
      expect(payment.amount, 200);
      final item = await (db.select(
        db.orderItems,
      )..where((t) => t.orderId.equals(order.id))).getSingle();
      expect(item.productName, 'Sticker');
      expect(item.unitPrice, 100);
    });

    test('allocates order_no inside the txn: seq increments per device/day',
        () async {
      await seedStore();
      await seedDevice();
      await seedProduct('p1');

      final a = await db.createOrder(
        storeId: 'store-1',
        deviceId: 'device-1',
        subtotal: 10,
        discount: 0,
        total: 10,
        items: oneItem('p1', qty: 1),
      );
      final b = await db.createOrder(
        storeId: 'store-1',
        deviceId: 'device-1',
        subtotal: 10,
        discount: 0,
        total: 10,
        items: oneItem('p1', qty: 1),
      );

      expect(a.orderNo, 'A1-260115-001');
      expect(b.orderNo, 'A1-260115-002');
    });

    test('snapshots payment method name + type at sale time', () async {
      await seedStore();
      await seedDevice();
      await seedProduct('p1');
      await seedCashMethod();

      final order = await db.createOrder(
        storeId: 'store-1',
        deviceId: 'device-1',
        subtotal: 100,
        discount: 0,
        total: 100,
        paymentMethodId: 'pm-cash',
        items: oneItem('p1', qty: 1),
      );

      // Editing the method later must not rewrite an issued receipt.
      await db
          .into(db.paymentMethods)
          .insertOnConflictUpdate(
            PaymentMethodsCompanion(
              id: const Value('pm-cash'),
              storeId: const Value('store-1'),
              name: const Value('Cash (renamed)'),
              type: const Value('bank'),
              updatedAt: Value(DateTime.utc(2026, 3, 1)),
            ),
          );

      final payment = await (db.select(
        db.payments,
      )..where((t) => t.orderId.equals(order.id))).getSingle();
      expect(payment.methodName, 'Cash');
      expect(payment.methodType, 'cash');
      expect(payment.methodId, 'pm-cash');
      expect(payment.amount, 100);
    });

    test('snapshots item name + unit_price at sale time', () async {
      await seedStore();
      await seedDevice();
      await seedProduct('p1', name: 'Sticker', price: 100);
      await seedCashMethod();

      final order = await db.createOrder(
        storeId: 'store-1',
        deviceId: 'device-1',
        subtotal: 100,
        discount: 0,
        total: 100,
        paymentMethodId: 'pm-cash',
        items: oneItem('p1', name: 'Sticker', price: 100, qty: 1),
      );

      // Rename + reprice the product afterwards.
      await (db.update(db.products)..where((t) => t.id.equals('p1'))).write(
        const ProductsCompanion(
          name: Value('Sticker XL'),
          price: Value(199.0),
        ),
      );

      final item = await (db.select(
        db.orderItems,
      )..where((t) => t.orderId.equals(order.id))).getSingle();
      expect(item.productName, 'Sticker');
      expect(item.unitPrice, 100);
    });

    test('rollback: a mid-txn failure leaves all five tables empty', () async {
      await seedStore();
      await seedDevice();
      await seedProduct('p1');

      // Two items sharing a primary key -> the second insert throws.
      final dup = [
        ...oneItem('p1', id: 'dup'),
        ...oneItem('p1', id: 'dup'),
      ];

      await expectLater(
        db.createOrder(
          storeId: 'store-1',
          deviceId: 'device-1',
          orderNo: 'A1-260115-001',
          subtotal: 200,
          discount: 0,
          total: 200,
          items: dup,
        ),
        throwsA(anything),
      );

      expect(await count('orders'), 0);
      expect(await count('order_items'), 0);
      expect(await count('payments'), 0);
      expect(await count('stock_events'), 0);
      expect(await saleOutboxCount(), 0);
      expect(await count('sync_outbox'), 0);
    });
  });

  // --------------------------------------------------------- voidOrder (F3)

  group('voidOrder — append-only', () {
    Future<Order> makeSale() async {
      await seedStore();
      await seedDevice();
      await seedProduct('p1', stock: 100);
      await seedCashMethod();
      return db.createOrder(
        storeId: 'store-1',
        deviceId: 'device-1',
        orderNo: 'A1-260115-001',
        subtotal: 300,
        discount: 0,
        total: 300,
        paymentMethodId: 'pm-cash',
        amountReceived: 300,
        changeAmount: 0,
        items: oneItem('p1', qty: 3, price: 100),
      );
    }

    test('writes a void row, reverses stock, enqueues outbox, keeps the order '
        'row byte-identical', () async {
      final order = await makeSale();
      final before = await rawRow('orders', order.id);
      expect(await db.stockOf('p1'), -3);

      final outcome = await db.voidOrder(
        order.id,
        reason: 'Customer cancelled',
        deviceId: 'device-1',
        storeId: 'store-1',
      );

      expect(outcome, VoidOutcome.created);
      expect(await count('order_voids'), 1);
      expect(await db.isVoided(order.id), true);
      expect(await db.stockOf('p1'), 0);

      // The order row must be untouched — no status flip, no updated_at.
      final after = await rawRow('orders', order.id);
      expect(after, equals(before));

      final voidOutbox =
          await db.select(db.syncOutbox).get();
      expect(
        voidOutbox.where((e) => e.entity == 'void').length,
        1,
      );
    });

    test('voiding twice -> one void row, stock reversed once', () async {
      final order = await makeSale();
      await db.voidOrder(order.id,
          reason: 'first', deviceId: 'device-1', storeId: 'store-1');
      final second = await db.voidOrder(order.id,
          reason: 'second', deviceId: 'device-1', storeId: 'store-1');

      expect(second, VoidOutcome.alreadyVoided);
      expect(await count('order_voids'), 1);
      expect(await count('stock_events'), 2); // one sale + one reversal
      expect(await db.stockOf('p1'), 0);
    });

    test('voiding an unknown order changes nothing', () async {
      await seedStore();
      final outcome = await db.voidOrder('nope',
          reason: 'x', deviceId: 'device-1', storeId: 'store-1');
      expect(outcome, VoidOutcome.notFound);
      expect(await count('order_voids'), 0);
      expect(await count('stock_events'), 0);
    });
  });

  // -------------------------------------------- activeOrders / reporting (F3)

  group('activeOrders — the one helper every total uses', () {
    Future<void> setUpSales() async {
      await seedStore();
      await seedDevice();
      await seedProduct('p1', stock: 100);
      await seedCashMethod();
      await db.createOrder(
        storeId: 'store-1',
        deviceId: 'device-1',
        subtotal: 100,
        discount: 0,
        total: 100,
        paymentMethodId: 'pm-cash',
        items: oneItem('p1', qty: 1),
      );
      final toVoid = await db.createOrder(
        storeId: 'store-1',
        deviceId: 'device-1',
        subtotal: 50,
        discount: 0,
        total: 50,
        paymentMethodId: 'pm-cash',
        items: oneItem('p1', qty: 1),
      );
      await db.voidOrder(toVoid.id,
          reason: 'oops', deviceId: 'device-1', storeId: 'store-1');
    }

    test('excludes voided orders', () async {
      await setUpSales();
      final active = await db.activeOrders('store-1');
      expect(active.length, 1);
      expect(active.single.total, 100);
    });

    test('voidedCount counts orders with a void row', () async {
      await setUpSales();
      expect(await db.voidedCount('store-1'), 1);
      expect((await db.voidedOrders('store-1')).single.total, 50);
    });

    test('dailyTotal excludes voided orders', () async {
      await setUpSales();
      expect(await db.dailyTotal('store-1'), 100);
    });

    test('cashExpected excludes voided cash orders', () async {
      await setUpSales();
      expect(
        await db.cashExpected(
          storeId: 'store-1',
          businessDate: fixedClock(),
          cashPaymentMethodId: 'pm-cash',
        ),
        100,
      );
    });

    test('chip derives Voided from order_voids, else outbox state', () async {
      await setUpSales();
      final all = await db.listOrders('store-1');
      final voided = all.firstWhere((o) => o.total == 50);
      final active = all.firstWhere((o) => o.total == 100);

      // Voided wins outright, whatever the outbox says.
      expect(await db.chipFor(voided), OrderChip.voided);
      // Nothing has been pushed yet -> Pending.
      expect(await db.chipFor(active), OrderChip.pending);

      // Once the sale's outbox row syncs, the same order reads Synced.
      final sale = (await db.select(db.syncOutbox).get())
          .firstWhere((e) => e.entity == 'sale' && e.entityId == active.id);
      await db.markOutboxSynced(sale.id);
      expect(await db.chipFor(active), OrderChip.synced);
    });
  });

  // ---------------------------------------------------------------- sync (F2)

  group('sync — bundles and remote voids', () {
    test('sale outbox payload is ONE bundle of the whole transaction',
        () async {
      await seedStore();
      await seedDevice();
      await seedProduct('p1');
      await seedCashMethod();
      final order = await db.createOrder(
        storeId: 'store-1',
        deviceId: 'device-1',
        subtotal: 200,
        discount: 0,
        total: 200,
        paymentMethodId: 'pm-cash',
        items: oneItem('p1'),
      );

      final row = await (db.select(db.syncOutbox)
            ..where((t) => t.entity.equals('sale')))
          .getSingle();
      expect(row.entityId, order.id);
      final payload = jsonDecode(row.payload) as Map<String, dynamic>;
      expect(
        payload.keys,
        containsAll([
          SaleBundle.order,
          SaleBundle.items,
          SaleBundle.payment,
          SaleBundle.stockEvents,
        ]),
      );
      expect(payload[SaleBundle.order]['order_no'], order.orderNo);
      expect((payload[SaleBundle.items] as List).length, 1);
      expect(payload[SaleBundle.payment]['method_name'], 'Cash');
      expect((payload[SaleBundle.stockEvents] as List).length, 1);
    });

    test('replaying the sale bundle twice -> 1 order, N items, 1 payment, '
        'N stock events (fake api)', () async {
      await seedStore();
      await seedDevice();
      await seedProduct('p1');
      await seedProduct('p2');
      await seedCashMethod();

      await db.createOrder(
        storeId: 'store-1',
        deviceId: 'device-1',
        subtotal: 300,
        discount: 0,
        total: 300,
        paymentMethodId: 'pm-cash',
        items: [
          ...oneItem('p1', qty: 2),
          ...oneItem('p2', qty: 1, name: 'Pin', price: 100),
        ],
      );

      final row = await (db.select(db.syncOutbox)
            ..where((t) => t.entity.equals('sale')))
          .getSingle();
      final payload = jsonDecode(row.payload) as Map<String, dynamic>;

      final server = BundleServer();
      expect(server.apply(payload), greaterThan(0));
      expect(server.orders.length, 1);
      expect(server.items.length, 2);
      expect(server.payments.length, 1);
      expect(server.stockEvents.length, 2);

      // Replay the exact same bundle: everything is a no-op.
      expect(server.apply(payload), 0);
      expect(server.orders.length, 1);
      expect(server.items.length, 2);
      expect(server.payments.length, 1);
      expect(server.stockEvents.length, 2);
    });

    test('void outbox carries order_voids + reversal stock, never the order',
        () async {
      await seedStore();
      await seedDevice();
      await seedProduct('p1', stock: 100);
      await seedCashMethod();
      final order = await db.createOrder(
        storeId: 'store-1',
        deviceId: 'device-1',
        subtotal: 100,
        discount: 0,
        total: 100,
        paymentMethodId: 'pm-cash',
        items: oneItem('p1', qty: 1),
      );
      await db.voidOrder(order.id,
          reason: 'x', deviceId: 'device-1', storeId: 'store-1');

      final row = await (db.select(db.syncOutbox)
            ..where((t) => t.entity.equals('void')))
          .getSingle();
      final payload = jsonDecode(row.payload) as Map<String, dynamic>;
      expect(payload.containsKey(SaleBundle.order), false);
      expect(payload[VoidBundle.voidRow]['order_id'], order.id);
      expect((payload[VoidBundle.stockEvents] as List).length, 1);

      final server = BundleServer();
      server.apply(payload);
      expect(server.voids.length, 1);
      expect(server.orders.length, 0); // a void never writes an order row
    });

    test('pull of a remote void inserts order_voids, order untouched',
        () async {
      await seedStore();
      await seedDevice();
      await seedProduct('p1', stock: 100);
      await seedCashMethod();
      final order = await db.createOrder(
        storeId: 'store-1',
        deviceId: 'device-1',
        subtotal: 100,
        discount: 0,
        total: 100,
        paymentMethodId: 'pm-cash',
        items: oneItem('p1', qty: 1),
      );
      final before = await rawRow('orders', order.id);

      final inserted = await db.applyRemoteVoid({
        'id': 'void-remote-1',
        'order_id': order.id,
        'device_id': 'device-2',
        'reason': 'remote void',
        'voided_at': '2026-01-15T11:00:00.000Z',
        'created_at': '2026-01-15T11:00:00.000Z',
      });

      expect(inserted, true);
      expect(await db.isVoided(order.id), true);
      expect(await rawRow('orders', order.id), equals(before));
      expect((await db.activeOrders('store-1')).isEmpty, true);

      // Idempotent: applying the same remote void again inserts nothing.
      expect(
        await db.applyRemoteVoid({
          'id': 'void-remote-1',
          'order_id': order.id,
          'device_id': 'device-2',
          'reason': 'remote void',
          'voided_at': '2026-01-15T11:00:00.000Z',
        }),
        false,
      );
      expect(await count('order_voids'), 1);
    });
  });

  // ------------------------------------------------------------ day close (F5)

  group('closeDay — one row per (business_date, device_id)', () {
    Future<void> seedDay() async {
      await seedStore();
      await seedDevice();
      await seedProduct('p1', stock: 100);
      await seedCashMethod();
      await db.createOrder(
        storeId: 'store-1',
        deviceId: 'device-1',
        subtotal: 250,
        discount: 0,
        total: 250,
        paymentMethodId: 'pm-cash',
        items: oneItem('p1', qty: 1),
      );
      final voided = await db.createOrder(
        storeId: 'store-1',
        deviceId: 'device-1',
        subtotal: 75,
        discount: 0,
        total: 75,
        paymentMethodId: 'pm-cash',
        items: oneItem('p1', qty: 1),
      );
      await db.voidOrder(voided.id,
          reason: 'x', deviceId: 'device-1', storeId: 'store-1');
    }

    test('expected cash comes from active orders; variance = actual - expected',
        () async {
      await seedDay();
      final close = await db.closeDay(
        storeId: 'store-1',
        deviceId: 'device-1',
        businessDate: fixedClock(),
        cashPaymentMethodId: 'pm-cash',
        cashActual: 260,
        closedBy: 'cashier-1',
      );
      expect(close.cashExpected, 250);
      expect(close.cashActual, 260);
      expect(close.variance, 10);
    });

    test('closing the same day twice updates one row (LWW), no duplicate',
        () async {
      await seedDay();
      await db.closeDay(
        storeId: 'store-1',
        deviceId: 'device-1',
        businessDate: fixedClock(),
        cashPaymentMethodId: 'pm-cash',
        cashActual: 260,
        closedBy: 'cashier-1',
      );
      final second = await db.closeDay(
        storeId: 'store-1',
        deviceId: 'device-1',
        businessDate: fixedClock(),
        cashPaymentMethodId: 'pm-cash',
        cashActual: 250,
        closedBy: 'cashier-2',
      );

      expect(await count('day_closes'), 1);
      expect(second.cashActual, 250);
      expect(second.variance, 0);
      expect(second.closedBy, 'cashier-2');
    });
  });

  // ------------------------------------------------------------------ misc

  group('timestamp + integrity guarantees', () {
    test('clock injection: every stored timestamp is the fixed UTC clock',
        () async {
      await seedStore();
      await seedDevice();
      await seedProduct('p1');
      final order = await db.createOrder(
        storeId: 'store-1',
        deviceId: 'device-1',
        subtotal: 10,
        discount: 0,
        total: 10,
        items: oneItem('p1', qty: 1),
      );
      expect(order.createdAt, fixedClock());
      expect(order.createdAt.isUtc, true);

      // Round-trips through storage as the same UTC instant.
      final reread = await db.orderById(order.id);
      expect(reread!.createdAt.toUtc(), fixedClock());
    });

    test('stock is the sum of its delta events', () async {
      await seedStore();
      await seedDevice();
      await seedProduct('p1', stock: 100);
      await db.adjustStock('p1', 10, 'adjustment',
          deviceId: 'device-1', storeId: 'store-1');
      await db.adjustStock('p1', -3, 'adjustment',
          deviceId: 'device-1', storeId: 'store-1');
      expect(await db.stockOf('p1'), 7);
    });

    test('order_no is unique per store', () async {
      await seedStore();
      await seedDevice();
      await seedProduct('p1');
      await db.createOrder(
        storeId: 'store-1',
        deviceId: 'device-1',
        orderNo: 'A1-260115-001',
        subtotal: 10,
        discount: 0,
        total: 10,
        items: oneItem('p1', qty: 1),
      );
      await expectLater(
        db.createOrder(
          storeId: 'store-1',
          deviceId: 'device-1',
          orderNo: 'A1-260115-001',
          subtotal: 10,
          discount: 0,
          total: 10,
          items: oneItem('p1', qty: 1),
        ),
        throwsA(anything),
      );
      expect(await count('orders'), 1);
    });
  });

  // ------------------------------------------------- outbox dedupe semantics

  group('outbox — same-instant re-enqueue', () {
    Product product(String name) => Product(
      id: 'p1',
      storeId: 'store-1',
      categoryId: null,
      name: name,
      price: 10,
      barcode: null,
      imagePath: null,
      stockQuantity: 0,
      isActive: true,
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 1),
      deletedAt: null,
      syncedAt: null,
    );

    test('enqueue twice at the same instant -> one row, latest payload',
        () async {
      await seedStore();
      // fixed clock -> identical (entity, entity_id, updated_at) -> same id
      await db.upsertProduct(product('First'),
          deviceId: 'device-1', storeId: 'store-1');
      await db.upsertProduct(product('Second'),
          deviceId: 'device-1', storeId: 'store-1');

      final rows = await (db.select(
        db.syncOutbox,
      )..where((t) => t.entity.equals('products'))).get();
      expect(rows.length, 1);
      expect(rows.single.payload, contains('Second'));
      expect(rows.single.syncedAt, isNull);
    });

    test('enqueue after sent -> no duplicate, sent row not resurrected or '
        'overwritten, backoff state kept', () async {
      await seedStore();
      await db.upsertProduct(product('First'),
          deviceId: 'device-1', storeId: 'store-1');
      final first = (await (db.select(
        db.syncOutbox,
      )..where((t) => t.entity.equals('products'))).get())
          .single;
      expect(first.syncedAt, isNull);

      // attempts=1, then ack it (sent).
      await db.markOutboxFailed(first.id, 'boom');
      await db.markOutboxSynced(first.id);

      // Same-instant re-enqueue of the same deterministic id.
      await db.upsertProduct(product('Third'),
          deviceId: 'device-1', storeId: 'store-1');

      final rows = await (db.select(
        db.syncOutbox,
      )..where((t) => t.entity.equals('products'))).get();
      expect(rows.length, 1); // no duplicate
      expect(rows.single.syncedAt, isNotNull); // not resurrected
      expect(rows.single.payload, contains('First')); // payload unchanged
      expect(rows.single.attempts, 1); // backoff state preserved
    });
  });
}
