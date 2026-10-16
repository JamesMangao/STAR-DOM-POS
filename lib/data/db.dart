import 'dart:convert';

import 'package:drift/drift.dart';

import 'bundle.dart';
import 'logic.dart';
import 'sync_policy.dart';
import 'tables.dart';

part 'db.g.dart';

/// Outcome of [AppDatabase.voidOrder] — a clear result instead of a bare
/// throw, so a double-tap on Void is a no-op, not an error.
enum VoidOutcome { created, alreadyVoided, notFound }

/// Local offline-first SQLite DB (drift). Mirrors docs/plan.md §3.
///
/// Every timestamp is stored UTC. [clock] is injectable so tests never depend
/// on wall time; the default is `DateTime.now().toUtc()`.
@DriftDatabase(
  tables: [
    Stores,
    Devices,
    Categories,
    Products,
    PaymentMethods,
    Orders,
    OrderItems,
    Payments,
    OrderVoids,
    StockEvents,
    DayCloses,
    SyncOutbox,
    Settings,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e, {DateTime Function()? clock})
    : _clock = clock ?? _utcNow;

  /// Default clock: UTC now.
  static DateTime _utcNow() => DateTime.now().toUtc();

  final DateTime Function() _clock;

  /// v2 adds sync_outbox.next_attempt_at (B5 backoff).
  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onUpgrade: (m, from, to) async {
      if (from < 2) {
        await m.addColumn(syncOutbox, syncOutbox.nextAttemptAt);
      }
    },
    beforeOpen: (details) async {
      await customStatement(
        'CREATE UNIQUE INDEX IF NOT EXISTS idx_products_store_barcode '
        'ON products (store_id, barcode) WHERE barcode IS NOT NULL',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_outbox_store_created '
        'ON sync_outbox (store_id, created_at)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_orders_store_created '
        'ON orders (store_id, created_at DESC)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_stock_events_product '
        'ON stock_events (product_id)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_voids_order ON order_voids (order_id)',
      );
    },
  );

  static double r2(double v) => (v * 100).round() / 100;

  // ---------------------------------------------------------------- stores

  Future<Store?> store(String id) async =>
      (select(stores)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<void> upsertStore(Store s) async =>
      into(stores).insertOnConflictUpdate(
        StoresCompanion(
          id: Value(s.id),
          name: Value(s.name),
          tagline: Value(s.tagline),
          ownerId: Value(s.ownerId),
          receiptName: Value(s.receiptName),
          receiptTin: Value(s.receiptTin),
          receiptAddress: Value(s.receiptAddress),
          receiptAccreditation: Value(s.receiptAccreditation),
          receiptFooter: Value(s.receiptFooter),
          currency: Value(s.currency),
          createdAt: Value(s.createdAt),
          updatedAt: Value(_clock()),
        ),
      );

  // --------------------------------------------------------------- devices

  Future<Device?> deviceById(String id) async =>
      (select(devices)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<Device?> deviceByCode(String storeId, String code) async =>
      (select(devices)..where(
            (t) => t.storeId.equals(storeId) & t.deviceCode.equals(code),
          ))
          .getSingleOrNull();

  Future<Device> upsertDevice(Device d) async {
    await into(devices).insertOnConflictUpdate(
      DevicesCompanion(
        id: Value(d.id),
        storeId: Value(d.storeId),
        deviceName: Value(d.deviceName),
        deviceCode: Value(d.deviceCode),
        isActive: Value(d.isActive),
        lastSyncAt: Value(d.lastSyncAt),
        createdAt: Value(d.createdAt),
        updatedAt: Value(_clock()),
      ),
    );
    return d;
  }

  Future<void> renameDevice(String id, String name) async =>
      (update(devices)..where((t) => t.id.equals(id))).write(
        DevicesCompanion(deviceName: Value(name)),
      );

  Future<void> setDeviceActive(String id, bool active) async =>
      (update(devices)..where((t) => t.id.equals(id))).write(
        DevicesCompanion(isActive: Value(active)),
      );

  Future<void> touchSync(String deviceId) async =>
      (update(devices)..where((t) => t.id.equals(deviceId))).write(
        DevicesCompanion(lastSyncAt: Value(_clock())),
      );

  Future<List<Device>> listDevices(String storeId) async =>
      (select(devices)..where((t) => t.storeId.equals(storeId))).get();

  // ------------------------------------------------------------ categories

  Future<List<Category>> listCategories(String storeId) async =>
      (select(categories)
            ..where((t) => t.storeId.equals(storeId) & t.deletedAt.isNull())
            ..orderBy([(t) => OrderingTerm.asc(t.sortOrder)]))
          .get();

  Future<void> upsertCategory(Category c) async {
    final now = _clock();
    await into(categories).insertOnConflictUpdate(
      CategoriesCompanion(
        id: Value(c.id),
        storeId: Value(c.storeId),
        name: Value(c.name),
        sortOrder: Value(c.sortOrder),
        isActive: Value(c.isActive),
        createdAt: Value(c.createdAt),
        updatedAt: Value(now),
        deletedAt: Value(c.deletedAt),
        syncedAt: const Value.absent(),
      ),
    );
    await _enqueue(
      storeId: c.storeId,
      deviceId: '',
      entity: 'categories',
      entityId: c.id,
      op: 'update',
      updatedAt: now,
      payload: _categoryJson(c, now),
    );
  }

  Future<void> softDeleteCategory(String id) async =>
      (update(categories)..where((t) => t.id.equals(id))).write(
        CategoriesCompanion(deletedAt: Value(_clock())),
      );

  // -------------------------------------------------------------- products

  Future<List<Product>> listProducts(
    String storeId, {
    String? categoryId,
    String? search,
  }) async {
    final q = select(products)
      ..where((t) => t.storeId.equals(storeId) & t.deletedAt.isNull());
    if (categoryId != null) q.where((t) => t.categoryId.equals(categoryId));
    if (search != null && search.isNotEmpty) {
      q.where((t) => t.name.like('%${search.replaceAll("'", "_")}%'));
    }
    q.orderBy([(t) => OrderingTerm.asc(t.name)]);
    return q.get();
  }

  Future<Product?> productById(String id) async =>
      (select(products)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<void> upsertProduct(
    Product p, {
    required String deviceId,
    required String storeId,
  }) async {
    final now = _clock();
    await into(products).insertOnConflictUpdate(
      ProductsCompanion(
        id: Value(p.id),
        storeId: Value(p.storeId),
        categoryId: Value(p.categoryId),
        name: Value(p.name),
        price: Value(r2(p.price)),
        barcode: Value(p.barcode),
        imagePath: Value(p.imagePath),
        stockQuantity: Value(p.stockQuantity),
        isActive: Value(p.isActive),
        createdAt: Value(p.createdAt),
        updatedAt: Value(now),
        syncedAt: const Value.absent(),
      ),
    );
    await _enqueue(
      storeId: storeId,
      deviceId: deviceId,
      entity: 'products',
      entityId: p.id,
      op: 'update',
      updatedAt: now,
      payload: _productJson(p, now),
    );
  }

  Future<void> softDeleteProduct(
    String id, {
    required String deviceId,
    required String storeId,
  }) async {
    final now = _clock();
    await (update(products)..where((t) => t.id.equals(id))).write(
      ProductsCompanion(deletedAt: Value(now), updatedAt: Value(now)),
    );
    await _enqueue(
      storeId: storeId,
      deviceId: deviceId,
      entity: 'products',
      entityId: id,
      op: 'delete',
      updatedAt: now,
      payload: {'id': id, 'deleted_at': now.toUtc().toIso8601String()},
    );
  }

  /// Stock = sum of delta events. Never an absolute overwrite.
  Future<void> adjustStock(
    String productId,
    int delta,
    String reason, {
    String? orderId,
    required String deviceId,
    required String storeId,
  }) async {
    final now = _clock();
    final eventId = OutboxEventId.of('stock', '$productId:$reason:$delta', now);
    await into(stockEvents).insert(
      StockEventsCompanion(
        id: Value(eventId),
        storeId: Value(storeId),
        productId: Value(productId),
        delta: Value(delta),
        reason: Value(reason),
        orderId: Value(orderId),
        deviceId: Value(deviceId),
        createdAt: Value(now),
      ),
    );
    await _mirrorStock(productId, now);
    await _enqueue(
      storeId: storeId,
      deviceId: deviceId,
      entity: 'stock_events',
      entityId: eventId,
      op: 'insert',
      updatedAt: now,
      payload: {
        'id': eventId,
        'store_id': storeId,
        'product_id': productId,
        'delta': delta,
        'reason': reason,
        'order_id': orderId,
        'device_id': deviceId,
        'created_at': now.toUtc().toIso8601String(),
      },
    );
  }

  Future<int> stockOf(String productId) async {
    final rows = await (select(
      stockEvents,
    )..where((t) => t.productId.equals(productId))).get();
    return rows.fold<int>(0, (a, r) => a + r.delta);
  }

  /// Mirror the delta sum onto `products.stock_quantity` (display cache only;
  /// the events remain the source of truth).
  Future<void> _mirrorStock(String productId, DateTime now) async {
    final total = await stockOf(productId);
    await (update(products)..where((t) => t.id.equals(productId))).write(
      ProductsCompanion(stockQuantity: Value(total), updatedAt: Value(now)),
    );
  }

  // ------------------------------------------------------- payment methods

  Future<List<PaymentMethod>> listPaymentMethods(String storeId) async =>
      (select(paymentMethods)
            ..where((t) => t.storeId.equals(storeId) & t.deletedAt.isNull())
            ..orderBy([(t) => OrderingTerm.asc(t.sortOrder)]))
          .get();

  Future<PaymentMethod?> paymentMethodById(String id) async =>
      (select(paymentMethods)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<void> upsertPaymentMethod(
    PaymentMethod pm, {
    required String deviceId,
    required String storeId,
  }) async {
    final now = _clock();
    await into(paymentMethods).insertOnConflictUpdate(
      PaymentMethodsCompanion(
        id: Value(pm.id),
        storeId: Value(pm.storeId),
        name: Value(pm.name),
        type: Value(pm.type),
        color: Value(pm.color),
        qrImagePath: Value(pm.qrImagePath),
        accountName: Value(pm.accountName),
        accountNumber: Value(pm.accountNumber),
        requireReference: Value(pm.requireReference),
        isEnabled: Value(pm.isEnabled),
        sortOrder: Value(pm.sortOrder),
        // B9: was `Value(now)`, which rewrote created_at on every edit.
        createdAt: Value(pm.createdAt),
        updatedAt: Value(now),
        deletedAt: Value(pm.deletedAt),
        syncedAt: const Value.absent(),
      ),
    );
    await _enqueue(
      storeId: storeId,
      deviceId: deviceId,
      entity: 'payment_methods',
      entityId: pm.id,
      op: 'update',
      updatedAt: now,
      payload: _paymentMethodJson(pm, now),
    );
  }

  Future<void> softDeletePaymentMethod(
    String id, {
    required String deviceId,
    required String storeId,
  }) async {
    final now = _clock();
    await (update(paymentMethods)..where((t) => t.id.equals(id))).write(
      PaymentMethodsCompanion(deletedAt: Value(now), updatedAt: Value(now)),
    );
    await _enqueue(
      storeId: storeId,
      deviceId: deviceId,
      entity: 'payment_methods',
      entityId: id,
      op: 'delete',
      updatedAt: now,
      payload: {'id': id, 'deleted_at': now.toUtc().toIso8601String()},
    );
  }

  // ---------------------------------------------------------------- orders

  /// Next sequence for this device+day: count of that store's orders with the
  /// {device_code}-{YYMMDD}- prefix, + 1. Called INSIDE the sale transaction.
  /// B9: counted in SQL — it used to load every order row into memory.
  Future<int> dailyOrderSeq(String deviceCode, String dayKey) async {
    final prefix = '$deviceCode-$dayKey-';
    final row = await customSelect(
      'SELECT COUNT(*) AS n FROM orders WHERE order_no LIKE ?',
      variables: [Variable.withString('$prefix%')],
      readsFrom: {orders},
    ).getSingle();
    return row.read<int>('n') + 1;
  }

  Future<Order?> orderById(String id) async =>
      (select(orders)..where((t) => t.id.equals(id))).getSingleOrNull();

  /// True when an order_voids row exists — voided is DERIVED, never a column.
  Future<bool> isVoided(String orderId) async {
    final row = await (select(
      orderVoids,
    )..where((t) => t.orderId.equals(orderId))).getSingleOrNull();
    return row != null;
  }

  Future<OrderVoid?> voidFor(String orderId) async => (select(
    orderVoids,
  )..where((t) => t.orderId.equals(orderId))).getSingleOrNull();

  /// The ONE helper every total uses: orders with NO order_voids row.
  /// Reports, End-of-Day and Close Day all funnel through here.
  Future<List<Order>> activeOrders(
    String storeId, {
    DateTime? businessDate,
  }) async {
    return _ordersMatching(
      storeId,
      businessDate: businessDate,
      includeVoided: false,
    );
  }

  /// "N voided" = orders WITH a void row.
  Future<List<Order>> voidedOrders(
    String storeId, {
    DateTime? businessDate,
  }) async {
    return _ordersMatching(
      storeId,
      businessDate: businessDate,
      includeVoided: true,
      onlyVoided: true,
    );
  }

  /// The store's configured UTC offset in minutes (settings `tz_offset_minutes`,
  /// default 480 = Manila). B8.
  Future<int> tzOffsetMinutes(String storeId) async {
    final s = await getSetting(storeId, 'tz_offset_minutes');
    final parsed = int.tryParse(s?.value ?? '');
    return parsed ?? BusinessDate.defaultTzOffsetMinutes;
  }

  Future<List<Order>> _ordersMatching(
    String storeId, {
    DateTime? businessDate,
    bool includeVoided = true,
    bool onlyVoided = false,
  }) async {
    final voidedIds = (await select(
      orderVoids,
    ).get()).map((v) => v.orderId).toSet();

    // B9: the day filter runs in SQL (the old version loaded every order and
    // filtered in Dart). B8: the day is the STORE-LOCAL day.
    final q = select(orders)..where((t) => t.storeId.equals(storeId));
    if (businessDate != null) {
      final tz = await tzOffsetMinutes(storeId);
      final start = BusinessDate.startOfDayUtc(
        businessDate,
        tzOffsetMinutes: tz,
      );
      final end = start.add(const Duration(days: 1));
      q.where(
        (t) =>
            t.createdAt.isBiggerOrEqualValue(start) &
            t.createdAt.isSmallerThanValue(end),
      );
    }
    final rows = await q.get();

    final result = <Order>[];
    for (final o in rows) {
      final isVoid = voidedIds.contains(o.id);
      if (!includeVoided && isVoid) continue;
      if (onlyVoided && !isVoid) continue;
      result.add(o);
    }
    result.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return result;
  }

  /// Sum of active (non-voided) order totals for a business day.
  Future<double> dailyTotal(String storeId, {DateTime? businessDate}) async {
    final active = await activeOrders(storeId, businessDate: businessDate);
    return r2(active.fold<double>(0, (a, o) => a + o.total));
  }

  Future<int> voidedCount(String storeId, {DateTime? businessDate}) async =>
      (await voidedOrders(storeId, businessDate: businessDate)).length;

  /// Orders list: all orders for a store (optionally filtered), newest first.
  Future<List<Order>> listOrders(
    String storeId, {
    String? paymentMethodId,
    DateTime? businessDate,
  }) async {
    final rows = await _ordersMatching(storeId, businessDate: businessDate);
    if (paymentMethodId == null) return rows;
    return rows.where((o) => o.paymentMethodId == paymentMethodId).toList();
  }

  /// Chip for the orders list: Voided from order_voids, else outbox state.
  Future<OrderChip> chipFor(Order order) async {
    final hasVoid = await isVoided(order.id);
    final outbox = await (select(
      syncOutbox,
    )..where((t) => t.entityId.equals(order.id))).get();
    final failed = outbox.any((e) => e.lastError != null && e.syncedAt == null);
    final synced = outbox.isNotEmpty && outbox.every((e) => e.syncedAt != null);
    return OrderChips.of(hasVoid: hasVoid, synced: synced, failed: failed);
  }

  /// Creates an order + items + payment + stock deltas + outbox bundle in ONE
  /// transaction. `order_no` is allocated INSIDE the transaction when omitted:
  /// order_no = {device_code}-{YYMMDD}-{seq}, seq = this store's orders with
  /// that prefix for the STORE-LOCAL day + 1. Returns the created order row.
  ///
  /// B7: the device code comes from the server (register_device), because
  /// order_no is globally unique and two devices inventing their own code would
  /// collide forever. A sale cannot be created before that registration.
  Future<Order> createOrder({
    required String storeId,
    required String deviceId,
    String? orderNo,
    required double subtotal,
    required double discount,
    required double total,
    String note = '',
    String? paymentMethodId,
    double? amountReceived,
    double? changeAmount,
    String referenceNo = '',
    required List<OrderItem> items,
  }) async {
    final now = _clock();
    late Order order;

    await transaction(() async {
      // 1. order_no sequence allocation — INSIDE the txn, so concurrent
      //    writers cannot hand out the same sequence.
      var no = orderNo;
      if (no == null) {
        final device = await deviceById(deviceId);
        final code = device?.deviceCode ?? '';
        if (code.isEmpty) {
          throw StateError(
            'device $deviceId has no server-assigned code: register it first',
          );
        }
        final tz = await tzOffsetMinutes(storeId);
        final seq = await dailyOrderSeq(
          code,
          OrderNo.dayKey(now, tzOffsetMinutes: tz),
        );
        no = OrderNo.generate(code, now, seq, tzOffsetMinutes: tz);
      }

      final orderId = OutboxEventId.of('order', '$storeId:$no', now);

      // 2. payment-method snapshot, read at sale time.
      var methodName = '';
      var methodType = '';
      if (paymentMethodId != null) {
        final pm = await paymentMethodById(paymentMethodId);
        methodName = pm?.name ?? '';
        methodType = pm?.type ?? '';
      }

      order = Order(
        id: orderId,
        storeId: storeId,
        deviceId: deviceId,
        orderNo: no,
        subtotal: r2(subtotal),
        discount: r2(discount),
        total: r2(total),
        note: note,
        paymentMethodId: paymentMethodId,
        amountReceived: amountReceived == null ? null : r2(amountReceived),
        changeAmount: changeAmount == null ? null : r2(changeAmount),
        referenceNo: referenceNo,
        status: 'completed', // written once; never updated (F3)
        createdAt: now,
        updatedAt: now,
        syncedAt: null,
      );

      await into(orders).insert(
        OrdersCompanion(
          id: Value(order.id),
          storeId: Value(order.storeId),
          deviceId: Value(order.deviceId),
          orderNo: Value(order.orderNo),
          subtotal: Value(order.subtotal),
          discount: Value(order.discount),
          total: Value(order.total),
          note: Value(order.note),
          paymentMethodId: Value(order.paymentMethodId),
          amountReceived: Value(order.amountReceived),
          changeAmount: Value(order.changeAmount),
          referenceNo: Value(order.referenceNo),
          status: const Value('completed'),
          createdAt: Value(now),
          syncedAt: const Value.absent(),
        ),
      );

      // 3. items, with the product name + unit price SNAPSHOTTED at sale time.
      final itemRows = <OrderItem>[];
      for (var i = 0; i < items.length; i++) {
        final it = items[i];
        final row = it.copyWith(
          id: it.id.isEmpty
              ? OutboxEventId.of('item', '${order.id}:$i', now)
              : it.id,
          orderId: order.id,
          unitPrice: r2(it.unitPrice),
          lineTotal: r2(it.lineTotal),
          createdAt: now,
        );
        itemRows.add(row);
        await into(orderItems).insert(
          OrderItemsCompanion(
            id: Value(row.id),
            orderId: Value(row.orderId),
            productId: Value(row.productId),
            productName: Value(row.productName),
            unitPrice: Value(row.unitPrice),
            quantity: Value(row.quantity),
            lineTotal: Value(row.lineTotal),
            createdAt: Value(now),
          ),
        );
      }

      // 4. payment row — in the SAME txn.
      final paymentId = OutboxEventId.of('payment', order.id, now);
      final payment = Payment(
        id: paymentId,
        storeId: storeId,
        deviceId: deviceId,
        orderId: order.id,
        methodId: paymentMethodId,
        methodName: methodName,
        methodType: methodType,
        amount: order.total,
        amountReceived: order.amountReceived,
        changeAmount: order.changeAmount,
        referenceNo: referenceNo,
        createdAt: now,
      );
      await into(payments).insert(
        PaymentsCompanion(
          id: Value(payment.id),
          storeId: Value(payment.storeId),
          deviceId: Value(payment.deviceId),
          orderId: Value(payment.orderId),
          methodId: Value(payment.methodId),
          methodName: Value(payment.methodName),
          methodType: Value(payment.methodType),
          amount: Value(payment.amount),
          amountReceived: Value(payment.amountReceived),
          changeAmount: Value(payment.changeAmount),
          referenceNo: Value(payment.referenceNo),
          createdAt: Value(now),
        ),
      );

      // 5. stock deltas (negative = sale).
      final stockRows = <StockEvent>[];
      for (var i = 0; i < itemRows.length; i++) {
        final it = itemRows[i];
        if (it.productId == null) continue;
        final eventId = OutboxEventId.of('stock', '${order.id}:$i', now);
        final row = StockEvent(
          id: eventId,
          storeId: storeId,
          productId: it.productId!,
          delta: -it.quantity,
          reason: 'sale',
          orderId: order.id,
          deviceId: deviceId,
          createdAt: now,
        );
        stockRows.add(row);
        await into(stockEvents).insert(
          StockEventsCompanion(
            id: Value(row.id),
            storeId: Value(row.storeId),
            productId: Value(row.productId),
            delta: Value(row.delta),
            reason: Value(row.reason),
            orderId: Value(row.orderId),
            deviceId: Value(row.deviceId),
            createdAt: Value(now),
          ),
        );
        await _mirrorStock(row.productId, now);
      }

      // 6. ONE outbox row carrying the whole sale as a bundle.
      await _enqueue(
        storeId: storeId,
        deviceId: deviceId,
        entity: SaleBundle.entity,
        entityId: order.id,
        op: 'insert',
        updatedAt: now,
        payload: _saleBundle(
          order: order,
          items: itemRows,
          payment: payment,
          stock: stockRows,
        ),
      );
    });

    return order;
  }

  /// Void = append an `order_voids` row + reversal `stock_events` + outbox.
  /// The `orders` row is NEVER touched (F3). Idempotent: a second void inserts
  /// nothing and returns [VoidOutcome.alreadyVoided].
  Future<VoidOutcome> voidOrder(
    String orderId, {
    required String reason,
    required String deviceId,
    required String storeId,
  }) async {
    final now = _clock();
    var outcome = VoidOutcome.created;

    await transaction(() async {
      final order = await (select(
        orders,
      )..where((t) => t.id.equals(orderId))).getSingleOrNull();
      if (order == null) {
        outcome = VoidOutcome.notFound;
        return;
      }
      final existing = await (select(
        orderVoids,
      )..where((t) => t.orderId.equals(orderId))).getSingleOrNull();
      if (existing != null) {
        outcome = VoidOutcome.alreadyVoided;
        return;
      }

      final voidId = OutboxEventId.of('void', orderId, now);
      final voidRow = OrderVoid(
        id: voidId,
        orderId: orderId,
        deviceId: deviceId,
        reason: reason,
        voidedAt: now,
        createdAt: now,
      );
      await into(orderVoids).insert(
        OrderVoidsCompanion(
          id: Value(voidRow.id),
          orderId: Value(voidRow.orderId),
          deviceId: Value(voidRow.deviceId),
          reason: Value(voidRow.reason),
          voidedAt: Value(voidRow.voidedAt),
          createdAt: Value(voidRow.createdAt),
        ),
      );

      // Reversal stock events (positive delta).
      final items = await (select(
        orderItems,
      )..where((t) => t.orderId.equals(orderId))).get();
      final stockRows = <StockEvent>[];
      for (var i = 0; i < items.length; i++) {
        final it = items[i];
        if (it.productId == null) continue;
        final eventId = OutboxEventId.of('voidstock', '$voidId:$i', now);
        final row = StockEvent(
          id: eventId,
          storeId: storeId,
          productId: it.productId!,
          delta: it.quantity,
          reason: 'void',
          orderId: orderId,
          deviceId: deviceId,
          createdAt: now,
        );
        stockRows.add(row);
        await into(stockEvents).insert(
          StockEventsCompanion(
            id: Value(row.id),
            storeId: Value(row.storeId),
            productId: Value(row.productId),
            delta: Value(row.delta),
            reason: Value(row.reason),
            orderId: Value(row.orderId),
            deviceId: Value(row.deviceId),
            createdAt: Value(now),
          ),
        );
        await _mirrorStock(row.productId, now);
      }

      await _enqueue(
        storeId: storeId,
        deviceId: deviceId,
        entity: VoidBundle.entity,
        entityId: voidId,
        op: 'void',
        updatedAt: now,
        payload: _voidBundle(
          voidRow: voidRow,
          orderNo: order.orderNo,
          stock: stockRows,
        ),
      );
    });

    return outcome;
  }

  /// Apply an order_voids row pulled from the server. Inserts locally if
  /// absent; NEVER mutates the order row.
  Future<bool> applyRemoteVoid(Map<String, dynamic> row) async {
    final orderId = row['order_id'] as String;
    final existing = await (select(
      orderVoids,
    )..where((t) => t.orderId.equals(orderId))).getSingleOrNull();
    if (existing != null) return false;
    await into(orderVoids).insert(
      OrderVoidsCompanion(
        id: Value(row['id'] as String),
        orderId: Value(orderId),
        deviceId: Value((row['device_id'] as String?) ?? ''),
        reason: Value((row['reason'] as String?) ?? ''),
        voidedAt: Value(DateTime.parse(row['voided_at'] as String).toUtc()),
        createdAt: Value(
          row['created_at'] == null
              ? _clock()
              : DateTime.parse(row['created_at'] as String).toUtc(),
        ),
      ),
      onConflict: DoNothing(),
    );
    return true;
  }

  // ------------------------------------------------------------ day closes

  /// Expected cash for a business day = active (non-voided) cash orders.
  /// "cash orders minus voids", exactly as the mockup decides.
  Future<double> cashExpected({
    required String storeId,
    required DateTime businessDate,
    required String cashPaymentMethodId,
    String? deviceId,
  }) async {
    final active = await activeOrders(storeId, businessDate: businessDate);
    final cash = active.where(
      (o) =>
          o.paymentMethodId == cashPaymentMethodId &&
          (deviceId == null || o.deviceId == deviceId),
    );
    return r2(cash.fold<double>(0, (a, o) => a + o.total));
  }

  Future<DayClose?> dayClose({
    required String storeId,
    required String deviceId,
    required DateTime businessDate,
  }) async {
    final day = BusinessDate.startOfDayUtc(
      businessDate,
      tzOffsetMinutes: await tzOffsetMinutes(storeId),
    );
    return (select(dayCloses)..where(
          (t) =>
              t.storeId.equals(storeId) &
              t.deviceId.equals(deviceId) &
              t.businessDate.equals(day),
        ))
        .getSingleOrNull();
  }

  /// Close Day for one device. One row per (business_date, device_id):
  /// closing the same day twice updates the row (LWW), never duplicates it.
  Future<DayClose> closeDay({
    required String storeId,
    required String deviceId,
    required DateTime businessDate,
    required String cashPaymentMethodId,
    double? cashActual,
    String? closedBy,
  }) async {
    final now = _clock();
    final day = BusinessDate.startOfDayUtc(
      businessDate,
      tzOffsetMinutes: await tzOffsetMinutes(storeId),
    );
    final expected = await cashExpected(
      storeId: storeId,
      businessDate: day,
      cashPaymentMethodId: cashPaymentMethodId,
      deviceId: deviceId,
    );
    final variance = cashActual == null ? null : r2(cashActual - expected);

    final existing =
        await (select(dayCloses)..where(
              (t) =>
                  t.storeId.equals(storeId) &
                  t.deviceId.equals(deviceId) &
                  t.businessDate.equals(day),
            ))
            .getSingleOrNull();

    if (existing != null) {
      await (update(dayCloses)..where((t) => t.id.equals(existing.id))).write(
        DayClosesCompanion(
          cashExpected: Value(expected),
          cashActual: Value(cashActual),
          variance: Value(variance),
          closedBy: Value(closedBy),
          updatedAt: Value(now),
          syncedAt: const Value.absent(),
        ),
      );
      await _enqueue(
        storeId: storeId,
        deviceId: deviceId,
        entity: 'day_closes',
        entityId: existing.id,
        op: 'update',
        updatedAt: now,
        payload: {
          'id': existing.id,
          'store_id': storeId,
          'device_id': deviceId,
          'business_date': day.toIso8601String(),
          'cash_expected': expected,
          'cash_actual': cashActual,
          'variance': variance,
          'closed_by': closedBy,
          'updated_at': now.toUtc().toIso8601String(),
        },
      );
      return (await (select(
        dayCloses,
      )..where((t) => t.id.equals(existing.id))).getSingle());
    }

    final row = DayClose(
      id: OutboxEventId.of('day_close', '$storeId:$deviceId:$day', now),
      storeId: storeId,
      deviceId: deviceId,
      businessDate: day,
      cashExpected: expected,
      cashActual: cashActual,
      variance: variance,
      closedBy: closedBy,
      createdAt: now,
      updatedAt: now,
      syncedAt: null,
    );
    await into(dayCloses).insert(
      DayClosesCompanion(
        id: Value(row.id),
        storeId: Value(row.storeId),
        deviceId: Value(row.deviceId),
        businessDate: Value(row.businessDate),
        cashExpected: Value(row.cashExpected),
        cashActual: Value(row.cashActual),
        variance: Value(row.variance),
        closedBy: Value(row.closedBy),
        createdAt: Value(now),
        updatedAt: Value(now),
        syncedAt: const Value.absent(),
      ),
    );
    await _enqueue(
      storeId: storeId,
      deviceId: deviceId,
      entity: 'day_closes',
      entityId: row.id,
      op: 'insert',
      updatedAt: now,
      payload: {
        'id': row.id,
        'store_id': storeId,
        'device_id': deviceId,
        'business_date': day.toIso8601String(),
        'cash_expected': expected,
        'cash_actual': cashActual,
        'variance': variance,
        'closed_by': closedBy,
        'created_at': now.toUtc().toIso8601String(),
        'updated_at': now.toUtc().toIso8601String(),
      },
    );
    return row;
  }

  // ------------------------------------------------------------- settings

  Future<Setting?> getSetting(String storeId, String key) async =>
      (select(settings)
            ..where((t) => t.storeId.equals(storeId) & t.key.equals(key)))
          .getSingleOrNull();

  Future<void> setSetting(
    String storeId,
    String key,
    String value, {
    required String deviceId,
  }) async {
    final now = _clock();
    await into(settings).insertOnConflictUpdate(
      SettingsCompanion(
        storeId: Value(storeId),
        key: Value(key),
        value: Value(value),
        updatedAt: Value(now),
        syncedAt: const Value.absent(),
      ),
    );
    await _enqueue(
      storeId: storeId,
      deviceId: deviceId,
      entity: 'settings',
      entityId: key,
      op: 'update',
      updatedAt: now,
      payload: {
        'store_id': storeId,
        'key': key,
        'value': value,
        'updated_at': now.toUtc().toIso8601String(),
      },
    );
  }

  // -------------------------------------------------------------- outbox

  /// Enqueue one outbox event. `id` is the deterministic dedupe key
  /// (entity, entity_id, updated_at-UTC) so a replay never double-sends.
  ///
  /// Same-instant re-enqueue (same deterministic id):
  ///   * row NOT yet sent -> replace payload/op, keep attempts + backoff;
  ///   * row already sent -> no-op: never resurrect, never overwrite, never
  ///     duplicate. The `WHERE sync_outbox.synced_at IS NULL` on the upsert
  ///     makes that a database-level guarantee, not a race-prone check.
  Future<void> _enqueue({
    required String storeId,
    required String deviceId,
    required String entity,
    required String entityId,
    required String op,
    required DateTime updatedAt,
    Map<String, dynamic>? payload,
    String? payloadJson,
  }) async {
    final id = OutboxEventId.of(entity, entityId, updatedAt);
    final body = payloadJson ?? jsonEncode(payload ?? const {});
    await into(syncOutbox).insert(
      SyncOutboxCompanion(
        id: Value(id),
        storeId: Value(storeId),
        deviceId: Value(deviceId),
        entity: Value(entity),
        entityId: Value(entityId),
        op: Value(op),
        payload: Value(body),
        createdAt: Value(updatedAt),
      ),
      // DO UPDATE ... WHERE sync_outbox.synced_at IS NULL:
      //   unsent -> refresh payload/op/created_at (attempts + backoff kept);
      //   sent   -> the WHERE is false, so the row is left exactly as it is.
      onConflict: DoUpdate(
        (old) => SyncOutboxCompanion(
          payload: Value(body),
          op: Value(op),
          createdAt: Value(updatedAt),
        ),
        where: (old) => old.syncedAt.isNull(),
      ),
    );
  }

  Future<List<SyncOutboxData>> pendingOutbox(String storeId) async =>
      (select(syncOutbox)
            ..where((t) => t.storeId.equals(storeId) & t.syncedAt.isNull())
            ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
          .get();

  Future<int> pendingCount(String storeId) async =>
      (await pendingOutbox(storeId)).length;

  Future<void> markOutboxSynced(String id) async =>
      (update(syncOutbox)..where((t) => t.id.equals(id))).write(
        SyncOutboxCompanion(
          syncedAt: Value(_clock()),
          nextAttemptAt: const Value.absent(),
          lastError: const Value.absent(),
        ),
      );

  Future<void> retryOutbox(String id) async =>
      (update(syncOutbox)..where((t) => t.id.equals(id))).write(
        SyncOutboxCompanion(
          attempts: const Value(0),
          lastError: const Value.absent(),
        ),
      );

  // -------------------------------------------- pull cursors (B4)

  /// The per-table pull cursor. LOCAL device state: stored in settings under
  /// `pull_cursor:<table>` and NEVER enqueued, because it is not store data.
  Future<PullCursor> getPullCursor(String storeId, String table) async {
    final s = await getSetting(storeId, PullPlan.cursorKey(table));
    return PullCursor.parse(s?.value);
  }

  Future<void> setPullCursor(String storeId, String table, PullCursor cursor) =>
      setLocalSetting(storeId, PullPlan.cursorKey(table), cursor.describe());

  /// A setting that is written locally and never pushed (cursors, flags).
  Future<void> setLocalSetting(String storeId, String key, String value) async {
    await into(settings).insertOnConflictUpdate(
      SettingsCompanion(
        storeId: Value(storeId),
        key: Value(key),
        value: Value(value),
        updatedAt: Value(_clock()),
        syncedAt: const Value.absent(),
      ),
    );
  }

  // ------------------------------------------- remote apply (B1, B2, B3)

  DateTime? _ts(Object? v) =>
      v == null ? null : DateTime.tryParse(v.toString())?.toUtc();

  /// Apply one pulled row. NEVER enqueues (a pulled row must not be pushed
  /// straight back), keeps the SERVER's created_at/updated_at, and applies
  /// last-write-wins on EVERY mutable table. Returns true if it changed
  /// something. Append-only rows insert with DO NOTHING.
  Future<bool> applyRemoteRow(String table, Map<String, dynamic> row) async {
    switch (table) {
      case 'stores':
        return _applyRemoteStore(row);
      case 'devices':
        return _applyRemoteDevice(row);
      case 'categories':
        return _applyRemoteCategory(row);
      case 'products':
        return _applyRemoteProduct(row);
      case 'payment_methods':
        return _applyRemotePaymentMethod(row);
      case 'settings':
        return _applyRemoteSetting(row);
      case 'day_closes':
        return _applyRemoteDayClose(row);
      case 'orders':
        if (await orderById(row['id'] as String) != null) return false;
        await into(orders).insert(
          OrdersCompanion(
            id: Value(row['id'] as String),
            storeId: Value(row['store_id'] as String),
            deviceId: Value(row['device_id'] as String),
            orderNo: Value(row['order_no'] as String),
            subtotal: Value((row['subtotal'] as num).toDouble()),
            discount: Value((row['discount'] as num).toDouble()),
            total: Value((row['total'] as num).toDouble()),
            note: Value((row['note'] as String?) ?? ''),
            paymentMethodId: Value(row['payment_method_id'] as String?),
            amountReceived: Value((row['amount_received'] as num?)?.toDouble()),
            changeAmount: Value((row['change_amount'] as num?)?.toDouble()),
            referenceNo: Value((row['reference_no'] as String?) ?? ''),
            status: Value((row['status'] as String?) ?? 'completed'),
            createdAt: Value(_ts(row['created_at']) ?? _clock()),
            updatedAt: Value(_ts(row['updated_at']) ?? _clock()),
          ),
          mode: InsertMode.insertOrIgnore,
        );
        return true;
      case 'order_items':
        if (await (select(orderItems)
                  ..where((t) => t.id.equals(row['id'] as String)))
                .getSingleOrNull() !=
            null) {
          return false;
        }
        await into(orderItems).insert(
          OrderItemsCompanion(
            id: Value(row['id'] as String),
            orderId: Value(row['order_id'] as String),
            productId: Value(row['product_id'] as String?),
            productName: Value(row['product_name'] as String),
            unitPrice: Value((row['unit_price'] as num).toDouble()),
            quantity: Value((row['quantity'] as num).toInt()),
            lineTotal: Value((row['line_total'] as num).toDouble()),
            createdAt: Value(_ts(row['created_at']) ?? _clock()),
          ),
          mode: InsertMode.insertOrIgnore,
        );
        return true;
      case 'payments':
        if (await (select(payments)
                  ..where((t) => t.id.equals(row['id'] as String)))
                .getSingleOrNull() !=
            null) {
          return false;
        }
        await into(payments).insert(
          PaymentsCompanion(
            id: Value(row['id'] as String),
            storeId: Value(row['store_id'] as String),
            deviceId: Value(row['device_id'] as String),
            orderId: Value(row['order_id'] as String),
            methodId: Value(row['method_id'] as String?),
            methodName: Value((row['method_name'] as String?) ?? ''),
            methodType: Value((row['method_type'] as String?) ?? ''),
            amount: Value((row['amount'] as num).toDouble()),
            amountReceived: Value((row['amount_received'] as num?)?.toDouble()),
            changeAmount: Value((row['change_amount'] as num?)?.toDouble()),
            referenceNo: Value((row['reference_no'] as String?) ?? ''),
            createdAt: Value(_ts(row['created_at']) ?? _clock()),
          ),
          mode: InsertMode.insertOrIgnore,
        );
        return true;
      case 'stock_events':
        if (await (select(stockEvents)
                  ..where((t) => t.id.equals(row['id'] as String)))
                .getSingleOrNull() !=
            null) {
          return false;
        }
        await into(stockEvents).insert(
          StockEventsCompanion(
            id: Value(row['id'] as String),
            storeId: Value(row['store_id'] as String),
            productId: Value(row['product_id'] as String),
            delta: Value((row['delta'] as num).toInt()),
            reason: Value(row['reason'] as String),
            orderId: Value(row['order_id'] as String?),
            deviceId: Value(row['device_id'] as String?),
            createdAt: Value(_ts(row['created_at']) ?? _clock()),
          ),
          mode: InsertMode.insertOrIgnore,
        );
        // B2: the mirror is DERIVED from the events, never taken from a row.
        await rebuildStockMirror(row['product_id'] as String);
        return true;
      case 'order_voids':
        return applyRemoteVoid(row);
      default:
        return false;
    }
  }

  Future<bool> _applyRemoteStore(Map<String, dynamic> row) async {
    final id = row['id'] as String;
    final existing = await store(id);
    final serverUpdated = _ts(row['updated_at']);
    if (!LastWriteWins.serverWins(
      localUpdatedAt: existing?.updatedAt,
      serverUpdatedAt: serverUpdated,
    )) {
      return false;
    }
    await into(stores).insertOnConflictUpdate(
      StoresCompanion(
        id: Value(id),
        name: Value(row['name'] as String),
        tagline: Value((row['tagline'] as String?) ?? ''),
        ownerId: Value((row['owner_id'] as String?) ?? ''),
        receiptName: Value((row['receipt_name'] as String?) ?? ''),
        receiptTin: Value((row['receipt_tin'] as String?) ?? ''),
        receiptAddress: Value((row['receipt_address'] as String?) ?? ''),
        receiptAccreditation: Value(
          (row['receipt_accreditation'] as String?) ?? '',
        ),
        receiptFooter: Value((row['receipt_footer'] as String?) ?? ''),
        currency: Value((row['currency'] as String?) ?? 'PHP'),
        createdAt: Value(
          _ts(row['created_at']) ?? existing?.createdAt ?? _clock(),
        ),
        updatedAt: Value(serverUpdated ?? existing?.updatedAt ?? _clock()),
      ),
    );
    return true;
  }

  Future<bool> _applyRemoteDevice(Map<String, dynamic> row) async {
    final id = row['id'] as String;
    final existing = await deviceById(id);
    final serverUpdated = _ts(row['updated_at']);
    if (!LastWriteWins.serverWins(
      localUpdatedAt: existing?.updatedAt,
      serverUpdatedAt: serverUpdated,
    )) {
      return false;
    }
    await into(devices).insertOnConflictUpdate(
      DevicesCompanion(
        id: Value(id),
        storeId: Value(row['store_id'] as String),
        deviceName: Value((row['device_name'] as String?) ?? 'Phone'),
        deviceCode: Value((row['device_code'] as String?) ?? ''),
        isActive: Value(row['is_active'] as bool? ?? true),
        lastSyncAt: Value(_ts(row['last_sync_at'])),
        createdAt: Value(
          _ts(row['created_at']) ?? existing?.createdAt ?? _clock(),
        ),
        updatedAt: Value(serverUpdated ?? existing?.updatedAt ?? _clock()),
      ),
    );
    return true;
  }

  Future<bool> _applyRemoteCategory(Map<String, dynamic> row) async {
    final id = row['id'] as String;
    final existing = await (select(
      categories,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    final serverUpdated = _ts(row['updated_at']);
    if (!LastWriteWins.serverWins(
      localUpdatedAt: existing?.updatedAt,
      serverUpdatedAt: serverUpdated,
    )) {
      return false;
    }
    await into(categories).insertOnConflictUpdate(
      CategoriesCompanion(
        id: Value(id),
        storeId: Value(row['store_id'] as String),
        name: Value(row['name'] as String),
        sortOrder: Value((row['sort_order'] as num?)?.toInt() ?? 0),
        isActive: Value(row['is_active'] as bool? ?? true),
        createdAt: Value(
          _ts(row['created_at']) ?? existing?.createdAt ?? _clock(),
        ),
        updatedAt: Value(serverUpdated ?? existing?.updatedAt ?? _clock()),
        deletedAt: Value(_ts(row['deleted_at'])),
      ),
    );
    return true;
  }

  Future<bool> _applyRemoteProduct(Map<String, dynamic> row) async {
    final id = row['id'] as String;
    final existing = await productById(id);
    final serverUpdated = _ts(row['updated_at']);
    if (!LastWriteWins.serverWins(
      localUpdatedAt: existing?.updatedAt,
      serverUpdatedAt: serverUpdated,
    )) {
      return false;
    }
    await into(products).insertOnConflictUpdate(
      ProductsCompanion(
        id: Value(id),
        storeId: Value(row['store_id'] as String),
        categoryId: Value(row['category_id'] as String?),
        name: Value(row['name'] as String),
        price: Value((row['price'] as num).toDouble()),
        barcode: Value(row['barcode'] as String?),
        imagePath: Value(row['image_path'] as String?),
        // B2: stock_quantity is a MIRROR of the events, never a remote value.
        stockQuantity: existing == null ? const Value(0) : const Value.absent(),
        isActive: Value(row['is_active'] as bool? ?? true),
        createdAt: Value(
          _ts(row['created_at']) ?? existing?.createdAt ?? _clock(),
        ),
        updatedAt: Value(serverUpdated ?? existing?.updatedAt ?? _clock()),
        deletedAt: Value(_ts(row['deleted_at'])),
      ),
    );
    await rebuildStockMirror(id);
    return true;
  }

  Future<bool> _applyRemotePaymentMethod(Map<String, dynamic> row) async {
    final id = row['id'] as String;
    final existing = await paymentMethodById(id);
    final serverUpdated = _ts(row['updated_at']);
    if (!LastWriteWins.serverWins(
      localUpdatedAt: existing?.updatedAt,
      serverUpdatedAt: serverUpdated,
    )) {
      return false;
    }
    await into(paymentMethods).insertOnConflictUpdate(
      PaymentMethodsCompanion(
        id: Value(id),
        storeId: Value(row['store_id'] as String),
        name: Value(row['name'] as String),
        type: Value(row['type'] as String),
        color: Value((row['color'] as String?) ?? '#B70011'),
        qrImagePath: Value(row['qr_image_path'] as String?),
        accountName: Value((row['account_name'] as String?) ?? ''),
        accountNumber: Value((row['account_number'] as String?) ?? ''),
        requireReference: Value(row['require_reference'] as bool? ?? false),
        isEnabled: Value(row['is_enabled'] as bool? ?? true),
        sortOrder: Value((row['sort_order'] as num?)?.toInt() ?? 0),
        createdAt: Value(
          _ts(row['created_at']) ?? existing?.createdAt ?? _clock(),
        ),
        updatedAt: Value(serverUpdated ?? existing?.updatedAt ?? _clock()),
        deletedAt: Value(_ts(row['deleted_at'])),
      ),
    );
    return true;
  }

  Future<bool> _applyRemoteSetting(Map<String, dynamic> row) async {
    final storeId = row['store_id'] as String;
    final key = row['key'] as String;
    final existing = await getSetting(storeId, key);
    final serverUpdated = _ts(row['updated_at']);
    if (!LastWriteWins.serverWins(
      localUpdatedAt: existing?.updatedAt,
      serverUpdatedAt: serverUpdated,
    )) {
      return false;
    }
    final value = (row['value'] as String?) ?? '';
    await into(settings).insertOnConflictUpdate(
      SettingsCompanion(
        storeId: Value(storeId),
        key: Value(key),
        value: Value(value),
        updatedAt: Value(serverUpdated ?? existing?.updatedAt ?? _clock()),
      ),
    );
    return true;
  }

  Future<bool> _applyRemoteDayClose(Map<String, dynamic> row) async {
    final id = row['id'] as String;
    final existing = await (select(
      dayCloses,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    final serverUpdated = _ts(row['updated_at']);
    if (!LastWriteWins.serverWins(
      localUpdatedAt: existing?.updatedAt,
      serverUpdatedAt: serverUpdated,
    )) {
      return false;
    }
    await into(dayCloses).insertOnConflictUpdate(
      DayClosesCompanion(
        id: Value(id),
        storeId: Value(row['store_id'] as String),
        deviceId: Value(row['device_id'] as String),
        businessDate: Value(_ts(row['business_date']) ?? _clock()),
        cashExpected: Value((row['cash_expected'] as num?)?.toDouble()),
        cashActual: Value((row['cash_actual'] as num?)?.toDouble()),
        variance: Value((row['variance'] as num?)?.toDouble()),
        closedBy: Value(row['closed_by'] as String?),
        createdAt: Value(
          _ts(row['created_at']) ?? existing?.createdAt ?? _clock(),
        ),
        updatedAt: Value(serverUpdated ?? existing?.updatedAt ?? _clock()),
      ),
    );
    return true;
  }

  /// Recompute the display cache from the events WITHOUT touching updated_at
  /// (B2): the row's LWW timestamp must stay the server's, not ours.
  Future<int> rebuildStockMirror(String productId) async {
    final total = await stockOf(productId);
    await (update(products)..where((t) => t.id.equals(productId))).write(
      ProductsCompanion(stockQuantity: Value(total)),
    );
    return total;
  }

  /// Rebuild every mirror (after a full pull of stock_events).
  Future<void> rebuildStockMirrors() async {
    final rows = await select(products).get();
    for (final p in rows) {
      await rebuildStockMirror(p.id);
    }
  }

  // ------------------------------------------- outbox state (B5)

  OutboxState outboxState(SyncOutboxData e) => OutboxState(
    attempts: e.attempts,
    nextAttemptAt: e.nextAttemptAt,
    synced: e.syncedAt != null,
    lastError: e.lastError,
  );

  /// Park/backoff a row after a REAL failure (never after being offline).
  Future<void> markOutboxFailed(
    String id,
    String error, {
    required int attempts,
    DateTime? nextAttemptAt,
  }) async {
    await (update(syncOutbox)..where((t) => t.id.equals(id))).write(
      SyncOutboxCompanion(
        attempts: Value(attempts),
        nextAttemptAt: Value(nextAttemptAt),
        lastError: Value(error),
      ),
    );
  }

  /// A device that is merely OFFLINE: nothing changes, nothing is parked.
  Future<void> markOutboxOffline(String id, String error) async {
    await (update(syncOutbox)..where((t) => t.id.equals(id))).write(
      SyncOutboxCompanion(lastError: Value(error)),
    );
  }

  // ---------------------------------------------------- JSON serialisation

  Map<String, dynamic> _saleBundle({
    required Order order,
    required List<OrderItem> items,
    required Payment payment,
    required List<StockEvent> stock,
  }) => {
    SaleBundle.order: {
      'id': order.id,
      'store_id': order.storeId,
      'device_id': order.deviceId,
      'order_no': order.orderNo,
      'subtotal': order.subtotal,
      'discount': order.discount,
      'total': order.total,
      'note': order.note,
      'payment_method_id': order.paymentMethodId,
      'amount_received': order.amountReceived,
      'change_amount': order.changeAmount,
      'reference_no': order.referenceNo,
      'status': order.status,
      'created_at': order.createdAt.toUtc().toIso8601String(),
      'updated_at': order.updatedAt.toUtc().toIso8601String(),
    },
    SaleBundle.items: [
      for (final i in items)
        {
          'id': i.id,
          'order_id': i.orderId,
          'product_id': i.productId,
          'product_name': i.productName,
          'unit_price': i.unitPrice,
          'quantity': i.quantity,
          'line_total': i.lineTotal,
          'created_at': i.createdAt.toUtc().toIso8601String(),
        },
    ],
    SaleBundle.payment: {
      'id': payment.id,
      'store_id': payment.storeId,
      'device_id': payment.deviceId,
      'order_id': payment.orderId,
      'method_id': payment.methodId,
      'method_name': payment.methodName,
      'method_type': payment.methodType,
      'amount': payment.amount,
      'amount_received': payment.amountReceived,
      'change_amount': payment.changeAmount,
      'reference_no': payment.referenceNo,
      'created_at': payment.createdAt.toUtc().toIso8601String(),
    },
    SaleBundle.stockEvents: [
      for (final s in stock)
        {
          'id': s.id,
          'store_id': s.storeId,
          'product_id': s.productId,
          'delta': s.delta,
          'reason': s.reason,
          'order_id': s.orderId,
          'device_id': s.deviceId,
          'created_at': s.createdAt.toUtc().toIso8601String(),
        },
    ],
  };

  Map<String, dynamic> _voidBundle({
    required OrderVoid voidRow,
    required String orderNo,
    required List<StockEvent> stock,
  }) => {
    VoidBundle.voidRow: {
      'id': voidRow.id,
      'order_id': voidRow.orderId,
      'order_no': orderNo,
      'device_id': voidRow.deviceId,
      'reason': voidRow.reason,
      'voided_at': voidRow.voidedAt.toUtc().toIso8601String(),
      'created_at': voidRow.createdAt.toUtc().toIso8601String(),
    },
    VoidBundle.stockEvents: [
      for (final s in stock)
        {
          'id': s.id,
          'store_id': s.storeId,
          'product_id': s.productId,
          'delta': s.delta,
          'reason': s.reason,
          'order_id': s.orderId,
          'device_id': s.deviceId,
          'created_at': s.createdAt.toUtc().toIso8601String(),
        },
    ],
  };

  Map<String, dynamic> _productJson(Product p, DateTime now) => {
    'id': p.id,
    'store_id': p.storeId,
    'category_id': p.categoryId,
    'name': p.name,
    'price': r2(p.price),
    'barcode': p.barcode,
    'image_path': p.imagePath,
    'stock_quantity': p.stockQuantity,
    'is_active': p.isActive,
    'created_at': p.createdAt.toUtc().toIso8601String(),
    'updated_at': now.toUtc().toIso8601String(),
  };

  Map<String, dynamic> _categoryJson(Category c, DateTime now) => {
    'id': c.id,
    'store_id': c.storeId,
    'name': c.name,
    'sort_order': c.sortOrder,
    'is_active': c.isActive,
    'created_at': c.createdAt.toUtc().toIso8601String(),
    'updated_at': now.toUtc().toIso8601String(),
    'deleted_at': c.deletedAt?.toUtc().toIso8601String(),
  };

  Map<String, dynamic> _paymentMethodJson(PaymentMethod pm, DateTime now) => {
    'id': pm.id,
    'store_id': pm.storeId,
    'name': pm.name,
    'type': pm.type,
    'color': pm.color,
    'qr_image_path': pm.qrImagePath,
    'account_name': pm.accountName,
    'account_number': pm.accountNumber,
    'require_reference': pm.requireReference,
    'is_enabled': pm.isEnabled,
    'sort_order': pm.sortOrder,
    'created_at': pm.createdAt.toUtc().toIso8601String(),
    'updated_at': now.toUtc().toIso8601String(),
    'deleted_at': pm.deletedAt?.toUtc().toIso8601String(),
  };
}
