import 'package:drift/drift.dart';

// Drift tables mirroring docs/plan.md §3. Column names are snake_case.
// Every entity: id, store_id, device_id (where applicable), created_at,
// updated_at, deleted_at (soft delete), synced_at.
//
// Append-only rule (F1/F3): orders, order_items, payments, stock_events and
// order_voids are never UPDATEd or DELETEd. A void is an `order_voids` row
// plus reversal `stock_events`; `orders` is written once at insert and the
// voided state is DERIVED from `order_voids`.
//
// Timestamps are always UTC (see AppDatabase._clock).

class Stores extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get tagline => text()();
  TextColumn get ownerId => text().named('owner_id')();
  TextColumn get receiptName => text().named('receipt_name')();
  TextColumn get receiptTin => text().named('receipt_tin')();
  TextColumn get receiptAddress => text().named('receipt_address')();
  TextColumn get receiptAccreditation =>
      text().named('receipt_accreditation')();
  TextColumn get receiptFooter => text().named('receipt_footer')();
  TextColumn get currency => text()();
  DateTimeColumn get createdAt =>
      dateTime().named('created_at').withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt =>
      dateTime().named('updated_at').withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}

class Devices extends Table {
  TextColumn get id => text()();
  TextColumn get storeId => text().named('store_id')();
  TextColumn get deviceName => text().named('device_name')();
  TextColumn get deviceCode => text().named('device_code')();
  BoolColumn get isActive =>
      boolean().named('is_active').withDefault(const Constant(true))();
  DateTimeColumn get lastSyncAt =>
      dateTime().named('last_sync_at').nullable()();
  DateTimeColumn get createdAt =>
      dateTime().named('created_at').withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt =>
      dateTime().named('updated_at').withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<String> get customConstraints => ['UNIQUE (store_id, device_code)'];
}

