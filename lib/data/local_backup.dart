import 'dart:convert';

import 'package:drift/drift.dart';

import '../core/web_apis.dart' as web;
import 'db.dart';

/// A mirror of the shop in browser localStorage — and the merge that puts it
/// back after a restart.
///
/// drift picks whatever storage the browser offers (OPFS → IndexedDB →
/// inMemory). When a browser lands on `inMemory` — or later evicts the
/// site's data — every table is empty on the next launch: the sales history,
/// the shop settings, and the payment methods the owner typed in once. He was
/// re-entering all of it after every restart of the PC or the browser.
///
/// [save] runs debounced after every local change and writes a JSON mirror
/// to localStorage, a store that lives outside the database and survives
/// both a normal restart and an evicted IndexedDB. [restore] runs once at
/// boot and merges the mirror back with INSERT OR IGNORE:
///
/// * an intact database is never touched — its rows win every conflict;
/// * an emptied database is refilled with the newest mirror;
/// * nothing is deleted on either side, so the merge is safe at every launch.
///
/// The mirror is bounded (newest sales first, ~5 MB quota kept in mind) so
/// it can never grow past what localStorage accepts; older sales already
/// live on the server through sync and in the owner's manual JSON export.
class LocalBackup {
  LocalBackup._();

  static const String key = 'stardom_pos_backup_v1';
  static const int version = 1;

  /// localStorage caps around 5 MB per origin — stay comfortably under it.
  static const int _maxChars = 4200000;

  /// Sales kept in the mirror (newest first — `listOrders` sorts
  /// descending). Retried smaller only if a batch ever exceeds the quota.
  static const List<int> _orderLimits = [1000, 300, 0];

  /// What Settings shows next to "Local backup".
  static String status = 'not saved yet';

  /// Merge the mirror into [db]. Runs at every launch, before anything reads
  /// the tables. Best-effort: a missing or broken backup must never stop the
  /// app from booting.
  static Future<void> restore(AppDatabase db) async {
    final raw = web.localStorageRead(key);
    if (raw == null || raw.isEmpty) return;
    try {
      final dump = jsonDecode(raw) as Map<String, dynamic>;
      if (dump['version'] != version) {
        status = 'backup from a different app version — ignored';
        return;
      }
      final before = await _counts(db);
      await db.transaction(() => _insertAll(db, dump));
      final after = await _counts(db);
      final sales = after.$1 - before.$1;
      final methods = after.$2 - before.$2;
      status = (sales == 0 && methods == 0)
          ? 'up to date — nothing to restore'
          : 'restored ${_fmt(sales, methods)} at launch';
    } catch (e) {
      status = 'backup unreadable — $e';
    }
  }

  /// Write the mirror. Called debounced after every local table change and
  /// once at the end of boot, so a fresh install is covered from minute one.
  static Future<void> save(AppDatabase db) async {
    try {
      var dump = const <String, dynamic>{};
      var json = '';
      // Newest sales first; shrink only when a build will not fit.
      for (final limit in _orderLimits) {
        dump = await _build(db, limit);
        json = jsonEncode(dump);
        if (json.length <= _maxChars) break;
      }
      final ok = web.localStorageWrite(key, json);
      final sales = (dump['orders'] as List?)?.length ?? 0;
      final methods = (dump['payment_methods'] as List?)?.length ?? 0;
      status = ok
          ? 'saved — ${_fmt(sales, methods)}'
          : 'browser storage is full — not saved';
    } catch (e) {
      status = 'save failed — $e';
    }
  }

  static String _fmt(int sales, int methods) =>
      '$sales sale${sales == 1 ? '' : 's'}, '
      '$methods payment method${methods == 1 ? '' : 's'}';

  /// Rows that COUNT(*) sees before/after a restore: the two tables the bug
  /// was felt in. Stored in order so `restored N sales, M methods` is real.
  static Future<(int, int)> _counts(AppDatabase db) async {
    Future<int> n(String table) async {
      final row = await db
          .customSelect('SELECT COUNT(*) AS n FROM $table')
          .getSingle();
      return row.read<int>('n');
    }

    return (
      await n(db.orders.actualTableName),
      await n(db.paymentMethods.actualTableName),
    );
  }

