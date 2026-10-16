import 'package:uuid/uuid.dart';

/// Pure, host-testable business logic. No Flutter/DB imports.

/// MONEY. The stored value stays a peso [double] (it round-trips to the
/// server's numeric(10,2) and every screen, export and import speaks pesos),
/// but no comparison, sum or difference is ever done in floating point: each
/// one converts to integer CENTAVOS first, which is what makes 0.1 + 0.2 equal
/// 0.3 and a 3 x 19.99 line total exactly 59.97.
class Money {
  Money._();

  /// Pesos -> integer centavos. The single rounding point in the app.
  static int cents(double pesos) => (pesos * 100).round();

  /// Integer centavos -> pesos.
  static double pesos(int cents) => cents / 100;

  /// Round a peso value to 2 decimals (compat wrapper for AppDatabase.r2).
  static double round(double value) => pesos(cents(value));

  /// Cent-exact equality — never `a == b` on money.
  static bool equal(double a, double b) => cents(a) == cents(b);

  static int compare(double a, double b) => cents(a).compareTo(cents(b));

  /// Cent-exact sum of any number of peso values.
  static double sum(Iterable<double> pesosValues) =>
      pesos(pesosValues.fold<int>(0, (acc, v) => acc + cents(v)));

  static double subtract(double a, double b) => pesos(cents(a) - cents(b));

  /// unit price x quantity, in cents (a line total can never drift).
  static double multiply(double unitPrice, int quantity) =>
      pesos(cents(unitPrice) * quantity);
}

/// Cashier math: change = received - due; sale completes only when received >= due.
class ChangeCalc {
  ChangeCalc._();

  static double compute({required double due, required double received}) =>
      Money.subtract(received, due);

  static bool canComplete({required double due, required double received}) =>
      Money.cents(received) >= Money.cents(due);
}

/// order_no = {device_code}-{YYMMDD}-{seq}, unique per store.
class OrderNo {
  OrderNo._();

  static String generate(
    String deviceCode,
    DateTime now,
    int seq, {
    int tzOffsetMinutes = BusinessDate.defaultTzOffsetMinutes,
  }) {
    final local = BusinessDate.local(now, tzOffsetMinutes: tzOffsetMinutes);
    final ymd =
        '${local.year % 100}'.padLeft(2, '0') +
        '${local.month}'.padLeft(2, '0') +
        '${local.day}'.padLeft(2, '0');
    return '$deviceCode-$ymd-${seq.toString().padLeft(3, '0')}';
  }

  /// YYMMDD day key for per-device daily sequences (STORE-LOCAL day).
  static String dayKey(
    DateTime now, {
    int tzOffsetMinutes = BusinessDate.defaultTzOffsetMinutes,
  }) {
    final local = BusinessDate.local(now, tzOffsetMinutes: tzOffsetMinutes);
    return '${local.year % 100}'.padLeft(2, '0') +
        '${local.month}'.padLeft(2, '0') +
        '${local.day}'.padLeft(2, '0');
  }
}

/// Business date is the STORE-LOCAL calendar day (UTC+8 in Manila, no DST).
/// Using the UTC day put every sale before 08:00 Manila on the previous date.
/// One helper so reports, End-of-Day and Close Day never disagree.
class BusinessDate {
  BusinessDate._();

  /// Asia/Manila is UTC+8 all year — the default when no setting exists.
  static const int defaultTzOffsetMinutes = 480;

  /// The store-local wall clock for an instant.
  static DateTime local(
    DateTime at, {
    int tzOffsetMinutes = defaultTzOffsetMinutes,
  }) => at.toUtc().add(Duration(minutes: tzOffsetMinutes));

  /// Local midnight, expressed as the canonical UTC instant to store.
  static DateTime startOfDayUtc(
    DateTime at, {
    int tzOffsetMinutes = defaultTzOffsetMinutes,
  }) {
    final l = local(at, tzOffsetMinutes: tzOffsetMinutes);
    return DateTime.utc(
      l.year,
      l.month,
      l.day,
    ).subtract(Duration(minutes: tzOffsetMinutes));
  }

  /// YYYY-MM-DD key of the store-local day.
  static String key(
    DateTime at, {
    int tzOffsetMinutes = defaultTzOffsetMinutes,
  }) {
    final l = local(at, tzOffsetMinutes: tzOffsetMinutes);
    return '${l.year.toString().padLeft(4, '0')}-'
        '${l.month.toString().padLeft(2, '0')}-'
        '${l.day.toString().padLeft(2, '0')}';
  }

  static bool sameDay(
    DateTime a,
    DateTime b, {
    int tzOffsetMinutes = defaultTzOffsetMinutes,
  }) =>
      key(a, tzOffsetMinutes: tzOffsetMinutes) ==
      key(b, tzOffsetMinutes: tzOffsetMinutes);
}

/// Deterministic outbox event id — dedupe key for idempotent push.
/// Same (entity, entityId, updatedAt) always yields the same UUID.
/// Both sides are normalised to UTC so a device clock in local time and a
/// server in UTC agree on the id.
class OutboxEventId {
  OutboxEventId._();

  static const _uuid = Uuid();
  static const _ns = '6ba7b810-9dad-11d1-80b4-00c04fd430c8'; // Namespace URL

  static String of(String entity, String entityId, DateTime updatedAt) =>
      _uuid.v5(_ns, '$entity:$entityId:${updatedAt.toUtc().toIso8601String()}');
}

/// Last-write-wins by updated_at. Server wins ties (device clock drift).
class LastWriteWins {
  LastWriteWins._();

  /// Returns true when the server version should overwrite the local one.
  /// Applied to EVERY mutable table (products used to be the only one).
  static bool serverWins({
    required DateTime? localUpdatedAt,
    required DateTime? serverUpdatedAt,
  }) {
    if (serverUpdatedAt == null) return false;
    if (localUpdatedAt == null) return true;
    return !serverUpdatedAt.isBefore(localUpdatedAt);
  }
}

/// Stock = sum of delta events. Never an absolute overwrite.
class StockDelta {
  StockDelta._();

  static int sum(Iterable<int> deltas) => deltas.fold(0, (a, b) => a + b);
}

/// Append-only rules for orders (F3).
class OrderRules {
  OrderRules._();

  /// Orders, order_items, payments and order_voids are immutable after insert.
  static bool isImmutable(String entity) =>
      entity == 'orders' ||
      entity == 'order_items' ||
      entity == 'payments' ||
      entity == 'order_voids';

  /// Voided is DERIVED: an order is voided iff an order_voids row exists.
  static bool isVoided({required bool hasVoidRow}) => hasVoidRow;

  /// A void may only be appended once per order.
  static bool canVoid({required bool hasVoidRow}) => !hasVoidRow;
}

/// Orders-list status chip. Voided comes from `order_voids`; the rest comes
/// from outbox state — never from a mutated order row.
enum OrderChip { voided, failed, pending, synced }

class OrderChips {
  OrderChips._();

  static OrderChip of({
    required bool hasVoid,
    required bool synced,
    required bool failed,
  }) {
    if (hasVoid) return OrderChip.voided;
    if (failed) return OrderChip.failed;
    if (!synced) return OrderChip.pending;
    return OrderChip.synced;
  }
}
