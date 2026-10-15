import 'package:drift/drift.dart';

import 'logic.dart';
import 'tables.dart';

part 'db.g.dart';

/// Local offline-first SQLite DB (drift). Mirrors docs/plan.md §3.
@DriftDatabase(tables: [
  Stores,
  Devices,
  Categories,
  Products,
  PaymentMethods,
  Orders,
  OrderItems,
  OrderVoids,
  StockEvents,
  Shifts,
  SyncOutbox,
  Settings,
])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get onBeforeOpen => (details) async {
    await customStatement(
        'CREATE UNIQUE INDEX IF NOT EXISTS idx_products_store_barcode '
        'ON products (store_id, barcode) WHERE barcode IS NOT NULL');
    await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_outbox_store_created '
        'ON sync_outbox (store_id, created_at)');
    await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_orders_store_created '
        'ON orders (store_id, created_at DESC)');
    await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_stock_events_product '
        'ON stock_events (product_id)');
  };

  static double r2(double v) => (v * 100).round() / 100;

  // ---- stores ----

  Future<Store?> store(String id) async =>
      (select(stores)..where((t) => t.id.equals(id))).getSingleOrNull().then((r) {
        if (r == null) return null;
        return Store(
          id: r.id,
          name: r.name,
          tagline: r.tagline,
          ownerId: r.ownerId,
          receiptName: r.receiptName,
          receiptTin: r.receiptTin,
          receiptAddress: r.receiptAddress,
          receiptAccreditation: r.receiptAccreditation,
          receiptFooter: r.receiptFooter,
          currency: r.currency,
        );
      });

  Future<void> upsertStore(Store s) async =>
      into(stores).insertOnConflictUpdate(StoresCompanion(
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
        updatedAt: Value(DateTime.now()),
      ));

  // ---- devices ----

  Future<Device?> deviceById(String id) async =>
      (select(devices)..where((t) => t.id.equals(id))).getSingleOrNull().then((r) {
        if (r == null) return null;
        return Device(
          id: r.id,
          storeId: r.storeId,
          deviceName: r.deviceName,
          deviceCode: r.deviceCode,
          isActive: r.isActive,
          lastSyncAt: r.lastSyncAt,
          createdAt: r.createdAt,
        );
      });

  Future<Device?> deviceByCode(String storeId, String code) async =>
      (select(devices)
            ..where((t) => t.storeId.equals(storeId) & t.deviceCode.equals(code)))
          .getSingleOrNull()
          .then((r) {
        if (r == null) return null;
        return Device(
          id: r.id,
          storeId: r.storeId,
          deviceName: r.deviceName,
          deviceCode: r.deviceCode,
          isActive: r.isActive,
          lastSyncAt: r.lastSyncAt,
          createdAt: r.createdAt,
        );
      });

  Future<Device> upsertDevice(Device d) async {
    await into(devices).insertOnConflictUpdate(DevicesCompanion(
      id: Value(d.id),
      storeId: Value(d.storeId),
      deviceName: Value(d.deviceName),
      deviceCode: Value(d.deviceCode),
      isActive: Value(d.isActive),
      lastSyncAt: Value(d.lastSyncAt),
      createdAt: Value(d.createdAt),
      updatedAt: Value(DateTime.now()),
    ));
    return d;
  }

  Future<void> renameDevice(String id, String name) async =>
      (update(devices)..where((t) => t.id.equals(id)))
          .write(DevicesCompanion(deviceName: Value(name)));

  Future<void> setDeviceActive(String id, bool active) async =>
      (update(devices)..where((t) => t.id.equals(id)))
          .write(DevicesCompanion(isActive: Value(active)));

  Future<void> touchSync(String deviceId) async =>
      (update(devices)..where((t) => t.id.equals(deviceId)))
          .write(DevicesCompanion(lastSyncAt: Value(DateTime.now())));

  Future<List<Device>> listDevices(String storeId) async =>
      (select(devices)..where((t) => t.storeId.equals(storeId))).get().then((rows) => rows
          .map((r) => Device(
                id: r.id,
                storeId: r.storeId,
                deviceName: r.deviceName,
                deviceCode: r.deviceCode,
                isActive: r.isActive,
                lastSyncAt: r.lastSyncAt,
                createdAt: r.createdAt,
              ))
          .toList());

  // ---- categories ----

  Future<List<Category>> listCategories(String storeId) async =>
      (select(categories)
            ..where((t) => t.storeId.equals(storeId) & t.deletedAt.isNull())
            ..orderBy([(t) => OrderingTerm.asc(t.sortOrder)]))
          .get()
          .then((rows) => rows
              .map((r) => Category(
                    id: r.id,
                    storeId: r.storeId,
                    name: r.name,
                    sortOrder: r.sortOrder,
                    isActive: r.isActive,
                  ))
              .toList());

  Future<void> upsertCategory(Category c) async =>
      into(categories).insertOnConflictUpdate(CategoriesCompanion(
        id: Value(c.id),
        storeId: Value(c.storeId),
        name: Value(c.name),
        sortOrder: Value(c.sortOrder),
        isActive: Value(c.isActive),
        createdAt: Value(c.id.isEmpty ? DateTime.now() : DateTime.now()),
        updatedAt: Value(DateTime.now()),
      ));

  Future<void> softDeleteCategory(String id) async =>
      (update(categories)..where((t) => t.id.equals(id)))
          .write(CategoriesCompanion(deletedAt: Value(DateTime.now())));

  // ---- products ----

  Future<List<Product>> listProducts(String storeId,
      {String? categoryId, String? search}) async {
    final q = select(products)
      ..where((t) => t.storeId.equals(storeId) & t.deletedAt.isNull());
    if (categoryId != null) q.where((t) => t.categoryId.equals(categoryId));
    if (search != null && search.isNotEmpty) {
      q.where((t) => t.name.like('%${search.replaceAll("'", "_")}%'));
    }
    q.orderBy([(t) => OrderingTerm.asc(t.name)]);
    final rows = await q.get();
    return rows.map(_productFromRow).toList();
  }

  Future<Product?> productById(String id) async =>
      (select(products)..where((t) => t.id.equals(id))).getSingleOrNull().then(
          (r) => r == null ? null : _productFromRow(r));

  Product _productFromRow(Products row) => Product(
        id: row.id,
        storeId: row.storeId,
        categoryId: row.categoryId,
        name: row.name,
        price: row.price,
        barcode: row.barcode,
        imagePath: row.imagePath,
        stockQuantity: row.stockQuantity,
        isActive: row.isActive,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt,
        deletedAt: row.deletedAt,
      );

  Future<void> upsertProduct(Product p,
      {required String deviceId, required String storeId}) async {
    final now = DateTime.now();
    await into(products).insertOnConflictUpdate(ProductsCompanion(
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
      syncedAt: const Value(null),
    ));
    await _enqueue(storeId: storeId, deviceId: deviceId, entity: 'products',
        entityId: p.id, op: 'update', updatedAt: now);
  }

  Future<void> softDeleteProduct(String id,
      {required String deviceId, required String storeId}) async {
    final now = DateTime.now();
    await (update(products)..where((t) => t.id.equals(id)))
        .write(ProductsCompanion(deletedAt: Value(now), updatedAt: Value(now)));
    await _enqueue(storeId: storeId, deviceId: deviceId, entity: 'products',
        entityId: id, op: 'delete', updatedAt: now);
  }

  /// Stock = sum of delta events. Never an absolute overwrite.
  Future<void> adjustStock(String productId, int delta, String reason,
      {String? orderId, required String deviceId, required String storeId}) async {
    final now = DateTime.now();
    await into(stockEvents).insert(StockEventsCompanion(
      id: Value(OutboxEventId.of('stock', productId, now)),
      storeId: Value(storeId),
      productId: Value(productId),
      delta: Value(delta),
      reason: Value(reason),
      orderId: Value(orderId),
      deviceId: Value(deviceId),
      createdAt: Value(now),
    ));
    final rows = await (select(stockEvents)
          ..where((t) => t.productId.equals(productId)))
        .get();
    final total = rows.fold<int>(0, (a, r) => a + r.delta);
    await (update(products)..where((t) => t.id.equals(productId)))
        .write(ProductsCompanion(stockQuantity: Value(total), updatedAt: Value(now)));
    await _enqueue(storeId: storeId, deviceId: deviceId, entity: 'products',
        entityId: productId, op: 'update', updatedAt: now);
  }

  Future<int> stockOf(String productId) async {
    final rows = await (select(stockEvents)
          ..where((t) => t.productId.equals(productId)))
        .get();
    return rows.fold<int>(0, (a, r) => a + r.delta);
  }

  // ---- payment methods ----

  Future<List<PaymentMethod>> listPaymentMethods(String storeId) async =>
      (select(paymentMethods)
            ..where((t) => t.storeId.equals(storeId) & t.deletedAt.isNull())
            ..orderBy([(t) => OrderingTerm.asc(t.sortOrder)]))
          .get()
          .then((rows) => rows
              .map((r) => PaymentMethod(
                    id: r.id,
                    storeId: r.storeId,
                    name: r.name,
                    type: r.type,
                    color: r.color,
                    qrImagePath: r.qrImagePath,
                    accountName: r.accountName,
                    accountNumber: r.accountNumber,
                    requireReference: r.requireReference,
                    isEnabled: r.isEnabled,
                    sortOrder: r.sortOrder,
                    updatedAt: r.updatedAt,
                    deletedAt: r.deletedAt,
                  ))
              .toList());

  Future<void> upsertPaymentMethod(PaymentMethod pm,
      {required String deviceId, required String storeId}) async {
    final now = DateTime.now();
    await into(paymentMethods).insertOnConflictUpdate(PaymentMethodsCompanion(
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
      syncedAt: const Value(null),
    ));
    await _enqueue(storeId: storeId, deviceId: deviceId,
        entity: 'payment_methods', entityId: pm.id, op: 'update', updatedAt: now);
  }

  Future<void> softDeletePaymentMethod(String id,
      {required String deviceId, required String storeId}) async {
    final now = DateTime.now();
    await (update(paymentMethods)..where((t) => t.id.equals(id))).write(
        PaymentMethodsCompanion(deletedAt: Value(now), updatedAt: Value(now)));
    await _enqueue(storeId: storeId, deviceId: deviceId,
        entity: 'payment_methods', entityId: id, op: 'delete', updatedAt: now);
  }

  // ---- orders (append-only) ----

  /// Next sequence for this device+day: count of that device's orders with the
  /// {device_code}-{YYMMDD}- prefix, + 1.
  Future<int> dailyOrderSeq(String deviceCode, String dayKey) async {
    final prefix = '$deviceCode-$dayKey-';
    final rows = await select(orders).get();
    return rows.where((o) => o.orderNo.startsWith(prefix)).length + 1;
  }

  Future<Order?> orderById(String id) async {
    final row =
        await (select(orders)..where((t) => t.id.equals(id))).getSingleOrNull();
    if (row == null) return null;
    final items =
        await (select(orderItems)..where((t) => t.orderId.equals(id))).get();
    return _orderFromRow(row, items);
  }

  Order _orderFromRow(Orders row, List<OrderItems> items) => Order(
        id: row.id,
        storeId: row.storeId,
        deviceId: row.deviceId,
        orderNo: row.orderNo,
        subtotal: row.subtotal,
        discount: row.discount,
        total: row.total,
        note: row.note,
        paymentMethodId: row.paymentMethodId,
        amountReceived: row.amountReceived,
        changeAmount: row.changeAmount,
        referenceNo: row.referenceNo,
        status: row.status,
        items: items
            .map((i) => OrderItem(
                  id: i.id,
                  orderId: i.orderId,
                  productId: i.productId,
                  productName: i.productName,
                  unitPrice: i.unitPrice,
                  quantity: i.quantity,
                  lineTotal: i.lineTotal,
                ))
            .toList(),
        createdAt: row.createdAt,
        updatedAt: row.updatedAt,
        syncedAt: row.syncedAt,
      );

  /// Creates an order + items + stock deltas + outbox event in one transaction.
  /// order_no = {device_code}-{YYMMDD}-{seq}. Returns the created order.
  Future<Order> createOrder({
    required String storeId,
    required String deviceId,
    required String orderNo,
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
    final now = DateTime.now();
    final orderId = OutboxEventId.of('order', orderNo, now);
    final order = Order(
      id: orderId,
      storeId: storeId,
      deviceId: deviceId,
      orderNo: orderNo,
      subtotal: r2(subtotal),
      discount: r2(discount),
      total: r2(total),
      note: note,
      paymentMethodId: paymentMethodId,
      amountReceived: amountReceived == null ? null : r2(amountReceived),
      changeAmount: changeAmount == null ? null : r2(changeAmount),
      referenceNo: referenceNo,
      items: items,
      createdAt: now,
      updatedAt: now,
    );

    await transaction(() async {
      await into(orders).insert(OrdersCompanion(
        id: Value(order.id),
        storeId: Value(storeId),
        deviceId: Value(deviceId),
        orderNo: Value(orderNo),
        subtotal: Value(r2(subtotal)),
        discount: Value(r2(discount)),
        total: Value(r2(total)),
        note: Value(note),
        paymentMethodId: Value(paymentMethodId),
        amountReceived: Value(amountReceived),
        changeAmount: Value(changeAmount),
        referenceNo: Value(referenceNo),
        createdAt: Value(now),
        syncedAt: const Value(null),
      ));
      for (final i in items) {
        await into(orderItems).insert(OrderItemsCompanion(
          id: Value(i.id),
          orderId: Value(order.id),
          productId: Value(i.productId),
          productName: Value(i.productName),
          unitPrice: Value(r2(i.unitPrice)),
          quantity: Value(i.quantity),
          lineTotal: Value(r2(i.lineTotal)),
        ));
      }
      for (final i in items) {
        if (i.productId == null) continue;
        await into(stockEvents).insert(StockEventsCompanion(
          id: Value(OutboxEventId.of('stock', i.productId!, now)),
          storeId: Value(storeId),
          productId: Value(i.productId!),
          delta: Value(-i.quantity),
          reason: const Value('sale'),
          orderId: Value(order.id),
          deviceId: Value(deviceId),
          createdAt: Value(now),
        ));
      }
      await _enqueue(storeId: storeId, deviceId: deviceId, entity: 'orders',
          entityId: order.id, op: 'insert', updatedAt: now);
    });

    return order;
  }

  /// Void = append order_voids event + flip status. Never edits the order row.
  Future<void> voidOrder(String orderId,
      {required String reason, required String deviceId, required String storeId}) async {
    final now = DateTime.now();
    await transaction(() async {
      await into(orderVoids).insert(OrderVoidsCompanion(
        id: Value(OutboxEventId.of('void', orderId, now)),
        orderId: Value(orderId),
        deviceId: Value(deviceId),
        reason: Value(reason),
      ));
      await (update(orders)..where((t) => t.id.equals(orderId)))
          .write(OrdersCompanion(status: const Value('voided'), updatedAt: Value(now)));
      await _enqueue(storeId: storeId, deviceId: deviceId, entity: 'orders',
          entityId: orderId, op: 'void', updatedAt: now);
    });
  }

  Future<List<Order>> listOrders(String storeId,
      {String? paymentMethodId, DateTime? date, String? status}) async {
    final rows = await (select(orders)..where((t) => t.storeId.equals(storeId))).get();
    final orders = <Order>[];
    for (final row in rows) {
      if (paymentMethodId != null && row.paymentMethodId != paymentMethodId) continue;
      if (status != null && row.status != status) continue;
      if (date != null &&
          !(row.createdAt.year == date.year &&
              row.createdAt.month == date.month &&
              row.createdAt.day == date.day)) {
        continue;
      }
      final items =
          await (select(orderItems)..where((t) => t.orderId.equals(row.id))).get();
      orders.add(_orderFromRow(row, items));
    }
    orders.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return orders;
  }

  // ---- shifts ----

  Future<Shift?> openShift(String deviceId, String storeId) async {
    final existing = await (select(shifts)
          ..where((t) => t.deviceId.equals(deviceId) & t.closedAt.isNull()))
        .getSingleOrNull();
    if (existing != null) return _shiftFromRow(existing);
    final shift = Shift(
      id: OutboxEventId.of('shift', deviceId, DateTime.now()),
      storeId: storeId,
      deviceId: deviceId,
      openedAt: DateTime.now(),
    );
    await into(shifts).insert(ShiftsCompanion(
      id: Value(shift.id),
      storeId: Value(storeId),
      deviceId: Value(deviceId),
      openedAt: Value(shift.openedAt),
    ));
    return shift;
  }

  Shift _shiftFromRow(Shifts r) => Shift(
        id: r.id,
        storeId: r.storeId,
        deviceId: r.deviceId,
        openedAt: r.openedAt,
        closedAt: r.closedAt,
        cashExpected: r.cashExpected,
        cashActual: r.cashActual,
        variance: r.variance,
        closedBy: r.closedBy,
      );

  /// Expected cash = sum of completed cash orders for this device since shift open.
  Future<double> cashExpected(String shiftId, String cashPaymentMethodId) async {
    final shift =
        await (select(shifts)..where((t) => t.id.equals(shiftId))).getSingleOrNull();
    if (shift == null) return 0;
    final orders = await (select(orders)
          ..where((t) =>
              t.deviceId.equals(shift.deviceId) &
              t.status.equals('completed') &
              t.paymentMethodId.equals(cashPaymentMethodId)))
        .get();
    return orders
        .where((o) => o.createdAt.isAfter(shift.openedAt))
        .fold<double>(0, (a, o) => a + o.total);
  }

  Future<void> closeShift(String shiftId,
      {double? cashActual, String? closedBy}) async {
    final now = DateTime.now();
    final shift =
        await (select(shifts)..where((t) => t.id.equals(shiftId))).getSingleOrNull();
    final expected = shift?.cashExpected;
    await (update(shifts)..where((t) => t.id.equals(shiftId))).write(ShiftsCompanion(
      closedAt: Value(now),
      cashActual: Value(cashActual),
      cashExpected: Value(expected),
      variance: Value(cashActual == null || expected == null ? null : r2(cashActual - expected)),
      closedBy: Value(closedBy),
      updatedAt: Value(now),
      syncedAt: const Value(null),
    ));
  }

  // ---- settings ----

  Future<SettingsItem?> getSetting(String storeId, String key) async =>
      (select(settings)..where((t) => t.storeId.equals(storeId) & t.key.equals(key)))
          .getSingleOrNull()
          .then((r) => r == null
              ? null
              : SettingsItem(
                  storeId: r.storeId, key: r.key, value: r.value, updatedAt: r.updatedAt));

  Future<void> setSetting(String storeId, String key, String value,
      {required String deviceId}) async {
    final now = DateTime.now();
    await into(settings).insertOnConflictUpdate(SettingsCompanion(
      storeId: Value(storeId),
      key: Value(key),
      value: Value(value),
      updatedAt: Value(now),
      syncedAt: const Value(null),
    ));
    await _enqueue(storeId: storeId, deviceId: deviceId, entity: 'settings',
        entityId: key, op: 'update', updatedAt: now);
  }

  // ---- outbox ----

  Future<void> _enqueue({
    required String storeId,
    required String deviceId,
    required String entity,
    required String entityId,
    required String op,
    required DateTime updatedAt,
  }) async {
    await into(syncOutbox).insert(SyncOutboxCompanion(
      id: Value(OutboxEventId.of(entity, entityId, updatedAt)),
      storeId: Value(storeId),
      deviceId: Value(deviceId),
      entity: Value(entity),
      entityId: Value(entityId),
      op: Value(op),
      payload: const Value('{}'),
      createdAt: Value(DateTime.now()),
    ));
  }

  Future<List<OutboxEvent>> pendingOutbox(String storeId) async =>
      (select(syncOutbox)
            ..where((t) => t.storeId.equals(storeId) & t.syncedAt.isNull())
            ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
          .get()
          .then((rows) => rows
              .map((r) => OutboxEvent(
                    id: r.id,
                    storeId: r.storeId,
                    deviceId: r.deviceId,
                    entity: r.entity,
                    entityId: r.entityId,
                    op: r.op,
                    payload: r.payload,
                    attempts: r.attempts,
                    lastError: r.lastError,
                    createdAt: r.createdAt,
                    syncedAt: r.syncedAt,
                  ))
              .toList());

  Future<int> pendingCount(String storeId) async =>
      (select(syncOutbox)
            ..where((t) => t.storeId.equals(storeId) & t.syncedAt.isNull()))
          .get()
          .then((rows) => rows.length);

  Future<void> markOutboxSynced(String id) async =>
      (update(syncOutbox)..where((t) => t.id.equals(id))).write(
          SyncOutboxCompanion(syncedAt: Value(DateTime.now()), lastError: const Value(null)));

  Future<void> markOutboxFailed(String id, String error) async {
    final row =
        await (select(syncOutbox)..where((t) => t.id.equals(id))).getSingleOrNull();
    await (update(syncOutbox)..where((t) => t.id.equals(id))).write(SyncOutboxCompanion(
      attempts: Value((row?.attempts ?? 0) + 1),
      lastError: Value(error),
    ));
  }

  Future<void> retryOutbox(String id) async =>
      (update(syncOutbox)..where((t) => t.id.equals(id))).write(
          SyncOutboxCompanion(attempts: const Value(0), lastError: const Value(null)));
}
