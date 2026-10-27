import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:sqlite3/sqlite3.dart';

import 'package:stardom_pos/data/bundle.dart';
import 'package:stardom_pos/data/db.dart';
import 'package:stardom_pos/data/logic.dart';
import 'package:stardom_pos/data/sync_policy.dart';

/// Deterministic clock: tests must not depend on wall time (F6). Mutable so a
/// test can move "now" across a business-day boundary without opening a second
/// database (two AppDatabase instances over one executor is a drift warning).
DateTime fixedClock() => DateTime.utc(2026, 1, 15, 10, 30, 0);

void main() {
  sqlite3.openInMemory();

  late AppDatabase db;
  late DateTime now;

  setUp(() {
    now = fixedClock();
    db = AppDatabase(NativeDatabase.memory(), clock: () => now);
  });
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

  /// A one-row advanced PullCursor, exactly the way sync.dart's pull loop
  /// writes them — so a stored value parses back non-empty.
  PullCursor cursorAt(DateTime at, String col) =>
      const PullCursor(cursorValue: null, lastPk: null).advance([
        {'id': 'row-1', col: at.toIso8601String()},
      ], col);

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

    test(
      'allocates order_no inside the txn: seq increments per device/day',
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
      },
    );

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
        const ProductsCompanion(name: Value('Sticker XL'), price: Value(199.0)),
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
      final dup = [...oneItem('p1', id: 'dup'), ...oneItem('p1', id: 'dup')];

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

      final voidOutbox = await db.select(db.syncOutbox).get();
      expect(voidOutbox.where((e) => e.entity == 'void').length, 1);
    });

    test('voiding twice -> one void row, stock reversed once', () async {
      final order = await makeSale();
      await db.voidOrder(
        order.id,
        reason: 'first',
        deviceId: 'device-1',
        storeId: 'store-1',
      );
      final second = await db.voidOrder(
        order.id,
        reason: 'second',
        deviceId: 'device-1',
        storeId: 'store-1',
      );

      expect(second, VoidOutcome.alreadyVoided);
      expect(await count('order_voids'), 1);
      expect(await count('stock_events'), 2); // one sale + one reversal
      expect(await db.stockOf('p1'), 0);
    });

    test('voiding an unknown order changes nothing', () async {
      await seedStore();
      final outcome = await db.voidOrder(
        'nope',
        reason: 'x',
        deviceId: 'device-1',
        storeId: 'store-1',
      );
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
      await db.voidOrder(
        toVoid.id,
        reason: 'oops',
        deviceId: 'device-1',
        storeId: 'store-1',
      );
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
      final sale = (await db.select(db.syncOutbox).get()).firstWhere(
        (e) => e.entity == 'sale' && e.entityId == active.id,
      );
      await db.markOutboxSynced(sale.id);
      expect(await db.chipFor(active), OrderChip.synced);
    });
  });

  // ---------------------------------------------------------------- sync (F2)

  group('sync — bundles and remote voids', () {
    test(
      'sale outbox payload is ONE bundle of the whole transaction',
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

        final row = await (db.select(
          db.syncOutbox,
        )..where((t) => t.entity.equals('sale'))).getSingle();
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
      },
    );

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

      final row = await (db.select(
        db.syncOutbox,
      )..where((t) => t.entity.equals('sale'))).getSingle();
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

    test(
      'void outbox carries order_voids + reversal stock, never the order',
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
        await db.voidOrder(
          order.id,
          reason: 'x',
          deviceId: 'device-1',
          storeId: 'store-1',
        );

        final row = await (db.select(
          db.syncOutbox,
        )..where((t) => t.entity.equals('void'))).getSingle();
        final payload = jsonDecode(row.payload) as Map<String, dynamic>;
        expect(payload.containsKey(SaleBundle.order), false);
        expect(payload[VoidBundle.voidRow]['order_id'], order.id);
        expect((payload[VoidBundle.stockEvents] as List).length, 1);

        final server = BundleServer();
        server.apply(payload);
        expect(server.voids.length, 1);
        expect(server.orders.length, 0); // a void never writes an order row
      },
    );

    test(
      'pull of a remote void inserts order_voids, order untouched',
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
      },
    );
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
      await db.voidOrder(
        voided.id,
        reason: 'x',
        deviceId: 'device-1',
        storeId: 'store-1',
      );
    }

    test(
      'expected cash comes from active orders; variance = actual - expected',
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
      },
    );

    test(
      'closing the same day twice updates one row (LWW), no duplicate',
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
      },
    );
  });

  // ------------------------------------------------------------------ misc

  group('timestamp + integrity guarantees', () {
    test(
      'clock injection: every stored timestamp is the fixed UTC clock',
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
      },
    );

    test('stock is the sum of its delta events', () async {
      await seedStore();
      await seedDevice();
      await seedProduct('p1', stock: 100);
      await db.adjustStock(
        'p1',
        10,
        'adjustment',
        deviceId: 'device-1',
        storeId: 'store-1',
      );
      await db.adjustStock(
        'p1',
        -3,
        'adjustment',
        deviceId: 'device-1',
        storeId: 'store-1',
      );
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
      stockStatus: 'In Stock',
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 1),
      deletedAt: null,
      syncedAt: null,
    );

    test(
      'enqueue twice at the same instant -> one row, latest payload',
      () async {
        await seedStore();
        // fixed clock -> identical (entity, entity_id, updated_at) -> same id
        await db.upsertProduct(
          product('First'),
          deviceId: 'device-1',
          storeId: 'store-1',
        );
        await db.upsertProduct(
          product('Second'),
          deviceId: 'device-1',
          storeId: 'store-1',
        );

        final rows = await (db.select(
          db.syncOutbox,
        )..where((t) => t.entity.equals('products'))).get();
        expect(rows.length, 1);
        expect(rows.single.payload, contains('Second'));
        expect(rows.single.syncedAt, isNull);
      },
    );

    test('enqueue after sent -> no duplicate, sent row not resurrected or '
        'overwritten, backoff state kept', () async {
      await seedStore();
      await db.upsertProduct(
        product('First'),
        deviceId: 'device-1',
        storeId: 'store-1',
      );
      final first = (await (db.select(
        db.syncOutbox,
      )..where((t) => t.entity.equals('products'))).get()).single;
      expect(first.syncedAt, isNull);

      // attempts=1, then ack it (sent).
      await db.markOutboxFailed(first.id, 'boom', attempts: 1);
      await db.markOutboxSynced(first.id);

      // Same-instant re-enqueue of the same deterministic id.
      await db.upsertProduct(
        product('Third'),
        deviceId: 'device-1',
        storeId: 'store-1',
      );

      final rows = await (db.select(
        db.syncOutbox,
      )..where((t) => t.entity.equals('products'))).get();
      expect(rows.length, 1); // no duplicate
      expect(rows.single.syncedAt, isNotNull); // not resurrected
      expect(rows.single.payload, contains('First')); // payload unchanged
      expect(rows.single.attempts, 1); // backoff state preserved
    });

    test(
      'resetOutboxAttempts: re-pull gives parked rows a fresh start but '
      'keeps their last_error and never touches synced rows',
      () async {
        await seedStore();
        await seedDevice();
        await db.upsertProduct(
          product('Sticker'),
          deviceId: 'device-1',
          storeId: 'store-1',
        );
        final row = (await (db.select(
          db.syncOutbox,
        )..where((t) => t.entity.equals('products'))).get()).single;

        // A row the server rejected maxAttempts times: parked, far-future
        // backoff, and the reason recorded.
        await db.markOutboxFailed(
          row.id,
          'attempt 8 failed: HTTP 403: RLS said no',
          attempts: 8,
          nextAttemptAt: DateTime.utc(2026, 3, 1),
        );
        await db.markOutboxSynced(row.id);
        final synced = (await (db.select(
          db.syncOutbox,
        )..where((t) => t.entity.equals('products'))).get()).single;
        expect(synced.syncedAt, isNotNull);

        // Now a second, unsynced row to be the one recovery resets. Its own
        // id, so the deterministic outbox key differs from the synced one.
        await db.upsertProduct(
          Product(
            id: 'p2',
            storeId: 'store-1',
            categoryId: null,
            name: 'Mug',
            price: 10,
            barcode: null,
            imagePath: null,
            stockQuantity: 0,
            isActive: true,
            stockStatus: 'In Stock',
            createdAt: DateTime.utc(2026, 1, 1),
            updatedAt: DateTime.utc(2026, 1, 1),
            deletedAt: null,
            syncedAt: null,
          ),
          deviceId: 'device-1',
          storeId: 'store-1',
        );
        final pending = (await db.pendingOutbox('store-1'))
            .where((r) => r.entity == 'products')
            .single;
        await db.markOutboxFailed(
          pending.id,
          'attempt 8 failed: HTTP 403: RLS said no',
          attempts: 8,
          nextAttemptAt: DateTime.utc(2026, 3, 1),
        );

        await db.resetOutboxAttempts('store-1');

        final after = await (db.select(
          db.syncOutbox,
        )..where((t) => t.id.equals(pending.id))).getSingle();
        expect(after.attempts, 0, reason: 'parked no more');
        expect(
          after.nextAttemptAt,
          isNull,
          reason: 'the old backoff window must not stall the recovery run',
        );
        expect(
          after.lastError,
          'attempt 8 failed: HTTP 403: RLS said no',
          reason: 'the reason stays readable until a new result replaces it',
        );
        final syncedAfter = (await (db.select(
          db.syncOutbox,
        )..where((t) => t.id.equals(synced.id))).getSingle());
        expect(syncedAfter.syncedAt, isNotNull, reason: 'synced stays synced');
        expect(
          syncedAfter.attempts,
          8,
          reason: 'recovery must not rewrite rows that already landed',
        );
      },
    );
  });

  // ---------------------------- applying what the server sends (B1, B2, B3)

  group('applyRemoteRow — a pulled row is stored as the server wrote it', () {
    /// The exact payload shape PostgREST returns for a route write.
    Map<String, dynamic> serverProduct({
      String updatedAt = '2026-02-01T00:00:00Z',
      int stock = 999,
      String name = 'From the server',
    }) => {
      'id': 'p-remote',
      'store_id': 'store-1',
      'name': name,
      'price': 12.50,
      'stock_quantity': stock,
      'is_active': true,
      'created_at': '2026-01-01T00:00:00Z',
      'updated_at': updatedAt,
    };

    test('products: applies, and NEVER enqueues a push back (B1)', () async {
      await seedStore();
      final applied = await db.applyRemoteRow('products', serverProduct());
      expect(applied, isTrue);
      expect(await count('products'), 1);
      expect(
        await count('sync_outbox'),
        0,
        reason:
            'an applied remote row must not enter the outbox: that is the '
            'loop where both devices push each other forever',
      );
    });

    test(
      'products: the server updated_at/created_at are kept as sent (B1)',
      () async {
        await seedStore();
        await db.applyRemoteRow('products', serverProduct());
        // drift stores dateTime columns as unix epoch SECONDS.
        final row = await rawRow('products', 'p-remote');
        expect(
          row['updated_at'],
          DateTime.utc(2026, 2, 1).millisecondsSinceEpoch ~/ 1000,
        );
        expect(
          row['created_at'],
          DateTime.utc(2026, 1, 1).millisecondsSinceEpoch ~/ 1000,
        );
      },
    );

    test(
      'a local edit NEWER than the remote row wins (LWW on every table)',
      () async {
        await seedStore();
        await db
            .into(db.products)
            .insert(
              ProductsCompanion.insert(
                id: 'p-remote',
                storeId: 'store-1',
                name: 'My local name',
                price: 12.50,
                updatedAt: DateTime.utc(2026, 3, 1), // newer than the row
              ),
            );
        final applied = await db.applyRemoteRow('products', serverProduct());
        expect(
          applied,
          isFalse,
          reason: 'the stale remote row must be ignored',
        );
        expect((await rawRow('products', 'p-remote'))['name'], 'My local name');
      },
    );

    test('a remote row NEWER than the local one replaces it', () async {
      await seedStore();
      await db
          .into(db.products)
          .insert(
            ProductsCompanion.insert(
              id: 'p-remote',
              storeId: 'store-1',
              name: 'Old local name',
              price: 1.00,
              updatedAt: DateTime.utc(2026, 1, 1),
            ),
          );
      await db.applyRemoteRow(
        'products',
        serverProduct(updatedAt: '2026-02-01T00:00:00Z'),
      );
      expect((await rawRow('products', 'p-remote'))['name'], 'From the server');
    });

    test('B2: a remote stock_quantity is IGNORED and the mirror is rebuilt '
        'from stock_events', () async {
      await seedStore();
      await db.applyRemoteRow('products', serverProduct(stock: 999));
      expect(
        (await rawRow('products', 'p-remote'))['stock_quantity'],
        0,
        reason: 'the mirror starts empty: no stock event has arrived yet',
      );

      // Now the events arrive — the mirror must equal their sum, not 999.
      await db.applyRemoteRow('stock_events', {
        'id': 'ev-a',
        'store_id': 'store-1',
        'product_id': 'p-remote',
        'delta': -3,
        'reason': 'sale',
        'created_at': '2026-02-01T00:01:00Z',
      });
      await db.applyRemoteRow('stock_events', {
        'id': 'ev-b',
        'store_id': 'store-1',
        'product_id': 'p-remote',
        'delta': 10,
        'reason': 'adjustment',
        'created_at': '2026-02-01T00:02:00Z',
      });
      expect((await rawRow('products', 'p-remote'))['stock_quantity'], 7);

      // A replayed event changes nothing (idempotent pull).
      await db.applyRemoteRow('stock_events', {
        'id': 'ev-a',
        'store_id': 'store-1',
        'product_id': 'p-remote',
        'delta': -3,
        'reason': 'sale',
        'created_at': '2026-02-01T00:01:00Z',
      });
      expect(await count('stock_events'), 2);
      expect((await rawRow('products', 'p-remote'))['stock_quantity'], 7);
    });

    test(
      'the mutating the mirror does not move the product timestamp (B2)',
      () async {
        await seedStore();
        await db.applyRemoteRow('products', serverProduct());
        final before = (await rawRow('products', 'p-remote'))['updated_at'];
        await db.applyRemoteRow('stock_events', {
          'id': 'ev-c',
          'store_id': 'store-1',
          'product_id': 'p-remote',
          'delta': 5,
          'reason': 'adjustment',
          'created_at': '2026-02-01T00:03:00Z',
        });
        expect(
          (await rawRow('products', 'p-remote'))['updated_at'],
          before,
          reason:
              'rewriting updated_at would make this device look newer than '
              'the server and republish the row',
        );
      },
    );

    test('B3: a fresh device receives a whole order history', () async {
      await seedStore();
      await db.applyRemoteRow('devices', {
        'id': 'dev-a',
        'store_id': 'store-1',
        'device_name': 'Counter',
        'device_code': 'A0',
        'is_active': true,
        'created_at': '2026-01-01T00:00:00Z',
        'updated_at': '2026-01-01T00:00:00Z',
      });
      await db.applyRemoteRow('orders', {
        'id': 'o-1',
        'store_id': 'store-1',
        'device_id': 'dev-a',
        'order_no': 'A0-260101-001',
        'subtotal': 30.0,
        'discount': 0.0,
        'total': 30.0,
        'created_at': '2026-01-01T01:00:00Z',
        'updated_at': '2026-01-01T01:00:00Z',
      });
      await db.applyRemoteRow('order_items', {
        'id': 'oi-1',
        'order_id': 'o-1',
        'product_id': 'p-remote',
        'product_name': 'Sticker',
        'unit_price': 30.0,
        'quantity': 1,
        'line_total': 30.0,
        'created_at': '2026-01-01T01:00:00Z',
      });
      await db.applyRemoteRow('payments', {
        'id': 'pay-1',
        'store_id': 'store-1',
        'device_id': 'dev-a',
        'order_id': 'o-1',
        'method_name': 'Cash',
        'method_type': 'cash',
        'amount': 30.0,
        'created_at': '2026-01-01T01:00:00Z',
      });
      await db.applyRemoteRow('order_voids', {
        'id': 'v-1',
        'order_id': 'o-1',
        'device_id': 'dev-a',
        'reason': 'mistake',
        'voided_at': '2026-01-01T02:00:00Z',
        'created_at': '2026-01-01T02:00:00Z',
      });
      await db.applyRemoteRow('day_closes', {
        'id': 'dc-1',
        'store_id': 'store-1',
        'device_id': 'dev-a',
        'business_date': '2026-01-01T00:00:00Z',
        'cash_expected': 30.0,
        'cash_actual': 30.0,
        'variance': 0.0,
        'created_at': '2026-01-01T03:00:00Z',
        'updated_at': '2026-01-01T03:00:00Z',
      });
      await db.applyRemoteRow('settings', {
        'store_id': 'store-1',
        'key': 'store_name',
        'value': 'STAR:DOM',
        'updated_at': '2026-01-01T03:00:00Z',
      });

      expect(await count('devices'), 1);
      expect(await count('orders'), 1);
      expect(await count('order_items'), 1);
      expect(await count('payments'), 1);
      expect(await count('order_voids'), 1);
      expect(await count('day_closes'), 1);
      expect(await db.isVoided('o-1'), isTrue);
      expect(await count('sync_outbox'), 0, reason: 'a pull never enqueues');
    });

    test('a replayed order pull does not duplicate the order', () async {
      await seedStore();
      final order = {
        'id': 'o-1',
        'store_id': 'store-1',
        'device_id': 'dev-a',
        'order_no': 'A0-260101-001',
        'subtotal': 30.0,
        'discount': 0.0,
        'total': 30.0,
        'created_at': '2026-01-01T01:00:00Z',
        'updated_at': '2026-01-01T01:00:00Z',
      };
      expect(await db.applyRemoteRow('orders', order), isTrue);
      expect(await db.applyRemoteRow('orders', order), isFalse);
      expect(await count('orders'), 1);
    });

    test('an unknown table is ignored, not inserted', () async {
      await seedStore();
      expect(await db.applyRemoteRow('not_a_table', {'id': 'x'}), isFalse);
    });

    test('categories: a same-name local twin merges into the server row '
        '(the Sell chips never double)', () async {
      await seedStore();
      // A demo-era local category (created before this device ever pulled)
      // with its own id, plus a local product pointing at it.
      await db
          .into(db.categories)
          .insert(
            CategoriesCompanion.insert(
              id: 'cat-local',
              storeId: 'store-1',
              name: 'Stickers',
              createdAt: Value(DateTime.utc(2026, 1, 1)),
              updatedAt: Value(DateTime.utc(2026, 1, 1)),
            ),
          );
      await db
          .into(db.products)
          .insert(
            ProductsCompanion.insert(
              id: 'p-local',
              storeId: 'store-1',
              name: 'Local sticker',
              price: 10,
              categoryId: const Value('cat-local'),
              stockQuantity: const Value(3),
              updatedAt: DateTime.utc(2026, 1, 1),
            ),
          );

      final applied = await db.applyRemoteRow('categories', {
        'id': 'cat-server',
        'store_id': 'store-1',
        'name': 'Stickers',
        'is_active': true,
        'created_at': '2026-02-01T00:00:00Z',
        'updated_at': '2026-02-01T00:00:00Z',
      });

      expect(applied, isTrue);
      // Exactly ONE row per name, and it is the server's id.
      final rows = await db
          .customSelect(
            'SELECT id FROM categories WHERE name = ?',
            variables: [Variable<String>('Stickers')],
          )
          .get();
      expect(rows.map((r) => r.data['id']), [
        'cat-server',
      ], reason: 'the pulled row must not double an existing same-name chip');
      // The local product follows the server id — no orphaned category.
      expect(
        (await rawRow('products', 'p-local'))['category_id'],
        'cat-server',
      );
      expect(await count('categories'), 1);
      expect(await count('products'), 1);
    });

    test('categories: a local twin NEWER than the remote row keeps its content '
        'but ADOPTS the server id', () async {
      await seedStore();
      await db
          .into(db.categories)
          .insert(
            CategoriesCompanion.insert(
              id: 'cat-local',
              storeId: 'store-1',
              name: 'Stickers',
              sortOrder: const Value(4),
              createdAt: Value(DateTime.utc(2026, 1, 1)),
              updatedAt: Value(DateTime.utc(2026, 3, 1)), // newer than the pull
            ),
          );
      final applied = await db.applyRemoteRow('categories', {
        'id': 'cat-server',
        'store_id': 'store-1',
        'name': 'Stickers',
        'sort_order': 0,
        'is_active': true,
        'created_at': '2026-02-01T00:00:00Z',
        'updated_at': '2026-02-01T00:00:00Z',
      });
      expect(applied, isTrue);
      expect(await count('categories'), 1);
      expect(
        (await rawRow('categories', 'cat-server'))['sort_order'],
        4,
        reason:
            'the newer local content survives on the server\u2019s identity —'
            'the two ids must never drift apart',
      );
    });
  });

  // ------------------------------------------------- the dedupe kernel (006)
  //
  // One name = one row, at every layer: the pull-time merge, the post-pull
  // dedupe and (in migration 006) the server's unique index all use the SAME
  // normalisation, so "PHM" vs "phm" can never survive as two shelf rows.

  group('dedupe kernel — normalised names, tombstones by id only', () {
    test('products: a CASE-variant twin ADOPTS the server id', () async {
      await seedStore();
      await db
          .into(db.products)
          .insert(
            ProductsCompanion.insert(
              id: 'p-local',
              storeId: 'store-1',
              name: 'PHM', // local seed, its own id
              price: 30,
              stockQuantity: const Value(5),
              updatedAt: DateTime.utc(2026, 1, 1),
            ),
          );

      final applied = await db.applyRemoteRow('products', {
        'id': 'p-server',
        'store_id': 'store-1',
        'name': 'phm', // same shelf item, different case
        'price': 30.0,
        'created_at': '2026-02-01T00:00:00Z',
        'updated_at': '2026-02-01T00:00:00Z',
      });

      expect(applied, isTrue);
      expect(
        await count('products'),
        1,
        reason: 'a case-variant twin must not double the Sell grid',
      );
      // The SERVER's id is the identity: 006 refuses a second live row with
      // this name, so a device that kept the local id could never push again.
      expect((await db.listProducts('store-1')).single.id, 'p-server');
      expect(
        (await rawRow('products', 'p-server'))['stock_quantity'],
        5,
        reason:
            'stock carried with no events behind it (CSV import) must '
            'not be zeroed by the identity move',
      );
    });

    test(
      'products: a twin carrying the SAME barcode adopts the server id '
      'instead of tripping the unique barcode index',
      () async {
        await seedStore();
        await db
            .into(db.products)
            .insert(
              ProductsCompanion.insert(
                id: 'p-local',
                storeId: 'store-1',
                name: 'Sticker Pack',
                price: 50,
                barcode: const Value('4800000000017'),
                updatedAt: DateTime.utc(2026, 1, 1),
              ),
            );

        // The wipe-a-phone case: the catalogue seed created a LOCAL twin,
        // the server row carries the same shelf item — same normalised name
        // AND the same barcode (both come from the source inventory sheet).
        final applied = await db.applyRemoteRow('products', {
          'id': 'p-server',
          'store_id': 'store-1',
          'name': 'sticker  pack', // case/spacing variant of the local name
          'price': 50.0,
          'barcode': '4800000000017',
          'created_at': '2026-02-01T00:00:00Z',
          'updated_at': '2026-02-01T00:00:00Z',
        });

        expect(
          applied,
          isTrue,
          reason:
              'the pull must APPLY this row — a throw here is what wedges '
              'the pull behind 25 unapplyable products',
        );
        expect(await count('products'), 1, reason: 'merged, not duplicated');
        expect((await db.listProducts('store-1')).single.id, 'p-server');
        expect(
          (await rawRow('products', 'p-server'))['barcode'],
          '4800000000017',
          reason: 'the scan code must survive the identity move',
        );
      },
    );

    test('products: adopting the server id takes the sales and stock events '
        'with it', () async {
      await seedStore();
      await seedDevice('device-1', 'A1');
      await db
          .into(db.products)
          .insert(
            ProductsCompanion.insert(
              id: 'p-local',
              storeId: 'store-1',
              name: 'Goby',
              price: 30,
              updatedAt: DateTime.utc(2026, 1, 1),
            ),
          );
      await db
          .into(db.orders)
          .insert(
            OrdersCompanion.insert(
              id: 'o-1',
              storeId: 'store-1',
              deviceId: 'device-1',
              orderNo: 'A1-260101-001',
              subtotal: const Value(30),
              total: 30,
              updatedAt: Value(DateTime.utc(2026, 1, 1)),
            ),
          );
      await db
          .into(db.orderItems)
          .insert(
            OrderItemsCompanion.insert(
              id: 'oi-1',
              orderId: 'o-1',
              productId: const Value('p-local'),
              productName: 'Goby',
              unitPrice: 30,
              quantity: 1,
              lineTotal: 30,
            ),
          );
      await db
          .into(db.stockEvents)
          .insert(
            StockEventsCompanion.insert(
              id: 'se-1',
              storeId: 'store-1',
              productId: 'p-local',
              delta: -1,
              reason: 'sale',
              deviceId: const Value('device-1'),
              createdAt: Value(DateTime.utc(2026, 1, 1)),
            ),
          );

      await db.applyRemoteRow('products', {
        'id': 'p-server',
        'store_id': 'store-1',
        'name': 'Goby',
        'price': 30.0,
        'created_at': '2026-02-01T00:00:00Z',
        'updated_at': '2026-02-01T00:00:00Z',
      });

      expect((await rawRow('order_items', 'oi-1'))['product_id'], 'p-server');
      expect((await rawRow('stock_events', 'se-1'))['product_id'], 'p-server');
      expect(
        (await rawRow('products', 'p-server'))['stock_quantity'],
        -1,
        reason: 'the mirror is recomputed from the events that moved over',
      );
      expect(await db.listProducts('store-1'), hasLength(1));
    });

    test('products: a NEWER local twin keeps its content and re-targets its '
        'pending push at the server id', () async {
      await seedStore();
      final local = Product(
        id: 'p-local',
        storeId: 'store-1',
        categoryId: null,
        name: 'PHM',
        price: 35, // the owner corrected the price offline
        barcode: null,
        imagePath: null,
        stockQuantity: 4,
        isActive: true,
        stockStatus: 'In Stock',
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 3, 1), // newer than the pull
        deletedAt: null,
        syncedAt: null,
      );
      await db.upsertProduct(local, deviceId: 'device-1', storeId: 'store-1');
      // upsertProduct stamps its own clock; force the offline edit to be newer
      // than the row about to be pulled.
      await (db.update(db.products)..where((t) => t.id.equals('p-local')))
          .write(ProductsCompanion(updatedAt: Value(DateTime.utc(2026, 3, 1))));

      await db.applyRemoteRow('products', {
        'id': 'p-server',
        'store_id': 'store-1',
        'name': 'phm',
        'price': 30.0,
        'created_at': '2026-02-01T00:00:00Z',
        'updated_at': '2026-02-01T00:00:00Z',
      });

      expect(
        (await rawRow('products', 'p-server'))['price'],
        35.0,
        reason: 'the newer local price stays on screen',
      );
      // The pending create followed the identity — otherwise the next push
      // would re-create the twin and 006 would refuse it forever.
      final pending = await db.pendingOutbox('store-1');
      final productEvents = pending.where((e) => e.entity == 'products');
      expect(productEvents, hasLength(1));
      expect(productEvents.single.entityId, 'p-server');
      expect(productEvents.single.payload, contains('"price":35'));
    });

    test('products: pre-existing duplicates do not break the pull '
        '(getSingleOrNull used to throw mid-page)', () async {
      await seedStore();
      // The bug's precondition: TWO live rows share a normalised name.
      for (final id in ['p-a', 'p-b']) {
        await db
            .into(db.products)
            .insert(
              ProductsCompanion.insert(
                id: id,
                storeId: 'store-1',
                name: id == 'p-a' ? 'Goby' : 'Goby',
                price: 30,
                stockQuantity: const Value(1),
                updatedAt: DateTime.utc(2026, 1, 1),
              ),
            );
      }
      // A re-pull of one of them must APPLY, not throw and wedge the cursor.
      final applied = await db.applyRemoteRow('products', {
        'id': 'p-a',
        'store_id': 'store-1',
        'name': 'Goby',
        'price': 35.0,
        'created_at': '2026-01-01T00:00:00Z',
        'updated_at': '2026-02-01T00:00:00Z',
      });
      expect(applied, isTrue);
      expect((await rawRow('products', 'p-a'))['price'], 35.0);
    });

    test('a TOMBSTONE reaches its exact id only — it never kills the '
        'live twin that survived the server merge', () async {
      await seedStore();
      await db
          .into(db.products)
          .insert(
            ProductsCompanion.insert(
              id: 'p-live',
              storeId: 'store-1',
              name: 'Tamaraw',
              price: 30,
              stockQuantity: const Value(2),
              updatedAt: DateTime.utc(2026, 1, 1),
            ),
          );

      // The server merged the dupes and hard-deletes the loser; an older
      // server build may still send tombstones. Applying one by NAME would
      // delete the survivor.
      final applied = await db.applyRemoteRow('products', {
        'id': 'p-dead',
        'store_id': 'store-1',
        'name': 'tamaraw',
        'price': 30.0,
        'created_at': '2026-01-01T00:00:00Z',
        'updated_at': '2026-03-01T00:00:00Z',
        'deleted_at': '2026-03-01T00:00:00Z',
      });

      expect(
        applied,
        isFalse,
        reason: 'a dead row with no local id is dropped',
      );
      expect(await count('products'), 1);
      expect(
        (await rawRow('products', 'p-live'))['deleted_at'],
        null,
        reason: 'the tombstone must not leak onto the surviving twin',
      );

      // The SAME tombstone for an id this device holds does apply.
      final appliedKnown = await db.applyRemoteRow('products', {
        'id': 'p-live',
        'store_id': 'store-1',
        'name': 'Tamaraw',
        'price': 30.0,
        'created_at': '2026-01-01T00:00:00Z',
        'updated_at': '2026-03-02T00:00:00Z',
        'deleted_at': '2026-03-02T00:00:00Z',
      });
      expect(appliedKnown, isTrue);
      expect(await db.listProducts('store-1'), isEmpty);
    });

    test('payment methods: a pulled same-name twin merges and repoints '
        'orders (the six-Cash case)', () async {
      await seedStore();
      await seedDevice();
      await db
          .into(db.paymentMethods)
          .insert(
            PaymentMethodsCompanion.insert(
              id: 'cash-local',
              storeId: 'store-1',
              name: 'Cash',
              type: 'cash',
              updatedAt: DateTime.utc(2026, 1, 1),
            ),
          );
      await db
          .into(db.orders)
          .insert(
            OrdersCompanion.insert(
              id: 'o-1',
              storeId: 'store-1',
              deviceId: 'device-1',
              orderNo: 'A1-260115-001',
              subtotal: const Value(100),
              total: 100,
              paymentMethodId: const Value('cash-local'),
              updatedAt: Value(DateTime.utc(2026, 1, 2)),
            ),
          );

      final applied = await db.applyRemoteRow('payment_methods', {
        'id': 'cash-server',
        'store_id': 'store-1',
        'name': 'Cash',
        'type': 'cash',
        'created_at': '2026-02-01T00:00:00Z',
        'updated_at': '2026-02-01T00:00:00Z',
      });

      expect(applied, isTrue);
      expect(
        await db.listPaymentMethods('store-1'),
        hasLength(1),
        reason: 'the checkout must show ONE Cash button, not six',
      );
      expect(
        (await rawRow('orders', 'o-1'))['payment_method_id'],
        'cash-server',
        reason: 'history follows the surviving id',
      );
    });

    test('deduplicateProducts: case-variant twins collapse onto the row '
        'with sales history', () async {
      await seedStore();
      await db
          .into(db.products)
          .insert(
            ProductsCompanion.insert(
              id: 'p-keep',
              storeId: 'store-1',
              name: 'Santan',
              price: 30,
              stockQuantity: const Value(1),
              createdAt: Value(DateTime.utc(2026, 1, 1)),
              updatedAt: DateTime.utc(2026, 1, 1),
            ),
          );
      await db
          .into(db.products)
          .insert(
            ProductsCompanion.insert(
              id: 'p-twin',
              storeId: 'store-1',
              name: 'santan ', // case + trailing space variant
              price: 30,
              stockQuantity: const Value(1),
              createdAt: Value(DateTime.utc(2026, 1, 2)),
              updatedAt: DateTime.utc(2026, 1, 2),
            ),
          );
      // The twin carries the only order_items reference: it must win.
      await db
          .into(db.orders)
          .insert(
            OrdersCompanion.insert(
              id: 'o-1',
              storeId: 'store-1',
              deviceId: 'device-1',
              orderNo: 'A1-260115-001',
              subtotal: const Value(30),
              total: 30,
              updatedAt: Value(DateTime.utc(2026, 1, 2)),
            ),
          );
      await db
          .into(db.orderItems)
          .insert(
            OrderItemsCompanion.insert(
              id: 'oi-1',
              orderId: 'o-1',
              productId: const Value('p-twin'),
              productName: 'santan',
              unitPrice: 30,
              quantity: 1,
              lineTotal: 30,
            ),
          );

      // The LOSING twin also carries stock history: it must follow the
      // survivor, or stock silently drops on every merged shelf item.
      await db
          .into(db.stockEvents)
          .insert(
            StockEventsCompanion.insert(
              id: 'se-1',
              storeId: 'store-1',
              productId: 'p-keep',
              delta: 4,
              reason: 'import',
              createdAt: Value(DateTime.utc(2026, 1, 2)),
            ),
          );

      await db.deduplicateProducts('store-1');

      expect(await count('products'), 1);
      expect((await rawRow('products', 'p-twin'))['name'], 'santan ');
      expect((await rawRow('order_items', 'oi-1'))['product_id'], 'p-twin');
      expect(
        (await rawRow('stock_events', 'se-1'))['product_id'],
        'p-twin',
        reason: 'stock history must not be stranded on a deleted row',
      );
      expect(
        (await rawRow('products', 'p-twin'))['stock_quantity'],
        4,
        reason: 'the mirror is rebuilt from the events that moved onto it',
      );
    });

    test(
      'deduplicateDevices retires a stale name WITHOUT deleting a device row',
      () async {
        await seedStore();
        // A referenced twin (the most orders) AND the local device, same name.
        await db
            .into(db.devices)
            .insert(
              DevicesCompanion.insert(
                id: 'dev-old',
                storeId: 'store-1',
                deviceName: 'Booth iPad',
                deviceCode: 'A1',
                createdAt: Value(DateTime.utc(2026, 1, 1)),
                updatedAt: Value(DateTime.utc(2026, 1, 1)),
              ),
            );
        await seedDevice('dev-own', 'A2'); // deviceName 'Phone' by default…
        await (db.update(db.devices)..where((t) => t.id.equals('dev-own')))
            .write(const DevicesCompanion(deviceName: Value('Booth iPad')));
        await db.setLocalSetting('store-1', 'device_id', 'dev-own');
        await db
            .into(db.orders)
            .insert(
              OrdersCompanion.insert(
                id: 'o-1',
                storeId: 'store-1',
                deviceId: 'dev-old',
                orderNo: 'A1-260115-001',
                subtotal: const Value(30),
                total: 30,
                updatedAt: Value(DateTime.utc(2026, 1, 2)),
              ),
            );

        await db.deduplicateDevices('store-1');

        final devs = await db.listDevices('store-1');
        expect(
          devs.map((d) => d.id).toList()..sort(),
          ['dev-old', 'dev-own'],
          reason:
              'a device row is an identity with its own order-number prefix: '
              'the stale one is retired, never deleted',
        );
        expect(
          {for (final d in devs) d.id: d.isActive},
          {'dev-old': false, 'dev-own': true},
          reason:
              'this install stays active; the older re-registration is retired',
        );
        // The sale still belongs to the device that issued its order number.
        expect((await rawRow('orders', 'o-1'))['device_id'], 'dev-old');
      },
    );

    test('the UI guard: liveXByName is normalised and excludes self', () async {
      await seedStore();
      await db
          .into(db.products)
          .insert(
            ProductsCompanion.insert(
              id: 'p1',
              storeId: 'store-1',
              name: 'Gay af',
              price: 30,
              stockQuantity: const Value(1),
              updatedAt: DateTime.utc(2026, 1, 1),
            ),
          );
      expect((await db.liveProductByName('store-1', 'gay  af'))?.id, 'p1');
      expect(
        await db.liveProductByName('store-1', 'GAY AF', excludeId: 'p1'),
        isNull,
        reason: 'editing a row must not collide with itself',
      );
      // A tombstoned row no longer claims the name.
      await db
          .into(db.products)
          .insert(
            ProductsCompanion.insert(
              id: 'p2',
              storeId: 'store-1',
              name: 'Jade',
              price: 30,
              stockQuantity: const Value(1),
              deletedAt: Value(DateTime.utc(2026, 1, 2)),
              updatedAt: DateTime.utc(2026, 1, 2),
            ),
          );
      expect(await db.liveProductByName('store-1', 'jade'), isNull);
      expect(
        (await db.liveCategoryByName('store-1', 'any')),
        isNull,
        reason: 'empty store: the guard must not invent a conflict',
      );
    });
  });

  // ------------------------------------------------- pull cursors (B4)

  group('pull cursors are per table and local (B4)', () {
    test('a cursor round-trips and is never enqueued', () async {
      await seedStore();
      expect((await db.getPullCursor('store-1', 'products')).isEmpty, isTrue);

      await db.setPullCursor(
        'store-1',
        'products',
        const PullCursor(cursorValue: null, lastPk: null).advance([
          {'id': 'p1', 'server_updated_at': '2026-02-01T00:00:00Z'},
        ], 'server_updated_at'),
      );

      final read = await db.getPullCursor('store-1', 'products');
      expect(read.cursorValue, DateTime.utc(2026, 2, 1));
      expect(read.lastPk, 'p1');
      expect(
        await count('sync_outbox'),
        0,
        reason: 'a cursor is device-local state, not store data to push',
      );
      // A different table has its own cursor.
      expect((await db.getPullCursor('store-1', 'orders')).isEmpty, isTrue);
    });
    test('resetPullCursors clears ONLY the pull_cursor keys', () async {
      await seedStore();
      await db.setPullCursor(
        'store-1',
        'orders',
        cursorAt(DateTime.utc(2026, 2, 1), 'server_created_at'),
      );
      await db.setPullCursor(
        'store-1',
        'products',
        cursorAt(DateTime.utc(2026, 2, 1), 'server_updated_at'),
      );
      await db.setLocalSetting('store-1', 'shop-name', 'STAR:DOM');

      await db.resetPullCursors('store-1');

      expect(
        (await db.getPullCursor('store-1', 'orders')).isEmpty,
        isTrue,
        reason:
            'a re-pull must not be blocked by a high-water mark from '
            'before the server data was rebuilt',
      );
      expect((await db.getPullCursor('store-1', 'products')).isEmpty, isTrue);
      // Real store settings are untouched.
      expect((await db.getSetting('store-1', 'shop-name'))?.value, 'STAR:DOM');
    });
    test('resetPullCursors does not touch another store', () async {
      await seedStore('store-2');
      await db.setPullCursor(
        'store-2',
        'orders',
        cursorAt(DateTime.utc(2026, 2, 1), 'server_created_at'),
      );
      await db.resetPullCursors('store-1');
      expect((await db.getPullCursor('store-2', 'orders')).isEmpty, isFalse);
    });
  });

  // ---------------------------------------------- B7/B8: order_no allocation

  group(
    'order_no needs a server-assigned code and uses the local day (B7, B8)',
    () {
      test('a device with no code cannot create a sale', () async {
        await seedStore();
        await seedDevice('device-1', '');
        await seedProduct('p1', stock: 5);
        await seedCashMethod();
        await expectLater(
          db.createOrder(
            storeId: 'store-1',
            deviceId: 'device-1',
            subtotal: 100,
            discount: 0,
            total: 100,
            items: oneItem('p1'),
          ),
          throwsA(isA<StateError>()),
        );
        expect(await count('orders'), 0);
      });

      test(
        'a 07:00 Manila sale gets the local day key, not the UTC one',
        () async {
          // 2026-01-15T23:30Z is 2026-01-16 07:30 in Manila (UTC+8).
          now = DateTime.utc(2026, 1, 15, 23, 30);
          await seedStore();
          await seedDevice('device-1', 'A0');
          await seedProduct('p1', price: 10, stock: 5);
          final order = await db.createOrder(
            storeId: 'store-1',
            deviceId: 'device-1',
            subtotal: 10,
            discount: 0,
            total: 10,
            items: oneItem('p1', qty: 1, price: 10),
          );
          expect(
            order.orderNo,
            'A0-260116-001',
            reason: 'the 16th locally; the UTC day would have said 260115',
          );

          // And the same day's sequence keeps counting on the local day.
          final second = await db.createOrder(
            storeId: 'store-1',
            deviceId: 'device-1',
            subtotal: 10,
            discount: 0,
            total: 10,
            items: oneItem('p1', qty: 1, price: 10),
          );
          expect(second.orderNo, 'A0-260116-002');
        },
      );

      test('the store offset is configurable (B8)', () async {
        now = DateTime.utc(2026, 1, 15, 23, 30);
        await seedStore();
        await seedDevice('device-1', 'A0');
        await seedProduct('p1', price: 10, stock: 5);
        await db.setSetting(
          'store-1',
          'tz_offset_minutes',
          '0',
          deviceId: 'device-1',
        );
        final order = await db.createOrder(
          storeId: 'store-1',
          deviceId: 'device-1',
          subtotal: 10,
          discount: 0,
          total: 10,
          items: oneItem('p1', qty: 1, price: 10),
        );
        expect(order.orderNo, 'A0-260115-001');
      });
    },
  );

  // ----------------------------------------------------- W2 / W3 additions
  // The web port adds exactly three local-only capabilities: an image cache
  // that makes a receipt/product image render with the network off, a JSON
  // export the owner can keep, and the "unsynced sales" clock. Each one is
  // asserted here, including the fact that NONE of them reach the outbox.
  group('web shell data (W2 export, W3 image cache)', () {
    Future<Order> sellOnce() async {
      await seedStore();
      await seedDevice();
      await seedProduct('p1');
      await seedCashMethod();
      return db.createOrder(
        storeId: 'store-1',
        deviceId: 'device-1',
        orderNo: 'A1-260115-001',
        subtotal: 100,
        discount: 0,
        total: 100,
        items: oneItem('p1', qty: 1, price: 100),
      );
    }

    test('image cache round-trips bytes and enqueues nothing (W3)', () async {
      await seedStore();
      final before = await db.pendingCount('store-1');

      await db.cacheImage(
        path: 'products/p1.webp',
        bytes: Uint8List.fromList([1, 2, 3, 4]),
        contentType: 'image/webp',
      );

      expect(await db.hasImage('products/p1.webp'), isTrue);
      expect(await db.hasImage('products/missing.webp'), isFalse);
      final row = await db.cachedImage('products/p1.webp');
      expect(row!.contentType, 'image/webp');
      expect(row.bytes, Uint8List.fromList([1, 2, 3, 4]));
      expect(await db.cachedImageCount(), 1);
      expect(await db.cachedImageBytes(), 4);

      // `path` is the primary key: re-caching overwrites the single row.
      await db.cacheImage(
        path: 'products/p1.webp',
        bytes: Uint8List.fromList([9, 9]),
        contentType: 'image/webp',
      );
      expect(await db.cachedImageCount(), 1);
      expect(await db.cachedImageBytes(), 2);

      // Local-only: an image is never a sync event.
      expect(await db.pendingCount('store-1'), before);
    });

    test('Export data (JSON) covers every local table (W2)', () async {
      await sellOnce();
      await db.cacheImage(
        path: 'products/p1.webp',
        bytes: Uint8List.fromList([1, 2, 3]),
        contentType: 'image/webp',
      );

      final dump = await db.exportAll();

      expect(dump['schema_version'], 4);
      expect((dump['stores'] as List).length, 1);
      expect((dump['devices'] as List).length, 1);
      expect((dump['products'] as List).length, 1);
      expect((dump['orders'] as List).length, 1);
      expect((dump['order_items'] as List).length, 1);
      expect((dump['payments'] as List).length, 1);
      expect((dump['stock_events'] as List).length, 1);
      // The whole sale must survive a dump, outbox row included.
      expect((dump['sync_outbox'] as List), isNotEmpty);
      expect(dump['image_cache_paths'], ['products/p1.webp']);
      expect(
        dump.keys,
        containsAll(<String>[
          'exported_at',
          'stores',
          'devices',
          'categories',
          'products',
          'payment_methods',
          'orders',
          'order_items',
          'payments',
          'order_voids',
          'stock_events',
          'day_closes',
          'sync_outbox',
          'settings',
          'image_cache_paths',
        ]),
      );
    });

    test(
      'the unsynced-sales clock sees the oldest pending sale (W2)',
      () async {
        await seedStore();
        expect(await db.oldestPendingAt('store-1'), isNull);

        final order = await sellOnce();
        final oldest = await db.oldestPendingAt('store-1');
        expect(oldest, isNotNull);
        expect(oldest!.isBefore(now.add(const Duration(seconds: 5))), isTrue);

        // Once the sale is pushed it is no longer at risk.
        final pending = await db.pendingOutbox('store-1');
        expect(pending.length, 1);
        await db.markOutboxSynced(pending.first.id);
        expect(await db.oldestPendingAt('store-1'), isNull);
        expect(order.id, isNotEmpty);
      },
    );
  });

  // -------------------------------------------------- photo-less shelf rule
  //
  // Sell used to hide photo-less products at render time while Products
  // still called them Active — ~4 in 10 items looked missing on one screen
  // and fine on the other. They are now switched OFF once at launch, so
  // `isActive` is the only rule both screens read.

  group('photo-less products are deactivated once', () {
    test(
      'the sweep switches off live unphotoed rows only, and never again',
      () async {
        await seedStore();
        final at = DateTime.utc(2026, 1, 1);
        await db
            .into(db.products)
            .insert(
              ProductsCompanion.insert(
                id: 'p-photo',
                storeId: 'store-1',
                name: 'With photo',
                price: 10,
                imagePath: const Value('assets/x.webp'),
                updatedAt: at,
              ),
            );
        await db
            .into(db.products)
            .insert(
              ProductsCompanion.insert(
                id: 'p-bare',
                storeId: 'store-1',
                name: 'No photo yet',
                price: 20,
                updatedAt: at,
              ),
            );
        await db
            .into(db.products)
            .insert(
              ProductsCompanion.insert(
                id: 'p-off',
                storeId: 'store-1',
                name: 'Turned off by hand',
                price: 30,
                isActive: const Value(false),
                updatedAt: at,
              ),
            );

        final swept = await db.deactivatePhotolessProducts('store-1');
        expect(
          swept,
          1,
          reason: 'only the LIVE photo-less row is switched off',
        );
        expect((await db.productById('p-photo'))!.isActive, isTrue);
        expect((await db.productById('p-bare'))!.isActive, isFalse);
        expect((await db.productById('p-off'))!.isActive, isFalse);

        // The owner turns it back on: the sweep must stay out of the way.
        await (db.update(db.products)..where((t) => t.id.equals('p-bare')))
            .write(const ProductsCompanion(isActive: Value(true)));
        expect(
          await db.deactivatePhotolessProducts('store-1'),
          0,
          reason: 'one-shot: it must never re-hide what the owner enabled',
        );
        expect((await db.productById('p-bare'))!.isActive, isTrue);

        expect(
          await db.getSetting('store-1', 'photoless_products_swept'),
          isNotNull,
        );
      },
    );
  });

  // ------------------------------------------------ scan-to-add + top sellers

  group('productByBarcode — the scan-to-add lookup', () {
    test('exact match on a live row; deleted and unknown codes miss', () async {
      await seedStore();
      await seedProduct('p1', name: 'Art Print');
      await db.into(db.products).insert(
        ProductsCompanion.insert(
          id: 'p-scan',
          storeId: 'store-1',
          name: 'Mug',
          price: 390,
          barcode: const Value('4800000000017'),
          updatedAt: DateTime.utc(2026, 1, 1),
        ),
      );
      await db.into(db.products).insert(
        ProductsCompanion.insert(
          id: 'p-gone',
          storeId: 'store-1',
          name: 'Retired',
          price: 10,
          barcode: const Value('4800000000024'),
          deletedAt: Value(DateTime.utc(2026, 1, 2)),
          updatedAt: DateTime.utc(2026, 1, 1),
        ),
      );

      expect((await db.productByBarcode('store-1', '4800000000017'))?.id,
          'p-scan');
      // A scanner's trailing whitespace must not defeat the match.
      expect((await db.productByBarcode('store-1', ' 4800000000017 '))?.id,
          'p-scan');
      expect(await db.productByBarcode('store-1', 'nope'), isNull);
      expect(await db.productByBarcode('store-1', ''), isNull,
          reason: 'an empty scan is nothing, not the first row');
      expect(await db.productByBarcode('store-1', '4800000000024'), isNull,
          reason: 'soft-deleted rows never enter a sale');
    });

    test('listProducts search also matches the barcode column', () async {
      await seedStore();
      await seedProduct('p1', name: 'Mug');
      await (db.update(db.products)..where((t) => t.id.equals('p1'))).write(
        const ProductsCompanion(barcode: Value('SKU-99')), 
      );
      await seedProduct('p2', name: 'Candle');

      final byName = await db.listProducts('store-1', search: 'Mug');
      expect(byName.map((p) => p.id), ['p1']);
      final byCode = await db.listProducts('store-1', search: 'SKU-99');
      expect(byCode.map((p) => p.id), ['p1']);
      final miss = await db.listProducts('store-1', search: 'zzz');
      expect(miss, isEmpty);
    });
  });

  group('topSellers — the Sell screen quick-add row', () {
    test('units desc; voided orders and unsellable rows dropped', () async {
      await seedStore();
      await seedDevice();
      await seedCashMethod();
      await seedProduct('p1', name: 'Art Print');
      await seedProduct('p2', name: 'Mug');
      await seedProduct('p3', name: 'Keychain');
      // Shelf says gone — a quick-add chip must never offer it.
      await db.into(db.products).insert(
        ProductsCompanion.insert(
          id: 'p4',
          storeId: 'store-1',
          name: 'Candle',
          price: 250,
          stockStatus: const Value('Out of Stock'),
          updatedAt: DateTime.utc(2026, 1, 1),
        ),
      );

      await db.createOrder(
        storeId: 'store-1',
        deviceId: 'device-1',
        subtotal: 1000,
        discount: 0,
        total: 1000,
        paymentMethodId: 'pm-cash',
        items: [
          ...oneItem('p1', qty: 5, name: 'Art Print'),
          ...oneItem('p2', qty: 2, name: 'Mug'),
          ...oneItem('p4', qty: 4, name: 'Candle'),
        ],
      );
      final voided = await db.createOrder(
        storeId: 'store-1',
        deviceId: 'device-1',
        subtotal: 900,
        discount: 0,
        total: 900,
        paymentMethodId: 'pm-cash',
        items: oneItem('p3', qty: 9, name: 'Keychain'),
      );
      await db.voidOrder(
        voided.id,
        reason: 'oops',
        deviceId: 'device-1',
        storeId: 'store-1',
      );

      final top = await db.topSellers(
        'store-1',
        start: DateTime.utc(2026, 1, 15),
        end: DateTime.utc(2026, 1, 16),
      );
      expect(
        top.map((e) => e.$1.id).toList(),
        ['p1', 'p2'],
        reason: 'most units first; voided p3 (9 units) and sold-out p4 gone',
      );
      expect(top.first.$2, 5);
      expect(top[1].$2, 2);

      // Outside the day window there is nothing to quick-add.
      final empty = await db.topSellers(
        'store-1',
        start: DateTime.utc(2026, 1, 16),
        end: DateTime.utc(2026, 1, 17),
      );
      expect(empty, isEmpty);
    });
  });
}