  static Future<void> _insertAll(
    AppDatabase db,
    Map<String, dynamic> dump,
  ) async {
    /// Insert every row from [dump][name] using [parse] and [toCompanion].
    /// INSERT OR IGNORE so an intact database keeps its own rows.
    Future<void> putRows(
      String name,
      void Function(Object companion) insert,
      Object Function(Map<String, dynamic>) toCompanion,
    ) async {
      final rows = dump[name];
      if (rows is! List) return;
      for (final r in rows) {
        insert(toCompanion(r as Map<String, dynamic>));
      }
    }

    // Parent rows first (drift tables carry no FK constraints, but sync
    // consumers and the catalogue re-seed both read in this order anyway).
    await putRows(
      'stores',
      (c) => db
          .into(db.stores)
          .insert(c as StoresCompanion, mode: InsertMode.insertOrIgnore),
      (r) => Store.fromJson(r).toCompanion(false),
    );
    await putRows(
      'devices',
      (c) => db
          .into(db.devices)
          .insert(c as DevicesCompanion, mode: InsertMode.insertOrIgnore),
      (r) => Device.fromJson(r).toCompanion(false),
    );
    await putRows(
      'categories',
      (c) => db
          .into(db.categories)
          .insert(c as CategoriesCompanion, mode: InsertMode.insertOrIgnore),
      (r) => Category.fromJson(r).toCompanion(false),
    );
    await putRows(
      'products',
      (c) => db
          .into(db.products)
          .insert(c as ProductsCompanion, mode: InsertMode.insertOrIgnore),
      (r) => Product.fromJson(r).toCompanion(false),
    );
    await putRows(
      'payment_methods',
      (c) => db
          .into(db.paymentMethods)
          .insert(
            c as PaymentMethodsCompanion,
            mode: InsertMode.insertOrIgnore,
          ),
      (r) => PaymentMethod.fromJson(r).toCompanion(false),
    );
    await putRows(
      'settings',
      (c) => db
          .into(db.settings)
          .insert(c as SettingsCompanion, mode: InsertMode.insertOrIgnore),
      (r) => Setting.fromJson(r).toCompanion(false),
    );
    await putRows(
      'day_closes',
      (c) => db
          .into(db.dayCloses)
          .insert(c as DayClosesCompanion, mode: InsertMode.insertOrIgnore),
      (r) => DayClose.fromJson(r).toCompanion(false),
    );
    await putRows(
      'orders',
      (c) => db
          .into(db.orders)
          .insert(c as OrdersCompanion, mode: InsertMode.insertOrIgnore),
      (r) => Order.fromJson(r).toCompanion(false),
    );
    await putRows(
      'order_items',
      (c) => db
          .into(db.orderItems)
          .insert(c as OrderItemsCompanion, mode: InsertMode.insertOrIgnore),
      (r) => OrderItem.fromJson(r).toCompanion(false),
    );
    await putRows(
      'payments',
      (c) => db
          .into(db.payments)
          .insert(c as PaymentsCompanion, mode: InsertMode.insertOrIgnore),
      (r) => Payment.fromJson(r).toCompanion(false),
    );
    await putRows(
      'order_voids',
      (c) => db
          .into(db.orderVoids)
          .insert(c as OrderVoidsCompanion, mode: InsertMode.insertOrIgnore),
      (r) => OrderVoid.fromJson(r).toCompanion(false),
    );
    await putRows(
      'stock_events',
      (c) => db
          .into(db.stockEvents)
          .insert(c as StockEventsCompanion, mode: InsertMode.insertOrIgnore),
      (r) => StockEvent.fromJson(r).toCompanion(false),
    );
    await putRows(
      'sync_outbox',
      (c) => db
          .into(db.syncOutbox)
          .insert(c as SyncOutboxCompanion, mode: InsertMode.insertOrIgnore),
      (r) => SyncOutboxData.fromJson(r).toCompanion(false),
    );
  }

  static Future<Map<String, dynamic>> _build(
    AppDatabase db,
    int orderLimit,
  ) async {
    final stores = await db.allStores();
    final storeId = stores.isEmpty ? null : stores.first.id;
    final orders = storeId == null
        ? const <Order>[]
        : await db.listOrders(storeId, limit: orderLimit);
    final orderIds = [for (final o in orders) o.id];

    return <String, dynamic>{
      'version': version,
      'saved_at': DateTime.now().toUtc().toIso8601String(),
      'stores': [for (final r in stores) r.toJson()],
      'devices': [
        for (final r in await db.select(db.devices).get()) r.toJson(),
      ],
      'categories': [
        for (final r in await db.select(db.categories).get()) r.toJson(),
      ],
      'products': [
        for (final r in await db.select(db.products).get()) r.toJson(),
      ],
      'payment_methods': [
        for (final r in await db.select(db.paymentMethods).get()) r.toJson(),
      ],
      'settings': [
        for (final r in await db.select(db.settings).get()) r.toJson(),
      ],
      'day_closes': [
        for (final r in await db.select(db.dayCloses).get()) r.toJson(),
      ],
      'orders': [for (final r in orders) r.toJson()],
      'order_items': [
        for (final r in await db.orderItemsForOrders(orderIds)) r.toJson(),
      ],
      'payments': [
        for (final r in await db.paymentsForOrders(orderIds)) r.toJson(),
      ],
      'order_voids': [for (final r in await _voids(db, orderIds)) r.toJson()],
      'stock_events': [
        for (final r in await _stockEvents(db, orderIds)) r.toJson(),
      ],
      'sync_outbox': [for (final r in await _outbox(db, orderIds)) r.toJson()],
    };
  }

  /// Voids of the mirrored sales (the screen reads order_voids, not the
  /// outbox, to draw the Voided chip).
  static Future<List<OrderVoid>> _voids(
    AppDatabase db,
    List<String> orderIds,
  ) async {
    if (orderIds.isEmpty) return const [];
    return (db.select(
      db.orderVoids,
    )..where((t) => t.orderId.isIn(orderIds))).get();
  }

  /// Import/manual stock events (they carry the product's opening count) plus
  /// the events of the mirrored sales, so a rebuilt stock mirror stays honest.
  static Future<List<StockEvent>> _stockEvents(
    AppDatabase db,
    List<String> orderIds,
  ) async {
    final all = await db.select(db.stockEvents).get();
    if (orderIds.isEmpty) {
      return all.where((e) => e.orderId == null).toList();
    }
    return all
        .where((e) => e.orderId == null || orderIds.contains(e.orderId))
        .toList();
  }

  /// Always the pending pushes (the offline-first contract), plus the synced
  /// rows of the mirrored sales so they keep their Synced chip.
  static Future<List<SyncOutboxData>> _outbox(
    AppDatabase db,
    List<String> orderIds,
  ) async {
    final all = await db.select(db.syncOutbox).get();
    if (orderIds.isEmpty) {
      return all.where((e) => e.syncedAt == null).toList();
    }
    return all
        .where((e) => e.syncedAt == null || orderIds.contains(e.entityId))
        .toList();
  }
}
