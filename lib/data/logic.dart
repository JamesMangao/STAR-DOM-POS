import 'package:uuid/uuid.dart';

/// Pure, host-testable business logic. No Flutter/DB imports.

/// Cashier math: change = received - due; sale completes only when received >= due.
class ChangeCalc {
  ChangeCalc._();

  static double compute({required double due, required double received}) =>
      (received * 100 - due * 100) / 100;

  static bool canComplete({required double due, required double received}) =>
      received >= due - 0.001;
}

/// order_no = {device_code}-{YYMMDD}-{seq}, unique per store.
class OrderNo {
  OrderNo._();

  static String generate(String deviceCode, DateTime now, int seq) {
    final utc = now.toUtc();
    final ymd =
        '${utc.year % 100}'.padLeft(2, '0') +
        '${utc.month}'.padLeft(2, '0') +
        '${utc.day}'.padLeft(2, '0');
    return '$deviceCode-$ymd-${seq.toString().padLeft(3, '0')}';
  }

  /// YYMMDD day key for per-device daily sequences (UTC day).
  static String dayKey(DateTime now) {
    final utc = now.toUtc();
    return '${utc.year % 100}'.padLeft(2, '0') +
        '${utc.month}'.padLeft(2, '0') +
        '${utc.day}'.padLeft(2, '0');
  }
}

/// Business date is always the UTC calendar day. One helper so reports,
/// End-of-Day and Close Day never disagree about which day a sale belongs to.
class BusinessDate {
  BusinessDate._();

  /// UTC midnight for [at] — the canonical stored value.
  static DateTime startOfDayUtc(DateTime at) {
    final utc = at.toUtc();
    return DateTime.utc(utc.year, utc.month, utc.day);
  }

  /// YYYY-MM-DD key (UTC).
  static String key(DateTime at) {
    final utc = at.toUtc();
    return '${utc.year.toString().padLeft(4, '0')}-'
        '${utc.month.toString().padLeft(2, '0')}-'
        '${utc.day.toString().padLeft(2, '0')}';
  }

  static bool sameDay(DateTime a, DateTime b) => key(a) == key(b);
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
