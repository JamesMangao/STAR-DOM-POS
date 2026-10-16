import 'dart:convert';

import 'package:drift/drift.dart';

import 'bundle.dart';
import 'logic.dart';
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

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
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
    final eventId = OutboxEventId.of(
      'stock',
      '$productId:$reason:$delta',
      now,
    );
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
      (select(
        paymentMethods,
      )..where((t) => t.id.equals(id))).getSingleOrNull();

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
        createdAt: Value(now),
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
  Future<int> dailyOrderSeq(String deviceCode, String dayKey) async {
    final prefix = '$deviceCode-$dayKey-';
    final rows = await select(orders).get();
    return rows.where((o) => o.orderNo.startsWith(prefix)).length + 1;
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

  Future<OrderVoid?> voidFor(String orderId) async =>
      (select(orderVoids)..where((t) => t.orderId.equals(orderId)))
          .getSingleOrNull();

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

  Future<List<Order>> _ordersMatching(
    String storeId, {
    DateTime? businessDate,
    bool includeVoided = true,
    bool onlyVoided = false,
  }) async {
    final voidedIds = (await select(orderVoids).get())
        .map((v) => v.orderId)
        .toSet();
    final rows = await (select(
      orders,
    )..where((t) => t.storeId.equals(storeId))).get();
    final result = <Order>[];
    for (final o in rows) {
      final isVoid = voidedIds.contains(o.id);
      if (!includeVoided && isVoid) continue;
      if (onlyVoided && !isVoid) continue;
      if (businessDate != null && !BusinessDate.sameDay(o.createdAt, businessDate)) {
        continue;
      }
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
  /// that prefix for the UTC day + 1. Returns the created order row.
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
        final code = device?.deviceCode ?? 'D0';
        final seq = await dailyOrderSeq(code, OrderNo.dayKey(now));
        no = OrderNo.generate(code, now, seq);
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
        voidedAt: Value(
          DateTime.parse(row['voided_at'] as String).toUtc(),
        ),
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
    final day = BusinessDate.startOfDayUtc(businessDate);
    return (select(dayCloses)..where(
          (t) => t.storeId.equals(storeId) & t.deviceId.equals(deviceId) & t.businessDate.equals(day),
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
    final day = BusinessDate.startOfDayUtc(businessDate);
    final expected = await cashExpected(
      storeId: storeId,
      businessDate: day,
      cashPaymentMethodId: cashPaymentMethodId,
      deviceId: deviceId,
    );
    final variance = cashActual == null ? null : r2(cashActual - expected);

    final existing = await (select(dayCloses)..where(
          (t) => t.storeId.equals(storeId) & t.deviceId.equals(deviceId) & t.businessDate.equals(day),
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
    // Upsert, not insert: re-enqueueing the same deterministic event (same
    // entity/entity_id/updated_at) refreshes the payload instead of throwing.
    // synced_at is not in the companion, so an already-synced row stays synced.
    await into(syncOutbox).insertOnConflictUpdate(
      SyncOutboxCompanion(
        id: Value(OutboxEventId.of(entity, entityId, updatedAt)),
        storeId: Value(storeId),
        deviceId: Value(deviceId),
        entity: Value(entity),
        entityId: Value(entityId),
        op: Value(op),
        payload: Value(payloadJson ?? jsonEncode(payload ?? const {})),
        createdAt: Value(updatedAt),
      ),
    );
  }

  Future<List<SyncOutboxData>> pendingOutbox(String storeId) async =>
      (select(syncOutbox)
            ..where((t) => t.storeId.equals(storeId) & t.syncedAt.isNull())
            ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
          .get();

  Future<int> pendingCount(String storeId) async => (await pendingOutbox(storeId)).length;

  Future<void> markOutboxSynced(String id) async =>
      (update(syncOutbox)..where((t) => t.id.equals(id))).write(
        SyncOutboxCompanion(
          syncedAt: Value(_clock()),
          lastError: const Value.absent(),
        ),
      );

  Future<void> markOutboxFailed(String id, String error) async {
    final row = await (select(
      syncOutbox,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    await (update(syncOutbox)..where((t) => t.id.equals(id))).write(
      SyncOutboxCompanion(
        attempts: Value((row?.attempts ?? 0) + 1),
        lastError: Value(error),
      ),
    );
  }

  Future<void> retryOutbox(String id) async =>
      (update(syncOutbox)..where((t) => t.id.equals(id))).write(
        SyncOutboxCompanion(
          attempts: const Value(0),
          lastError: const Value.absent(),
        ),
      );

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
