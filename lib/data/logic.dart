import 'package:uuid/uuid.dart';

/// Pure, host-testable business logic. No Flutter/DB imports.

/// Cashier math: change = received - due; sale completes only when received >= due.
class ChangeCalc {
  ChangeCalc._();

  static double compute({required double due, required received}) =>
      (received * 100 - due * 100) / 100;

  static bool canComplete({required double due, required received}) =>
      received >= due - 0.001;
}

/// order_no = {device_code}-{YYMMDD}-{seq}, unique per store.
class OrderNo {
  OrderNo._();

  static String generate(String deviceCode, DateTime now, int seq) {
    final ymd = '${now.year % 100}'.padLeft(2, '0') +
        '${now.month}'.padLeft(2, '0') +
        '${now.day}'.padLeft(2, '0');
    return '$deviceCode-$ymd-${seq.toString().padLeft(3, '0')}';
  }

  /// YYMMDD day key for per-device daily sequences.
  static String dayKey(DateTime now) =>
      '${now.year % 100}'.padLeft(2, '0') +
      '${now.month}'.padLeft(2, '0') +
      '${now.day}'.padLeft(2, '0');
}

/// Deterministic outbox event id — dedupe key for idempotent push.
/// Same (entity, entityId, updatedAt) always yields the same UUID.
class OutboxEventId {
  OutboxEventId._();

  static const _uuid = Uuid();

  static String of(String entity, String entityId, DateTime updatedAt) =>
      _uuid.v5(Namespace.url, '$entity:$entityId:${updatedAt.toIso8601String()}');
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

/// Append-only rules for orders.
class OrderRules {
  OrderRules._();

  /// Voiding an order never edits/deletes it — it appends an order_voids event.
  static bool isVoidable(String status) => status == 'completed';

  /// Orders/order_items are immutable after insert.
  static bool isImmutable(String entity) =>
      entity == 'orders' || entity == 'order_items';
}
