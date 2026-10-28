import 'dart:convert';

import 'package:drift/drift.dart';

import 'bundle.dart';
import 'logic.dart';
import 'norm.dart';
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
    ImageCaches,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e, {DateTime Function()? clock})
    : _clock = clock ?? _utcNow;

  /// Default clock: UTC now.
  static DateTime _utcNow() => DateTime.now().toUtc();

  final DateTime Function() _clock;

  /// v2 adds sync_outbox.next_attempt_at (B5 backoff).
  /// v3 adds the local-only image_cache table (W3, never synced).
  /// v5 adds devices.persistent_storage so Settings can show whether this
  /// device asked the browser to never evict its data (W2).
  @override
  int get schemaVersion => 5;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onUpgrade: (m, from, to) async {
      if (from < 2) {
        await m.addColumn(syncOutbox, syncOutbox.nextAttemptAt);
      }
      if (from < 3) {
        await m.createTable(imageCaches);
      }
      if (from < 4) {
        await m.addColumn(products, products.stockStatus);
        await m.addColumn(products, products.sourceRef);
        await m.addColumn(products, products.notes);
        await m.addColumn(products, products.sourceCol1);
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
      // v5: add persistent_storage to devices. Raw SQL here because
      // Migrator.addColumn has type issues with BoolColumn; onUpgrade can't
      // use it. beforeOpen runs every open, so try/catch handles the
      // "duplicate column" case on already-migrated databases.
      try {
        await customStatement(
          'ALTER TABLE devices ADD COLUMN persistent_storage '
          'BOOLEAN NOT NULL DEFAULT 0',
        );
      } catch (_) {
        // Column already exists — fine.
      }
      await _repairTextTimestamps();
      await _repairWalletPaymentTypes();
      await _repairQueuedBusinessDates();
    },
  );

  /// Heal timestamps left behind as TEXT by the old raw
  /// [setDevicePersistent] statement (it bound an ISO-8601 string into an
  /// INTEGER column).
  ///
  /// drift reads a `dateTime` column with `int.parse`, so ONE such row made
  /// every SELECT of that table throw — on the web build the message is the
  /// bare value: `FormatException: 2026-10-27T16:29:14.617Z`. Because the
  /// devices SELECT maps every row, one poisoned `updated_at` failed the whole
  /// devices dedupe pass and sync reported
  /// "Local cleanup of devices failed" on every run.
  ///
  /// Runs on every open and only matches `typeof(...) = 'text'` rows, so on a
  /// healthy database it is a scan that changes nothing. A value SQLite cannot
  /// read as a date is left as-is — never nulled out — so nothing is lost by
  /// running it. Drift stores SQLite date-times as Unix seconds, so this keeps
  /// the supported precision and the expected integer representation.
  Future<void> _repairTextTimestamps() async {
    for (final table in allSchemaEntities.whereType<TableInfo>()) {
      for (final col in table.$columns.whereType<DateTimeColumn>()) {
        final name = col.name;
        await customStatement(
          'UPDATE ${table.actualTableName} SET $name = '
          "CAST(strftime('%s', $name) AS INTEGER) "
          "WHERE typeof($name) = 'text' AND strftime('%s', $name) IS NOT NULL",
        );
      }
    }
  }

  /// Map the payment-method type this app used to write ('wallet') onto the
  /// one the server accepts (`payment_methods_type_check` allows only cash |
  /// ewallet | bank — verified live), and hand any queued push of the old
  /// value a clean retry: those rows failed 23514 on every attempt, and a row
  /// parked after [PushPolicy.maxAttempts] refusals never retries by itself.
  Future<void> _repairWalletPaymentTypes() async {
    await customStatement(
      "UPDATE payment_methods SET type = 'ewallet' WHERE type = 'wallet'",
    );
    await customStatement(
      'UPDATE sync_outbox SET payload = replace(payload, ?, ?), '
      'attempts = 0, next_attempt_at = NULL, last_error = NULL '
      "WHERE entity = 'payment_methods' AND synced_at IS NULL "
      "AND payload LIKE '%\"type\":\"wallet\"%'",
      ['"type":"wallet"', '"type":"ewallet"'],
    );
  }

  /// The old close-day push put a UTC INSTANT in `business_date`, a store-local
  /// DATE column, so the server read the day back one early. Rewrite any still
  /// queued payload to the store-local `YYYY-MM-DD` key before it can go out.
  Future<void> _repairQueuedBusinessDates() async {
    final rows =
        await (select(syncOutbox)
              ..where((t) => t.entity.equals('day_closes') & t.syncedAt.isNull()))
            .get();
    for (final r in rows) {
      final Object? decoded;
      try {
        decoded = jsonDecode(r.payload);
      } catch (_) {
        continue; // a payload we cannot read is not ours to rewrite
      }
      if (decoded is! Map<String, dynamic>) continue;
      final payload = decoded;
      final raw = payload['business_date'];
      if (raw is! String || raw.isEmpty || _ymd.hasMatch(raw)) continue;
      final at = DateTime.tryParse(raw);
      if (at == null) continue;
      payload['business_date'] = BusinessDate.key(
        at,
        tzOffsetMinutes: await tzOffsetMinutes(r.storeId),
      );
      await (update(syncOutbox)..where((t) => t.id.equals(r.id))).write(
        SyncOutboxCompanion(
          payload: Value(jsonEncode(payload)),
          attempts: const Value(0),
          lastError: const Value(null),
          nextAttemptAt: const Value(null),
        ),
      );
    }
  }

  /// The store-local DATE the server holds, read back into the local column's
  /// own shape: the UTC instant of that day's store-local midnight
  /// ([BusinessDate.startOfDayUtc]). The DEVICE's zone must not decide the
  /// day, so a plain `YYYY-MM-DD` is taken apart by parts; a legacy value that
  /// still carries a time (the old push sent a UTC instant) is run through the
  /// store offset instead. Null when unreadable — the caller keeps its
  /// fallback.
  Future<DateTime?> _businessDateFromServer(String? raw, String storeId) async {
    if (raw == null || raw.isEmpty) return null;
    final offset = Duration(minutes: await tzOffsetMinutes(storeId));
    if (_ymd.hasMatch(raw)) {
      final p = raw.split('-');
      return DateTime.utc(
        int.parse(p[0]),
        int.parse(p[1]),
        int.parse(p[2]),
      ).subtract(offset);
    }
    final at = DateTime.tryParse(raw);
    if (at == null) return null;
    final local = at.toUtc().add(offset);
    return DateTime.utc(
      local.year,
      local.month,
      local.day,
    ).subtract(offset);
  }

  /// `YYYY-MM-DD` — the shape a `date` column speaks.
  static final RegExp _ymd = RegExp(r'^\d{4}-\d{2}-\d{2}$');

  static double r2(double v) => (v * 100).round() / 100;

  // --------------------------------------------------------- image cache (W3)
  // Local-only: the bytes of a product/QR image, so it renders with the
  // network off. Never enqueued, never pushed, never pulled.

  Future<void> cacheImage({
    required String path,
    required Uint8List bytes,
    required String contentType,
    DateTime? fetchedAt,
  }) => into(imageCaches).insertOnConflictUpdate(
    ImageCachesCompanion(
      path: Value(path),
      bytes: Value(bytes),
      contentType: Value(contentType),
      fetchedAt: Value(fetchedAt ?? _clock()),
    ),
  );

  Future<ImageCache?> cachedImage(String path) async => (select(
    imageCaches,
  )..where((t) => t.path.equals(path))).getSingleOrNull();

  /// True when the cached bytes can be rendered without the network.
  Future<bool> hasImage(String path) async => await cachedImage(path) != null;

  Future<int> cachedImageCount() async {
    final row = await customSelect(
      'SELECT COUNT(*) AS n FROM image_caches',
      readsFrom: {imageCaches},
    ).getSingle();
    return row.read<int>('n');
  }

  Future<int> cachedImageBytes() async {
    final row = await customSelect(
      'SELECT COALESCE(SUM(LENGTH(bytes)), 0) AS n FROM image_caches',
      readsFrom: {imageCaches},
    ).getSingle();
    return row.read<int>('n');
  }

  // ------------------------------------------------------------- export (W2)

  /// "Export data (JSON)": every LOCAL table, as JSON.
  ///
  /// Browser storage can be evicted by the OS even when it was granted
  /// persistence, and the outbox may hold sales the server has never seen —
  /// so the owner gets a plain, complete dump he can keep. This is the only
  /// extra feature W2 allows, and it exists for exactly that reason.
  Future<Map<String, dynamic>> exportAll() async => {
    'exported_at': _clock().toIso8601String(),
    'schema_version': schemaVersion,
    'stores': [for (final r in await select(stores).get()) r.toJson()],
    'devices': [for (final r in await select(devices).get()) r.toJson()],
    'categories': [for (final r in await select(categories).get()) r.toJson()],
    'products': [for (final r in await select(products).get()) r.toJson()],
    'payment_methods': [
      for (final r in await select(paymentMethods).get()) r.toJson(),
    ],
    'orders': [for (final r in await select(orders).get()) r.toJson()],
    'order_items': [for (final r in await select(orderItems).get()) r.toJson()],
    'payments': [for (final r in await select(payments).get()) r.toJson()],
    'order_voids': [for (final r in await select(orderVoids).get()) r.toJson()],
    'stock_events': [
      for (final r in await select(stockEvents).get()) r.toJson(),
    ],
    'day_closes': [for (final r in await select(dayCloses).get()) r.toJson()],
    'sync_outbox': [for (final r in await select(syncOutbox).get()) r.toJson()],
    'settings': [for (final r in await select(settings).get()) r.toJson()],
    // Image bytes are deliberately NOT inlined: this dump is for the SALES,
    // and a base64 image blob would make it unopenable on a phone.
    'image_cache_paths': [
      for (final r in await select(imageCaches).get()) r.path,
    ],
  };

  /// W2 data-loss guard: how long the OLDEST unsynced sale has been waiting.
  /// Null when the outbox is empty.
  Future<DateTime?> oldestPendingAt(String storeId) async {
    final row = await customSelect(
      'SELECT MIN(created_at) AS t FROM sync_outbox '
      'WHERE store_id = ? AND synced_at IS NULL',
      variables: [Variable<String>(storeId)],
      readsFrom: {syncOutbox},
    ).getSingle();
    if (row.data['t'] == null) return null;
    final raw = row.data['t'];
    if (raw is int) {
      return DateTime.fromMillisecondsSinceEpoch(raw, isUtc: true);
    }
    if (raw is String) return DateTime.tryParse(raw)?.toUtc();
    return null;
  }

  // ---------------------------------------------------------------- stores

  /// Every store row. This install is expected to hold exactly one, so the
  /// single row doubles as the bootstrap config (W2).
  Future<List<Store>> allStores() async => select(stores).get();

  Future<Store?> store(String id) async =>
      (select(stores)..where((t) => t.id.equals(id))).getSingleOrNull();

  /// Upsert the store row. With [deviceId] the change is also enqueued, so
  /// shop/receipt details the owner edits in Settings reach the other devices
  /// (the server keeps `owner_id` as it is — ownership is never client-writable
  /// in spirit, and RLS decides it anyway).
  Future<void> upsertStore(Store s, {String? deviceId}) async {
    final now = _clock();
    await into(stores).insertOnConflictUpdate(
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
        updatedAt: Value(now),
      ),
    );
    if (deviceId != null) {
      await _enqueue(
        storeId: s.id,
        deviceId: deviceId,
        entity: 'stores',
        entityId: s.id,
        op: 'update',
        updatedAt: now,
        payload: _storeJson(s, now),
      );
    }
  }

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
        DevicesCompanion(
          deviceName: Value(name),
          updatedAt: Value(_clock()),
        ),
      );

  /// Record whether this device asked the browser to never evict its data (W2).
  /// Saved to the devices table so Settings can show it per-device.
  ///
  /// A typed drift write, NOT raw SQL: this column is an INTEGER timestamp,
  /// and binding an ISO-8601 string into it left `updated_at` as TEXT — the
  /// next SELECT of the devices table then threw `FormatException` while
  /// parsing it, which failed the whole sync dedupe pass. [_repairTextTimestamps]
  /// heals rows written by the old raw statement.
  Future<void> setDevicePersistent(String id, bool persistent) async =>
      (update(devices)..where((t) => t.id.equals(id))).write(
        DevicesCompanion(
          persistentStorage: Value(persistent),
          updatedAt: Value(_clock()),
        ),
      );

  /// Stamp the device's last_sync_at after a successful push to the server.
  Future<void> setDeviceLastSyncAt(String id) async =>
      (update(devices)..where((t) => t.id.equals(id))).write(
        DevicesCompanion(
          lastSyncAt: Value(_clock()),
          updatedAt: Value(_clock()),
        ),
      );

  /// Toggle a device's active flag. WITHOUT [storeId] this is a local-only
  /// write (the pull-time dedupe pass uses it — that pass never enqueues,
  /// same rule as B1: applying server rows must not queue server rows).
  /// WITH [storeId] it ALSO enqueues the row, so the toggle reaches the
  /// server and every other booth's next pull.
  Future<void> setDeviceActive(
    String id,
    bool active, {
    String? storeId,
    String? byDeviceId,
  }) async {
    await (update(devices)..where((t) => t.id.equals(id))).write(
      DevicesCompanion(isActive: Value(active), updatedAt: Value(_clock())),
    );
    if (storeId == null) return;
    final row = await deviceById(id);
    if (row == null) return; // already gone — nothing to tell the server
    await _enqueue(
      storeId: storeId,
      deviceId: byDeviceId ?? '',
      entity: 'devices',
      entityId: row.id,
      op: 'update',
      updatedAt: row.updatedAt,
      payload: _deviceJson(row),
    );
  }

  Future<void> touchSync(String deviceId) async =>
      (update(devices)..where((t) => t.id.equals(deviceId))).write(
        DevicesCompanion(lastSyncAt: Value(_clock())),
      );

  Future<List<Device>> listDevices(String storeId) async =>
      (select(devices)..where((t) => t.storeId.equals(storeId))).get();

  /// The server-side, code-carrying device row this fresh install can CLAIM
  /// as its own — resolved by normalised name against the local mirror,
  /// which the sync pull keeps in step with the server.
  ///
  /// Only rows that already carry a `device_code` qualify: co-existing the
  /// code means the row is a real booth identity the server knows, not this
  /// install's own unregistered placeholder. Among the candidates the newest
  /// wins (the most recent re-registration is the one whose receipts still
  /// look current).
  Future<Device?> claimableDevice(String storeId, String deviceName) async {
    final rows = await (select(
      devices,
    )..where((t) => t.storeId.equals(storeId))).get();
    final norm = NameNorm.normalize(deviceName);
    Device? best;
    for (final r in rows) {
      if (r.deviceCode.isEmpty) continue;
      if (NameNorm.normalize(r.deviceName) != norm) continue;
      if (best == null ||
          r.updatedAt.isAfter(best.updatedAt) ||
          (r.updatedAt.isAtSameMomentAs(best.updatedAt) &&
              r.isActive &&
              !best.isActive)) {
        best = r;
      }
    }
    return best;
  }

  /// Point THIS install at an existing server row: drop the freshly-minted
  /// placeholder row and copy the claimed identity into its place.
  ///
  /// Pure local work, deliberately NOT enqueued — the claimed row already
  /// exists on the server, so there is nothing to push; pushing a devices row
  /// from here would only fight the server's own lww_guard.
  Future<void> adoptDevice({
    required String storeId,
    required String oldId,
    required Device from,
  }) async {
    await (delete(devices)..where((t) => t.id.equals(oldId))).go();
    await into(devices).insertOnConflictUpdate(
      DevicesCompanion(
        id: Value(from.id),
        storeId: Value(from.storeId),
        deviceName: Value(from.deviceName),
        deviceCode: Value(from.deviceCode),
        isActive: const Value(true),
        persistentStorage: Value(from.persistentStorage),
        lastSyncAt: const Value(null),
        createdAt: Value(from.createdAt),
        updatedAt: Value(_clock()),
      ),
    );
    await setLocalSetting(storeId, 'device_id', from.id);
  }

  // ------------------------------------------------------------ categories

  Future<List<Category>> listCategories(String storeId) async =>
      (select(categories)
            ..where((t) => t.storeId.equals(storeId) & t.deletedAt.isNull())
            ..orderBy([(t) => OrderingTerm.asc(t.sortOrder)]))
          .get();

  /// The LIVE category whose normalised name equals [name] (excluding
  /// [excludeId]), or null. The save paths use it to refuse a duplicate name
  /// locally — migration 006's unique index would reject the push anyway, and
  /// a rejection that surfaces as "Sync failed" is a worse experience than a
  /// form error.
  Future<Category?> liveCategoryByName(
    String storeId,
    String name, {
    String? excludeId,
  }) async {
    final rows = await (select(
      categories,
    )..where((t) => t.storeId.equals(storeId) & t.deletedAt.isNull())).get();
    for (final r in rows) {
      if (r.id != excludeId && NameNorm.equal(r.name, name)) return r;
    }
    return null;
  }

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
      final term = search.replaceAll("'", "_");
      // Name OR exact barcode: a scanner types the code into this same box,
      // so search must find the product by the code it just received.
      q.where((t) => t.name.like('%$term%') | t.barcode.equals(search.trim()));
    }
    q.orderBy([(t) => OrderingTerm.asc(t.name)]);
    return q.get();
  }

  /// The one live product whose barcode is exactly [barcode] (scan-to-add).
  /// Barcodes are unique per store (partial unique index), so this is either
  /// one row or nothing.
  Future<Product?> productByBarcode(String storeId, String barcode) async {
    final code = barcode.trim();
    if (code.isEmpty) return null;
    return (select(products)
          ..where(
            (t) =>
                t.storeId.equals(storeId) &
                t.deletedAt.isNull() &
                t.barcode.equals(code),
          )
          ..limit(1))
        .getSingleOrNull();
  }

  Future<Product?> productById(String id) async =>
      (select(products)..where((t) => t.id.equals(id))).getSingleOrNull();

  /// The LIVE product whose normalised name equals [name] (excluding
  /// [excludeId]), or null — see [liveCategoryByName].
  Future<Product?> liveProductByName(
    String storeId,
    String name, {
    String? excludeId,
  }) async {
    final rows = await (select(
      products,
    )..where((t) => t.storeId.equals(storeId) & t.deletedAt.isNull())).get();
    for (final r in rows) {
      if (r.id != excludeId && NameNorm.equal(r.name, name)) return r;
    }
    return null;
  }

  /// Fast check if the store already has products seeded or downloaded.
  Future<bool> hasProducts(String storeId) async {
    final row =
        await (select(products)
              ..where((t) => t.storeId.equals(storeId) & t.deletedAt.isNull())
              ..limit(1))
            .getSingleOrNull();
    return row != null;
  }

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
        stockStatus: Value(p.stockStatus),
        sourceRef: Value(p.sourceRef),
        notes: Value(p.notes),
        sourceCol1: Value(p.sourceCol1),
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
  // ------------------------------------------------------- catalogue seed (W6)
  //
  // The bundled catalogue is a LOCAL bootstrap: the phone already carries the
  // shop's shelf, so a booth with no signal still shows the real products.
  // These helpers therefore NEVER enqueue — the server import is the
  // authority for the shared copy — and they NEVER overwrite a row the owner
  // already changed on this device.

  /// The shop row, if the device has none. The id is the SAME one the server
  /// import uses (uuid v5 of "store:main"), so the two copies are one row.
  Future<bool> seedStore(Store s) async {
    if (await store(s.id) != null) return false;
    await into(stores).insert(
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
        updatedAt: Value(s.updatedAt),
      ),
      mode: InsertMode.insertOrIgnore,
    );
    return true;
  }

  /// A shelf category, if the device has none.
  Future<bool> seedCategory(Category c) async {
    final existing = await (select(
      categories,
    )..where((t) => t.id.equals(c.id))).getSingleOrNull();
    if (existing != null) return false;
    await into(categories).insert(
      CategoriesCompanion(
        id: Value(c.id),
        storeId: Value(c.storeId),
        name: Value(c.name),
        sortOrder: Value(c.sortOrder),
        isActive: Value(c.isActive),
        createdAt: Value(c.createdAt),
        updatedAt: Value(c.updatedAt),
        deletedAt: const Value(null),
        syncedAt: const Value(null),
      ),
      mode: InsertMode.insertOrIgnore,
    );
    return true;
  }

  /// A product, if the device has none. The owner's edits always win.
  Future<bool> seedProduct(Product p) async {
    if (await productById(p.id) != null) return false;
    await into(products).insert(
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
        stockStatus: Value(p.stockStatus),
        sourceRef: Value(p.sourceRef),
        notes: Value(p.notes),
        sourceCol1: Value(p.sourceCol1),
        createdAt: Value(p.createdAt),
        updatedAt: Value(p.updatedAt),
        deletedAt: const Value(null),
        syncedAt: const Value(null),
      ),
      mode: InsertMode.insertOrIgnore,
    );
    return true;
  }

  /// The opening stock of a product, as a stock event.
  ///
  /// The event id is the SAME one the server import writes (uuid v5 of
  /// "stock_import:{product_id}"), so when the device and the server meet the
  /// event is inserted once, never twice: the stock is counted exactly once
  /// on each side.
  Future<bool> seedOpeningStock({
    required String productId,
    required int delta,
    required String storeId,
    required DateTime at,
  }) async {
    final id = StableId.of('stock_import', productId);
    final existing = await (select(
      stockEvents,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    if (existing != null) return false;
    await into(stockEvents).insert(
      StockEventsCompanion(
        id: Value(id),
        storeId: Value(storeId),
        productId: Value(productId),
        delta: Value(delta),
        reason: const Value('import'),
        orderId: const Value(null),
        deviceId: const Value(null),
        createdAt: Value(at),
      ),
      mode: InsertMode.insertOrIgnore,
    );
    await _mirrorStock(productId, at);
    return true;
  }

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

  /// The LIVE payment method whose normalised name equals [name] (excluding
  /// [excludeId]), or null — see [liveCategoryByName].
  Future<PaymentMethod?> livePaymentMethodByName(
    String storeId,
    String name, {
    String? excludeId,
  }) async {
    final rows = await (select(
      paymentMethods,
    )..where((t) => t.storeId.equals(storeId) & t.deletedAt.isNull())).get();
    for (final r in rows) {
      if (r.id != excludeId && NameNorm.equal(r.name, name)) return r;
    }
    return null;
  }

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

  /// Orders (active/non-voided) whose createdAt falls within [start, end) UTC.
  /// Voided is derived from order_voids (F3).
  Future<List<Order>> ordersInRange(
    String storeId, {
    required DateTime start,
    required DateTime end,
  }) async {
    final voidedIds = (await select(
      orderVoids,
    ).get()).map((v) => v.orderId).toSet();
    final rows =
        await (select(orders)
              ..where((t) => t.storeId.equals(storeId))
              ..where((t) => t.createdAt.isBiggerOrEqualValue(start))
              ..where((t) => t.createdAt.isSmallerThanValue(end)))
            .get();
    return rows.where((o) => !voidedIds.contains(o.id)).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  /// Voided orders whose createdAt falls within [start, end) UTC.
  Future<List<Order>> voidedOrdersInRange(
    String storeId, {
    required DateTime start,
    required DateTime end,
  }) async {
    final voidedIds = (await select(
      orderVoids,
    ).get()).map((v) => v.orderId).toSet();
    final rows =
        await (select(orders)
              ..where((t) => t.storeId.equals(storeId))
              ..where((t) => t.createdAt.isBiggerOrEqualValue(start))
              ..where((t) => t.createdAt.isSmallerThanValue(end)))
            .get();
    return rows.where((o) => voidedIds.contains(o.id)).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  /// Items for the given orders, oldest first.
  Future<List<OrderItem>> orderItemsForOrders(List<String> orderIds) async {
    if (orderIds.isEmpty) return const [];
    return (select(orderItems)
          ..where((t) => t.orderId.isIn(orderIds))
          ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
        .get();
  }

  /// Sales grouped by category for active (non-voided) orders in a UTC range.
  /// Returns (category_name, total, count) sorted by total descending.
  Future<List<({String name, double total, int count})>> salesByCategory(
    String storeId, {
    required DateTime start,
    required DateTime end,
  }) async {
    final voidedIds = (await select(
      orderVoids,
    ).get()).map((v) => v.orderId).toSet();
    final rows =
        await (select(orders)
              ..where((t) => t.storeId.equals(storeId))
              ..where((t) => t.createdAt.isBiggerOrEqualValue(start))
              ..where((t) => t.createdAt.isSmallerThanValue(end)))
            .get();
    final active = rows.where((o) => !voidedIds.contains(o.id)).toList();
    if (active.isEmpty) return const [];
    final ids = active.map((o) => o.id).toList();
    final items = await (select(
      orderItems,
    )..where((t) => t.orderId.isIn(ids))).get();
    final prodIds = items
        .where((it) => it.productId != null)
        .map((it) => it.productId!)
        .toSet();
    final products = <String, Product>{};
    for (final pid in prodIds) {
      final p = await productById(pid);
      if (p != null) products[pid] = p;
    }
    final catIds = products.values
        .where((p) => p.categoryId != null)
        .map((p) => p.categoryId!)
        .toSet();
    final catMap = <String, Category>{};
    for (final cid in catIds) {
      final c = await (select(
        categories,
      )..where((t) => t.id.equals(cid))).getSingleOrNull();
      if (c != null) catMap[cid] = c;
    }
    // Use separate accumulators since Dart can't infer named tuple types in map literals.
    final totals = <String, double>{};
    final counts = <String, int>{};
    final names = <String, String>{};
    for (final it in items) {
      if (it.productId == null) continue;
      final p = products[it.productId];
      if (p == null) continue;
      final cid = p.categoryId;
      if (cid == null) continue;
      final c = catMap[cid];
      if (c == null) continue;
      final order = active.firstWhere((o) => o.id == it.orderId);
      if (voidedIds.contains(order.id)) continue;
      totals[cid] = (totals[cid] ?? 0) + it.lineTotal;
      counts[cid] = (counts[cid] ?? 0) + it.quantity;
      names[cid] = c.name;
    }
    return names.entries
        .map(
          (e) => (
            name: e.value,
            total: Money.round(totals[e.key] ?? 0),
            count: counts[e.key] ?? 0,
          ),
        )
        .toList()
      ..sort((a, b) => b.total.compareTo(a.total));
  }

  /// Payments for the given orders.
  Future<List<Payment>> paymentsForOrders(List<String> orderIds) async {
    if (orderIds.isEmpty) return const [];
    return (select(payments)..where((t) => t.orderId.isIn(orderIds))).get();
  }

  /// The day's best sellers for the Sell screen's quick-add row: active
  /// (non-voided) order items in [start, end) grouped by product, most units
  /// first, limited to products that are still live AND sellable. Follows the
  /// same void-derivation rule as [salesByCategory]; reads only one day, so
  /// the 3 GB device never holds a whole history. Each row carries the unit
  /// count so the chip can say "×3".
  Future<List<(Product, int)>> topSellers(
    String storeId, {
    required DateTime start,
    required DateTime end,
    int limit = 8,
  }) async {
    final voidedIds =
        (await select(orderVoids).get()).map((v) => v.orderId).toSet();
    final rows =
        await (select(orders)
              ..where((t) => t.storeId.equals(storeId))
              ..where((t) => t.createdAt.isBiggerOrEqualValue(start))
              ..where((t) => t.createdAt.isSmallerThanValue(end)))
            .get();
    final active = rows.where((o) => !voidedIds.contains(o.id)).toList();
    if (active.isEmpty) return const [];
    final ids = active.map((o) => o.id).toList();
    final items =
        await (select(orderItems)..where((t) => t.orderId.isIn(ids))).get();
    final units = <String, int>{};
    for (final it in items) {
      final pid = it.productId;
      if (pid == null) continue;
      units[pid] = (units[pid] ?? 0) + it.quantity;
    }
    if (units.isEmpty) return const [];
    final ranked = units.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final out = <(Product, int)>[];
    for (final e in ranked) {
      if (out.length >= limit) break;
      final p = await productById(e.key);
      if (p == null || !p.isActive) continue;
      if (!StockRules.canSell(stock: p.stockQuantity, status: p.stockStatus)) {
        continue;
      }
      out.add((p, e.value));
    }
    return out;
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
    int? limit,
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
    if (limit != null) {
      // W3/4.4: never load the whole order table. When voided rows are about
      // to be dropped in Dart, fetch enough EXTRA rows that [limit] survivors
      // remain — the slack is bounded by the (small) void table.
      final slack = includeVoided ? 0 : voidedIds.length;
      q.limit(limit + slack);
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
    if (limit != null && result.length > limit) {
      return result.sublist(0, limit);
    }
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
  ///
  /// [limit] keeps the query bounded (device rule: a list must never pull the
  /// whole history into memory); callers page by moving the day filter rather
  /// than by scrolling forever.
  Future<List<Order>> listOrders(
    String storeId, {
    String? paymentMethodId,
    DateTime? businessDate,
    int? limit,
  }) async {
    final rows = await _ordersMatching(
      storeId,
      businessDate: businessDate,
      limit: limit,
    );
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
    // NO outbox row means the order never waited on THIS device's queue: it
    // arrived by pull or import — it is already on the server. Treating
    // "no row" as unsynced made every pulled order show Pending forever
    // while the Sync chip rightly said Synced (the queue was empty).
    final synced = outbox.every((e) => e.syncedAt != null);
    return OrderChips.of(hasVoid: hasVoid, synced: synced, failed: failed);
  }

  /// The same rule as [chipFor] for a WHOLE page of orders, in two queries
  /// instead of 2 × N. A screen must not fire a query per list row.
  Future<Map<String, OrderChip>> chipsFor(List<Order> orders) async {
    if (orders.isEmpty) return const {};
    final ids = orders.map((o) => o.id).toSet();

    final voided = (await select(orderVoids).get())
        .where((v) => ids.contains(v.orderId))
        .map((v) => v.orderId)
        .toSet();

    final outbox = await (select(
      syncOutbox,
    )..where((t) => t.entityId.isIn(ids.toList()))).get();
    final byOrder = <String, List<SyncOutboxData>>{};
    for (final e in outbox) {
      byOrder.putIfAbsent(e.entityId, () => []).add(e);
    }

    final out = <String, OrderChip>{};
    for (final o in orders) {
      final rows = byOrder[o.id] ?? const <SyncOutboxData>[];
      final failed = rows.any((e) => e.lastError != null && e.syncedAt == null);
      // Same rule as chipFor: an empty outbox = server-origin = Synced.
      final synced = rows.every((e) => e.syncedAt != null);
      out[o.id] = OrderChips.of(
        hasVoid: voided.contains(o.id),
        synced: synced,
        failed: failed,
      );
    }
    return out;
  }

  /// The sold lines of one order, oldest first — the receipt and the order
  /// detail both read them.
  Future<List<OrderItem>> orderItemsOf(String orderId) async =>
      (select(orderItems)
            ..where((t) => t.orderId.equals(orderId))
            ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
          .get();

  /// The payment snapshot of one order (written once, at sale time).
  Future<Payment?> paymentOf(String orderId) async => (select(
    payments,
  )..where((t) => t.orderId.equals(orderId))).getSingleOrNull();

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
  ///
  /// [cashFloat] is the money already in the drawer when the day started. The
  /// drawer expectation the owner counts against is float + the day's cash
  /// sales, so the float is folded INTO `cash_expected` — which keeps the
  /// invariant every reader depends on: `variance = cash_actual -
  /// cash_expected`. Call it without a float (or with 0) and `cash_expected`
  /// is exactly "cash orders minus voids" (plan §3.11).
  Future<DayClose> closeDay({
    required String storeId,
    required String deviceId,
    required DateTime businessDate,
    required String cashPaymentMethodId,
    double? cashActual,
    double? cashFloat,
    String? closedBy,
  }) async {
    final now = _clock();
    final tz = await tzOffsetMinutes(storeId);
    final day = BusinessDate.startOfDayUtc(
      businessDate,
      tzOffsetMinutes: tz,
    );
    final cashSales = await cashExpected(
      storeId: storeId,
      businessDate: day,
      cashPaymentMethodId: cashPaymentMethodId,
      deviceId: deviceId,
    );
    final expected = r2(cashSales + (cashFloat ?? 0));
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
          // The server column is a `date`: send the STORE-LOCAL day, never
          // the UTC instant (which is the previous calendar day in Manila).
          'business_date': BusinessDate.key(day, tzOffsetMinutes: tz),
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
        'business_date': BusinessDate.key(day, tzOffsetMinutes: tz),
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

  /// Mark every live photo-less product INACTIVE — once per store.
  ///
  /// The Sell grid used to hide photo-less products at render time, which
  /// left them ACTIVE in Products: ~4 in 10 shelf items vanished from Sell
  /// while the management screen called them on. Inactive is the honest
  /// state for a product the owner has not published yet, so this sweep sets
  /// the flag once at launch and [Product.isActive] becomes the ONLY rule
  /// both screens read — one switched back on still gets the neutral
  /// placeholder on Sell.
  ///
  /// Deliberately device-local: no outbox row is queued (a presentation
  /// call, and a product push would only be refused by the server's
  /// unique-name index anyway). The local-setting guard makes it run exactly
  /// once, so it can never re-hide a product the owner has since enabled.
  Future<int> deactivatePhotolessProducts(String storeId) async {
    if (await getSetting(storeId, _kPhotolessSwept) != null) return 0;
    final rows =
        await (select(products)..where(
              (t) =>
                  t.storeId.equals(storeId) &
                  t.deletedAt.isNull() &
                  t.isActive.equals(true) &
                  (t.imagePath.isNull() | t.imagePath.equals('')),
            ))
            .get();
    for (final p in rows) {
      await (update(products)..where((t) => t.id.equals(p.id))).write(
        const ProductsCompanion(isActive: Value(false)),
      );
    }
    await setLocalSetting(storeId, _kPhotolessSwept, 'yes');
    return rows.length;
  }

  /// The local setting that keeps [deactivatePhotolessProducts] one-shot.
  static const _kPhotolessSwept = 'photoless_products_swept';

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

  /// A pulled row has taken over the identity of a local same-name twin:
  /// every UNSENT outbox event for the twin must follow it.
  ///
  /// Without this the twin's edit is pushed under an id the server no longer
  /// has — a CREATE for a name the server already owns, which 006 refuses, so
  /// the row would fail every retry and the owner's correction would never
  /// land. Retargeting keeps one event, one row, one name.
  Future<void> _retargetOutbox(
    String entity,
    String fromId,
    String toId,
  ) async {
    final pending =
        await (select(syncOutbox)..where(
              (t) =>
                  t.entity.equals(entity) &
                  t.entityId.equals(fromId) &
                  t.syncedAt.isNull(),
            ))
            .get();
    for (final e in pending) {
      final payload = <String, dynamic>{};
      try {
        payload.addAll(jsonDecode(e.payload) as Map<String, dynamic>);
      } catch (_) {
        // A malformed payload is not worth carrying; the local row is already
        // written, and the next save re-enqueues a clean one.
        continue;
      }
      payload['id'] = toId;
      await (delete(syncOutbox)..where((t) => t.id.equals(e.id))).go();
      await _enqueue(
        storeId: e.storeId,
        deviceId: e.deviceId,
        entity: entity,
        entityId: toId,
        op: 'update',
        updatedAt: e.createdAt,
        payload: payload,
      );
    }
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

  /// Give every unsynced row of this store's queue a fresh set of attempts.
  /// Owner-recovery only (Settings → "Re-pull from server"): that dialog
  /// promises "Sales already here are kept and pushed back up", and a PARKED
  /// queue would silently refuse that promise. The attempt cap and backoff
  /// protect the server from a runaway 10 s timer; a human who just confirmed
  /// "Fetch all" is not a runaway timer. The old last_error is kept until a
  /// new result overwrites it, so Sync details never loses the history.
  Future<void> resetOutboxAttempts(String storeId) async =>
      (update(syncOutbox)
            ..where((t) => t.storeId.equals(storeId))
            ..where((t) => t.syncedAt.isNull()))
          .write(
            SyncOutboxCompanion(
              attempts: const Value(0),
              nextAttemptAt: const Value(null),
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

  /// Clears this store's per-table pull cursors so the NEXT pull re-reads
  /// every page from the beginning. Applying rows is idempotent, so a full
  /// re-pull never duplicates anything. This is the owner's recovery tool for
  /// what [PullPlan] cannot see alone: if the SERVER's data was wiped or
  /// rebuilt while a device held a cursor past that watermark, re-created
  /// rows older than the cursor would stay invisible to that device forever.
  Future<void> resetPullCursors(String storeId) async {
    final rows =
        await (select(settings)
              ..where((t) => t.storeId.equals(storeId))
              ..where((t) => t.key.like('pull_cursor:%')))
            .get();
    for (final s in rows) {
      await (delete(
        settings,
      )..where((t) => t.storeId.equals(storeId) & t.key.equals(s.key))).go();
    }
  }

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
        persistentStorage: Value(row['persistent_storage'] as bool? ?? false),
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
    final storeId = row['store_id'] as String;
    final name = row['name'] as String;
    final existing = await (select(
      categories,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    final serverUpdated = _ts(row['updated_at']);
    final serverDeleted = _ts(row['deleted_at']);

    // A TOMBSTONE (server deleted this row) is about the row's identity, not
    // its name: it may only reach the row with this exact id. Merging it into
    // a live same-name twin would kill the twin that just won the merge — so
    // when the id is unknown locally, a dead row is simply dropped.
    if (serverDeleted != null && existing == null) return false;

    // A LIVE category whose NORMALISED name matches a different local id
    // (seeded before this device ever pulled the server catalogue): merge by
    // name, or the Sell chips show the same shelf twice. The local row's
    // products follow the server id — the id the pulled products also carry —
    // and the twin is deleted, so exactly ONE live row per name survives.
    Category? newerTwin;
    if (serverDeleted == null) {
      final localTwins =
          await (select(categories)
                ..where((t) => t.storeId.equals(storeId))
                ..where((t) => t.deletedAt.isNull())
                ..where((t) => t.id.isNotIn([id])))
              .get();
      for (final twin in localTwins.where(
        (t) => NameNorm.equal(t.name, name),
      )) {
        if (!LastWriteWins.serverWins(
          localUpdatedAt: twin.updatedAt,
          serverUpdatedAt: serverUpdated,
        )) {
          // The local twin is newer (e.g. renamed after seeding): its CONTENT
          // wins, but the id below is the server's, so carry the edit over to
          // it — standing down here would leave two devices holding the same
          // shelf under different ids, and 006 refuses the twin's push.
          newerTwin = twin;
          await _retargetOutbox('categories', twin.id, id);
        }
        await (update(products)
              ..where((t) => t.storeId.equals(storeId))
              ..where((t) => t.categoryId.equals(twin.id)))
            .write(ProductsCompanion(categoryId: Value(id)));
        await (delete(categories)..where((t) => t.id.equals(twin.id))).go();
      }
    }

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
    // The retired twin was edited after the server row: keep what the owner
    // typed on screen (the outbox carries it to the server on the next push).
    if (newerTwin != null) {
      await (update(categories)..where((t) => t.id.equals(id))).write(
        CategoriesCompanion(
          name: Value(newerTwin.name),
          sortOrder: Value(newerTwin.sortOrder),
          isActive: Value(newerTwin.isActive),
          updatedAt: Value(newerTwin.updatedAt),
        ),
      );
    }
    return true;
  }

  Future<bool> _applyRemoteProduct(Map<String, dynamic> row) async {
    final id = row['id'] as String;
    final storeId = row['store_id'] as String;
    final name = row['name'] as String;
    final serverUpdated = _ts(row['updated_at']);
    final serverDeleted = _ts(row['deleted_at']);

    // Try to find by server ID first (normal sync match).
    var existing = await productById(id);

    // A TOMBSTONE is about identity, never name: it may only reach the row
    // with this exact id. A dead row whose id is unknown here is dropped
    // instead of being merged into — and thereby killing — the live
    // same-name twin that survived the server-side dedupe.
    if (serverDeleted != null && existing == null) return false;

    // If not found by ID, a LIVE product whose NORMALISED name matches a
    // different local id may exist (catalogue seed, or a duplicate the server
    // has since merged). Merge by name so we never show the shelf twice.
    // `get()` + an explicit pick, because when duplicates DO exist locally
    // (the very bug being fixed) a single-row read would throw mid-pull.
    if (existing == null && serverDeleted == null) {
      final twins =
          await (select(products)
                ..where((t) => t.storeId.equals(storeId))
                ..where((t) => t.deletedAt.isNull())
                ..where((t) => t.id.isNotIn([id])))
              .get();
      final matches = twins.where((t) => NameNorm.equal(t.name, name)).toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      if (matches.isNotEmpty) existing = matches.first;
    }

    // A name-matched TWIN is not a last-write-wins contest — its id is the
    // thing being retired, so it can never block the server row.
    final isTwin = existing != null && existing.id != id;
    if (!isTwin &&
        !LastWriteWins.serverWins(
          localUpdatedAt: existing?.updatedAt,
          serverUpdatedAt: serverUpdated,
        )) {
      return false;
    }

    // A pulled product's barcode must not collide with another product's
    // barcode in the same store — the unique index on (store_id, barcode)
    // would reject the insert. Barcodes are non-critical reference data, so
    // nulling the colliding barcode is safe and keeps the product importable.
    final rawBarcode = row['barcode'] as String?;
    final barcode = rawBarcode != null && rawBarcode.isNotEmpty
        ? await _nonConflictingBarcode(storeId, existing?.id ?? id, rawBarcode)
        : null;

    if (existing != null && existing.id == id) {
      // Exact ID match — normal upsert (insert or update).
      await into(products).insertOnConflictUpdate(
        ProductsCompanion(
          id: Value(id),
          storeId: Value(storeId),
          categoryId: Value(row['category_id'] as String?),
          name: Value(name),
          price: Value((row['price'] as num).toDouble()),
          barcode: Value(barcode),
          imagePath: Value(row['image_path'] as String?),
          stockQuantity: const Value.absent(),
          isActive: Value(row['is_active'] as bool? ?? true),
          stockStatus: row.containsKey('stock_status')
              ? Value((row['stock_status'] as String?) ?? 'In Stock')
              : const Value.absent(),
          sourceRef: row.containsKey('source_ref')
              ? Value(row['source_ref'] as String?)
              : const Value.absent(),
          notes: row.containsKey('notes')
              ? Value(row['notes'] as String?)
              : const Value.absent(),
          sourceCol1: row.containsKey('source_col1')
              ? Value((row['source_col1'] as num?)?.toInt())
              : const Value.absent(),
          createdAt: Value(_ts(row['created_at']) ?? existing.createdAt),
          updatedAt: Value(serverUpdated ?? existing.updatedAt),
          deletedAt: Value(_ts(row['deleted_at'])),
        ),
      );
      await rebuildStockMirror(id);
    } else if (existing != null) {
      // Same NORMALISED name, different id: THE SERVER ROW IS THE IDENTITY.
      //
      // The old behaviour here kept the local id and only copied the server's
      // fields onto it. That was survivable while the server accepted a second
      // row with the same name — but 006 now REFUSES one, so the next push of
      // this name would fail with a duplicate key forever and the catalogue
      // edit would never leave the device. Adopting the server id (and moving
      // the twin's sales history onto it) makes later pushes ordinary updates.
      //
      // Content still follows the newer side: when the twin was edited after
      // the server row, its payload is re-pointed at the server id so the
      // push carries the edit instead of dropping it.
      final twin = existing;
      final twinId = twin.id;
      final localWins = twin.updatedAt.isAfter(serverUpdated ?? twin.updatedAt);
      if (localWins) await _retargetOutbox('products', twinId, id);
      // The twin almost always carries the SAME barcode — it is the same
      // shelf item, and both rows come from the source inventory sheet. The
      // unique index on (store_id, barcode) would reject the insert below
      // while the twin still holds the code, and the quarantine in _pull
      // would skip the row as "unapplyable": on a wiped phone that skipped
      // the WHOLE catalogue (the seed twin is on every row). Free the code
      // first; the survivor's own barcode is written from the in-memory twin
      // (localWins) or the sanitised server value a few lines below, and the
      // twin itself is deleted at the end of this branch.
      await (update(products)..where((t) => t.id.equals(twinId)))
          .write(const ProductsCompanion(barcode: Value(null)));
      await into(products).insertOnConflictUpdate(
        ProductsCompanion(
          id: Value(id),
          storeId: Value(storeId),
          categoryId: Value(
            localWins ? twin.categoryId : row['category_id'] as String?,
          ),
          name: Value(localWins ? twin.name : name),
          price: Value(
            localWins ? twin.price : (row['price'] as num).toDouble(),
          ),
          barcode: Value(localWins ? twin.barcode : barcode),
          imagePath: Value(
            localWins ? twin.imagePath : row['image_path'] as String?,
          ),
          // The twin's quantity is the local truth: a CSV-imported product
          // carries stock with no events behind it, so it must not be lost.
          stockQuantity: Value(twin.stockQuantity),
          isActive: Value(
            localWins ? twin.isActive : row['is_active'] as bool? ?? true,
          ),
          stockStatus: localWins
              ? Value(twin.stockStatus)
              : row.containsKey('stock_status')
              ? Value((row['stock_status'] as String?) ?? 'In Stock')
              : const Value.absent(),
          sourceRef: localWins
              ? Value(twin.sourceRef)
              : row.containsKey('source_ref')
              ? Value(row['source_ref'] as String?)
              : const Value.absent(),
          notes: localWins
              ? Value(twin.notes)
              : row.containsKey('notes')
              ? Value(row['notes'] as String?)
              : const Value.absent(),
          sourceCol1: localWins
              ? Value(twin.sourceCol1)
              : row.containsKey('source_col1')
              ? Value((row['source_col1'] as num?)?.toInt())
              : const Value.absent(),
          createdAt: Value(_ts(row['created_at']) ?? twin.createdAt),
          updatedAt: Value(
            localWins ? twin.updatedAt : (serverUpdated ?? twin.updatedAt),
          ),
          deletedAt: const Value(null),
        ),
      );
      await (update(orderItems)..where((t) => t.productId.equals(twinId)))
          .write(OrderItemsCompanion(productId: Value(id)));
      final movedStock =
          await (update(stockEvents)..where((t) => t.productId.equals(twinId)))
              .write(StockEventsCompanion(productId: Value(id)));
      await (delete(products)..where((t) => t.id.equals(twinId))).go();
      // Events moved, so the mirror must be recomputed from them; with no
      // events the twin's own quantity stays as it was.
      if (movedStock > 0) await rebuildStockMirror(id);
    } else {
      // Brand new product — insert with server ID.
      await into(products).insert(
        ProductsCompanion(
          id: Value(id),
          storeId: Value(storeId),
          categoryId: Value(row['category_id'] as String?),
          name: Value(name),
          price: Value((row['price'] as num).toDouble()),
          barcode: Value(barcode),
          imagePath: Value(row['image_path'] as String?),
          stockQuantity: const Value(0),
          isActive: Value(row['is_active'] as bool? ?? true),
          stockStatus: row.containsKey('stock_status')
              ? Value((row['stock_status'] as String?) ?? 'In Stock')
              : const Value.absent(),
          sourceRef: row.containsKey('source_ref')
              ? Value(row['source_ref'] as String?)
              : const Value.absent(),
          notes: row.containsKey('notes')
              ? Value(row['notes'] as String?)
              : const Value.absent(),
          sourceCol1: row.containsKey('source_col1')
              ? Value((row['source_col1'] as num?)?.toInt())
              : const Value.absent(),
          createdAt: Value(_ts(row['created_at']) ?? _clock()),
          updatedAt: Value(serverUpdated ?? _clock()),
          deletedAt: Value(_ts(row['deleted_at'])),
        ),
      );
      await rebuildStockMirror(id);
    }
    return true;
  }

  /// Returns [barcode] unless another product in [storeId] already uses it
  /// (excluding [productId] itself, which is the row being imported). In that
  /// case returns null so the insert doesn't violate the unique barcode index.
  Future<String?> _nonConflictingBarcode(
    String storeId,
    String productId,
    String barcode,
  ) async {
    final rows =
        await (select(products)
              ..where((t) => t.storeId.equals(storeId))
              ..where((t) => t.barcode.equals(barcode)))
            .get();
    final conflict = rows.any((r) => r.id != productId);
    return conflict ? null : barcode;
  }

  /// Deduplicate categories by name after a sync pull.
  ///
  /// When the server's category IDs differ from locally-seeded IDs, duplicate
  /// category rows with the same name can exist on the device. This merges
  /// them into one: keeps the category referenced by the most products
  /// (ties broken by earliest createdAt), repoints all products to it, and
  /// deletes the rest. Names are compared with [NameNorm] so "Sticker sheets"
  /// and "sticker  sheets" cannot survive as two chips. Only LIVE rows merge;
  /// a tombstoned twin is already invisible and must not be resurrected.
  Future<void> deduplicateCategories(String storeId) async {
    final rows =
        await (select(categories)
              ..where((t) => t.storeId.equals(storeId))
              ..where((t) => t.deletedAt.isNull()))
            .get();
    final byName = <String, List<Category>>{};
    for (final r in rows) {
      byName.putIfAbsent(NameNorm.normalize(r.name), () => []).add(r);
    }

    for (final entry in byName.entries) {
      final cats = entry.value;
      if (cats.length <= 1) continue;

      // Keep the category referenced by the most products; ties broken by
      // earliest createdAt (oldest survives). Compute counts first because
      // sort() cannot take an async comparator.
      final counts = <String, int>{};
      for (final c in cats) {
        counts[c.id] = await _productCountForCategory(storeId, c.id);
      }
      cats.sort((a, b) {
        final ca = counts[a.id] ?? 0;
        final cb = counts[b.id] ?? 0;
        final c = cb.compareTo(ca); // more products first
        if (c != 0) return c;
        return a.createdAt.compareTo(b.createdAt); // earlier createdAt first
      });
      final keep = cats.first;
      final twins = cats.skip(1);

      // Repoint all products from twins to the kept category.
      for (final twin in twins) {
        await (update(products)
              ..where((t) => t.storeId.equals(storeId))
              ..where((t) => t.categoryId.equals(twin.id)))
            .write(ProductsCompanion(categoryId: Value(keep.id)));
        await (delete(categories)..where((t) => t.id.equals(twin.id))).go();
      }
    }
  }

  /// Count products referencing [categoryId] in [storeId].
  Future<int> _productCountForCategory(
    String storeId,
    String categoryId,
  ) async {
    final rows =
        await (select(products)
              ..where((t) => t.storeId.equals(storeId))
              ..where((t) => t.categoryId.equals(categoryId)))
            .get();
    return rows.length;
  }

  /// Count orders referencing [methodId] in [storeId].
  Future<int> _orderCountForMethod(String storeId, String methodId) async {
    final rows =
        await (select(orders)
              ..where((t) => t.storeId.equals(storeId))
              ..where((t) => t.paymentMethodId.equals(methodId)))
            .get();
    return rows.length;
  }

  /// Deduplicate payment methods by name after a sync pull.
  ///
  /// Same logic as [deduplicateCategories] (normalised names, live rows only):
  /// keeps the method referenced by the most orders, repoints all orders to
  /// it, deletes the rest.
  Future<void> deduplicatePaymentMethods(String storeId) async {
    final rows =
        await (select(paymentMethods)
              ..where((t) => t.storeId.equals(storeId))
              ..where((t) => t.deletedAt.isNull()))
            .get();
    final byName = <String, List<PaymentMethod>>{};
    for (final r in rows) {
      byName.putIfAbsent(NameNorm.normalize(r.name), () => []).add(r);
    }

    for (final entry in byName.entries) {
      final methods = entry.value;
      if (methods.length <= 1) continue;

      final counts = <String, int>{};
      for (final m in methods) {
        counts[m.id] = await _orderCountForMethod(storeId, m.id);
      }
      methods.sort((a, b) {
        final ca = counts[a.id] ?? 0;
        final cb = counts[b.id] ?? 0;
        final c = cb.compareTo(ca);
        if (c != 0) return c;
        return a.createdAt.compareTo(b.createdAt);
      });
      final keep = methods.first;
      final twins = methods.skip(1);

      for (final twin in twins) {
        await (update(orders)
              ..where((t) => t.storeId.equals(storeId))
              ..where((t) => t.paymentMethodId.equals(twin.id)))
            .write(OrdersCompanion(paymentMethodId: Value(keep.id)));
        await (delete(paymentMethods)..where((t) => t.id.equals(twin.id))).go();
      }
    }
  }

  /// Settle same-name devices after a sync pull — WITHOUT touching history.
  ///
  /// Devices are identities, not catalogue items: every re-registration is a
  /// row with its own device_code, and a sale keeps the code it was issued
  /// under. The live catalogue carried nine "Booth iPad" rows for one tablet,
  /// but deleting or repointing them would rewrite who sold what and could
  /// recycle a code that already appears on a receipt. So this pass only marks
  /// the stale twins INACTIVE: this install's own row always stays active, and
  /// among the rest the newest registration does. Nothing is deleted, so a bad
  /// merge can never orphan a sale or force a mid-shift re-registration.
  Future<void> deduplicateDevices(String storeId) async {
    final rows = await (select(
      devices,
    )..where((t) => t.storeId.equals(storeId))).get();
    final byName = <String, List<Device>>{};
    for (final r in rows) {
      byName.putIfAbsent(NameNorm.normalize(r.deviceName), () => []).add(r);
    }
    final ownId = (await getSetting(storeId, 'device_id'))?.value;

    for (final entry in byName.entries) {
      final devs = entry.value;
      if (devs.length <= 1) continue;

      devs.sort((a, b) {
        final ownA = a.id == ownId ? 1 : 0;
        final ownB = b.id == ownId ? 1 : 0;
        if (ownA != ownB) return ownB.compareTo(ownA); // this install first
        return b.createdAt.compareTo(a.createdAt); // else the newest
      });

      for (final twin in devs.skip(1).where((d) => d.isActive)) {
        await setDeviceActive(twin.id, false);
      }
    }
  }

  /// Deduplicate products by name after a sync pull.
  ///
  /// Keeps the product referenced by the most order_items, repoints order_items
  /// from twins to the kept product, deletes the rest. Names are compared
  /// with [NameNorm] (normalised, case- and space-insensitive): "PHM" and
  /// "phm" were two rows in the live catalogue and both showed on the Sell
  /// screen. Only LIVE rows merge — a tombstoned twin is already invisible.
  Future<void> deduplicateProducts(String storeId) async {
    final rows =
        await (select(products)
              ..where((t) => t.storeId.equals(storeId))
              ..where((t) => t.deletedAt.isNull()))
            .get();
    final byName = <String, List<Product>>{};
    for (final r in rows) {
      byName.putIfAbsent(NameNorm.normalize(r.name), () => []).add(r);
    }

    for (final entry in byName.entries) {
      final prods = entry.value;
      if (prods.length <= 1) continue;

      final counts = <String, int>{};
      for (final p in prods) {
        counts[p.id] = await _orderItemCountForProduct(p.id);
      }
      prods.sort((a, b) {
        final ca = counts[a.id] ?? 0;
        final cb = counts[b.id] ?? 0;
        final c = cb.compareTo(ca);
        if (c != 0) return c;
        return a.createdAt.compareTo(b.createdAt);
      });
      final keep = prods.first;
      final twins = prods.skip(1);

      for (final twin in twins) {
        await (update(orderItems)..where((t) => t.productId.equals(twin.id)))
            .write(OrderItemsCompanion(productId: Value(keep.id)));
        // The twin's stock history is the keeper's too: leaving the events
        // behind would orphan them against a deleted row and shrink stock.
        final movedStock =
            await (update(stockEvents)
                  ..where((t) => t.productId.equals(twin.id)))
                .write(StockEventsCompanion(productId: Value(keep.id)));
        await (delete(products)..where((t) => t.id.equals(twin.id))).go();
        if (movedStock > 0) await rebuildStockMirror(keep.id);
      }
    }
  }

  /// Count order_items referencing [productId].
  Future<int> _orderItemCountForProduct(String productId) async {
    final rows = await (select(
      orderItems,
    )..where((t) => t.productId.equals(productId))).get();
    return rows.length;
  }

  Future<bool> _applyRemotePaymentMethod(Map<String, dynamic> row) async {
    final id = row['id'] as String;
    final storeId = row['store_id'] as String;
    final name = row['name'] as String;
    final existing = await paymentMethodById(id);
    final serverUpdated = _ts(row['updated_at']);
    final serverDeleted = _ts(row['deleted_at']);

    // Tombstones reach their exact id only (see _applyRemoteProduct).
    if (serverDeleted != null && existing == null) return false;

    PaymentMethod? newerTwin;

    // A LIVE method whose NORMALISED name matches a different local id
    // (every install used to seed its own "Cash" and push it, which is how
    // the server ended up with six): merge by name, repoint this store's
    // orders onto the surviving id, delete the twin.
    if (serverDeleted == null) {
      final twins =
          await (select(paymentMethods)
                ..where((t) => t.storeId.equals(storeId))
                ..where((t) => t.deletedAt.isNull())
                ..where((t) => t.id.isNotIn([id])))
              .get();
      for (final twin in twins.where((t) => NameNorm.equal(t.name, name))) {
        if (!LastWriteWins.serverWins(
          localUpdatedAt: twin.updatedAt,
          serverUpdatedAt: serverUpdated,
        )) {
          // Same rule as categories: the server id wins, the newer content
          // follows it through the outbox instead of standing down.
          newerTwin = twin;
          await _retargetOutbox('payment_methods', twin.id, id);
        }
        await (update(orders)
              ..where((t) => t.storeId.equals(storeId))
              ..where((t) => t.paymentMethodId.equals(twin.id)))
            .write(OrdersCompanion(paymentMethodId: Value(id)));
        await (delete(paymentMethods)..where((t) => t.id.equals(twin.id))).go();
      }
    }

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
    if (newerTwin != null) {
      await (update(paymentMethods)..where((t) => t.id.equals(id))).write(
        PaymentMethodsCompanion(
          name: Value(newerTwin.name),
          type: Value(newerTwin.type),
          color: Value(newerTwin.color),
          qrImagePath: Value(newerTwin.qrImagePath),
          accountName: Value(newerTwin.accountName),
          accountNumber: Value(newerTwin.accountNumber),
          requireReference: Value(newerTwin.requireReference),
          isEnabled: Value(newerTwin.isEnabled),
          sortOrder: Value(newerTwin.sortOrder),
          updatedAt: Value(newerTwin.updatedAt),
        ),
      );
    }
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
        businessDate: Value(
          await _businessDateFromServer(
                row['business_date'] as String?,
                row['store_id'] as String,
              ) ??
              _clock(),
        ),
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
    required List<StockEvent> stock,
  }) => {
    VoidBundle.voidRow: {
      'id': voidRow.id,
      'order_id': voidRow.orderId,
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
    'stock_status': p.stockStatus,
    'source_ref': p.sourceRef,
    'notes': p.notes,
    'source_col1': p.sourceCol1,
    'created_at': p.createdAt.toUtc().toIso8601String(),
    'updated_at': now.toUtc().toIso8601String(),
  };

  Map<String, dynamic> _deviceJson(Device d) => {
    'id': d.id,
    'store_id': d.storeId,
    'device_name': d.deviceName,
    'device_code': d.deviceCode,
    'is_active': d.isActive,
    'persistent_storage': d.persistentStorage,
    'last_sync_at': d.lastSyncAt?.toUtc().toIso8601String(),
    'created_at': d.createdAt.toUtc().toIso8601String(),
    'updated_at': d.updatedAt.toUtc().toIso8601String(),
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

  Map<String, dynamic> _storeJson(Store s, DateTime now) => {
    'id': s.id,
    'name': s.name,
    'tagline': s.tagline,
    // Deliberately NO owner_id: the server keeps ownership as it is.
    'receipt_name': s.receiptName,
    'receipt_tin': s.receiptTin,
    'receipt_address': s.receiptAddress,
    'receipt_accreditation': s.receiptAccreditation,
    'receipt_footer': s.receiptFooter,
    'currency': s.currency,
    'updated_at': now.toUtc().toIso8601String(),
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