class Categories extends Table {
  TextColumn get id => text()();
  TextColumn get storeId => text().named('store_id')();
  TextColumn get name => text()();
  IntColumn get sortOrder =>
      integer().named('sort_order').withDefault(const Constant(0))();
  BoolColumn get isActive =>
      boolean().named('is_active').withDefault(const Constant(true))();
  DateTimeColumn get createdAt =>
      dateTime().named('created_at').withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt =>
      dateTime().named('updated_at').withDefault(currentDateAndTime)();
  DateTimeColumn get deletedAt => dateTime().named('deleted_at').nullable()();
  DateTimeColumn get syncedAt => dateTime().named('synced_at').nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class Products extends Table {
  TextColumn get id => text()();
  TextColumn get storeId => text().named('store_id')();
  TextColumn get categoryId => text().named('category_id').nullable()();
  TextColumn get name => text()();
  RealColumn get price => real()();
  TextColumn get barcode => text().nullable()();
  TextColumn get imagePath => text().named('image_path').nullable()();
  IntColumn get stockQuantity =>
      integer().named('stock_quantity').withDefault(const Constant(0))();
  BoolColumn get isActive =>
      boolean().named('is_active').withDefault(const Constant(true))();
  DateTimeColumn get createdAt =>
      dateTime().named('created_at').withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().named('updated_at')();
  DateTimeColumn get deletedAt => dateTime().named('deleted_at').nullable()();
  DateTimeColumn get syncedAt => dateTime().named('synced_at').nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class PaymentMethods extends Table {
  TextColumn get id => text()();
  TextColumn get storeId => text().named('store_id')();
  TextColumn get name => text()();
  TextColumn get type => text()();
  TextColumn get color => text().withDefault(const Constant('#B70011'))();
  TextColumn get qrImagePath => text().named('qr_image_path').nullable()();
  TextColumn get accountName =>
      text().named('account_name').withDefault(const Constant(''))();
  TextColumn get accountNumber =>
      text().named('account_number').withDefault(const Constant(''))();
  BoolColumn get requireReference =>
      boolean().named('require_reference').withDefault(const Constant(false))();
  BoolColumn get isEnabled =>
      boolean().named('is_enabled').withDefault(const Constant(true))();
  IntColumn get sortOrder =>
      integer().named('sort_order').withDefault(const Constant(0))();
  DateTimeColumn get createdAt =>
      dateTime().named('created_at').withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().named('updated_at')();
  DateTimeColumn get deletedAt => dateTime().named('deleted_at').nullable()();
  DateTimeColumn get syncedAt => dateTime().named('synced_at').nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class Orders extends Table {
  TextColumn get id => text()();
  TextColumn get storeId => text().named('store_id')();
  TextColumn get deviceId => text().named('device_id')();
  TextColumn get orderNo => text().named('order_no')();
  RealColumn get subtotal => real().withDefault(const Constant(0))();
  RealColumn get discount => real().withDefault(const Constant(0))();
  RealColumn get total => real()();
  TextColumn get note => text().withDefault(const Constant(''))();
  TextColumn get paymentMethodId =>
      text().named('payment_method_id').nullable()();
  RealColumn get amountReceived => real().named('amount_received').nullable()();
  RealColumn get changeAmount => real().named('change_amount').nullable()();
  TextColumn get referenceNo =>
      text().named('reference_no').withDefault(const Constant(''))();
  TextColumn get status => text().withDefault(const Constant('completed'))();
  DateTimeColumn get createdAt =>
      dateTime().named('created_at').withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt =>
      dateTime().named('updated_at').withDefault(currentDateAndTime)();
  DateTimeColumn get syncedAt => dateTime().named('synced_at').nullable()();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<String> get customConstraints => ['UNIQUE (store_id, order_no)'];
}

class OrderItems extends Table {
  TextColumn get id => text()();
  TextColumn get orderId => text().named('order_id')();
  TextColumn get productId => text().named('product_id').nullable()();
  TextColumn get productName => text().named('product_name')();
  RealColumn get unitPrice => real().named('unit_price')();
  IntColumn get quantity => integer()();
  RealColumn get lineTotal => real().named('line_total')();
  DateTimeColumn get createdAt =>
      dateTime().named('created_at').withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}

/// Snapshot of how an order was paid. Written once per sale, inside the same
/// transaction as orders/order_items/stock_events/sync_outbox. The method
/// name and type are snapshotted so editing or deleting a PaymentMethod later
/// never changes a receipt that has already been issued.
class Payments extends Table {
  TextColumn get id => text()();
  TextColumn get storeId => text().named('store_id')();
  TextColumn get deviceId => text().named('device_id')();
  TextColumn get orderId => text().named('order_id')();
  TextColumn get methodId => text().named('method_id').nullable()();
  TextColumn get methodName =>
      text().named('method_name').withDefault(const Constant(''))();
  TextColumn get methodType =>
      text().named('method_type').withDefault(const Constant(''))();
  RealColumn get amount => real()();
  RealColumn get amountReceived => real().named('amount_received').nullable()();
  RealColumn get changeAmount => real().named('change_amount').nullable()();
  TextColumn get referenceNo =>
      text().named('reference_no').withDefault(const Constant(''))();
  DateTimeColumn get createdAt =>
      dateTime().named('created_at').withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};

  // One payment per order -> idempotent replay dedupes on order_id too.
  @override
  List<String> get customConstraints => ['UNIQUE (order_id)'];
}

class OrderVoids extends Table {
  TextColumn get id => text()();
  TextColumn get orderId => text().named('order_id')();
  TextColumn get deviceId => text().named('device_id')();
  TextColumn get reason => text()();
  DateTimeColumn get voidedAt => dateTime().named('voided_at')();
  DateTimeColumn get createdAt =>
      dateTime().named('created_at').withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};

  // A second void must not create a second row (F3).
  @override
  List<String> get customConstraints => ['UNIQUE (order_id)'];
}

class StockEvents extends Table {
  TextColumn get id => text()();
  TextColumn get storeId => text().named('store_id')();
  TextColumn get productId => text().named('product_id')();
  IntColumn get delta => integer()();
  TextColumn get reason => text()();
  TextColumn get orderId => text().named('order_id').nullable()();
  TextColumn get deviceId => text().named('device_id').nullable()();
  DateTimeColumn get createdAt =>
      dateTime().named('created_at').withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}

/// Close Day record. Replaces `shifts` (which nothing used — see plan.md §3.11).
/// Unique per (business_date, device_id): closing the same day twice updates
/// the existing row (last-write-wins) instead of appending a duplicate.
class DayCloses extends Table {
  TextColumn get id => text()();
  TextColumn get storeId => text().named('store_id')();
  TextColumn get deviceId => text().named('device_id')();
  DateTimeColumn get businessDate => dateTime().named('business_date')();
  RealColumn get cashExpected => real().named('cash_expected').nullable()();
  RealColumn get cashActual => real().named('cash_actual').nullable()();
  RealColumn get variance => real().nullable()();
  TextColumn get closedBy => text().named('closed_by').nullable()();
  DateTimeColumn get createdAt =>
      dateTime().named('created_at').withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt =>
      dateTime().named('updated_at').withDefault(currentDateAndTime)();
  DateTimeColumn get syncedAt => dateTime().named('synced_at').nullable()();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<String> get customConstraints => ['UNIQUE (business_date, device_id)'];
}

class SyncOutbox extends Table {
  TextColumn get id => text()();
  TextColumn get storeId => text().named('store_id')();
  TextColumn get deviceId => text().named('device_id')();
  TextColumn get entity => text()();
  TextColumn get entityId => text().named('entity_id')();
  TextColumn get op => text()();
  TextColumn get payload => text()();
  IntColumn get attempts => integer().withDefault(const Constant(0))();

  /// When this row may be retried (B5). Null = now. Backoff 1s..60s, so a
  /// flapping connection never burns the 8 attempts in a few seconds.
  DateTimeColumn get nextAttemptAt =>
      dateTime().named('next_attempt_at').nullable()();

  TextColumn get lastError => text().named('last_error').nullable()();
  DateTimeColumn get createdAt =>
      dateTime().named('created_at').withDefault(currentDateAndTime)();
  DateTimeColumn get syncedAt => dateTime().named('synced_at').nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// W3 — LOCAL-ONLY image cache. This table has no counterpart in Supabase and
/// is NEVER synced.
///
/// A signed URL expires in minutes and a cross-origin `<img>` response is not
/// reliably served from WebKit's HTTP cache while offline, so the product and
/// payment-QR images are stored here as bytes and rendered from here. The
/// column is `path` (the pos-assets object path), which is also the primary
/// key: re-fetching an image overwrites its one row.
class ImageCaches extends Table {
  TextColumn get path => text()();
  BlobColumn get bytes => blob()();
  TextColumn get contentType => text().named('content_type')();
  DateTimeColumn get fetchedAt => dateTime().named('fetched_at')();

  @override
  Set<Column> get primaryKey => {path};
}

class Settings extends Table {
  TextColumn get storeId => text().named('store_id')();
  TextColumn get key => text()();
  TextColumn get value => text()();
  DateTimeColumn get updatedAt =>
      dateTime().named('updated_at').withDefault(currentDateAndTime)();
  DateTimeColumn get syncedAt => dateTime().named('synced_at').nullable()();

  @override
  Set<Column> get primaryKey => {storeId, key};
}
