import 'dart:convert';

/// Outbox bundle shapes (F2).
///
/// A sale reaches the server as ONE outbox row whose payload carries the
/// whole transaction: order + items + payment + stock_events. The server
/// inserts every append-only table with `ON CONFLICT (id) DO NOTHING`, so
/// replaying the same bundle leaves exactly one order, N items, one payment
/// and N stock events.
class SaleBundle {
  SaleBundle._();

  static const entity = 'sale';
  static const order = 'order';
  static const items = 'items';
  static const payment = 'payment';
  static const stockEvents = 'stock_events';

  /// Parse an outbox payload back into a bundle (throws on malformed input).
  static Map<String, dynamic> decode(String payload) =>
      jsonDecode(payload) as Map<String, dynamic>;

  /// The append-only tables a sale bundle touches, in dependency order.
  static const tables = ['orders', 'order_items', 'payments', 'stock_events'];
}

/// A void reaches the server as its own bundle: the order_voids row plus the
/// reversal stock_events. The order row is never part of it.
class VoidBundle {
  VoidBundle._();
  static const entity = 'void';
  static const voidRow = 'void';
  static const stockEvents = 'stock_events';
}

/// B6: a bundle is pushed one row at a time, PARENTS FIRST.
///
/// `order_items`, `payments` and `stock_events` reference `orders`, and RLS on
/// order_items/order_voids walks up to the parent order, so inserting an item
/// before its order is rejected. Pushing in this order also means a failure
/// halfway leaves a valid prefix on the server and the retry replays the whole
/// bundle (every write is insert-if-absent), which is what makes the push
/// idempotent: 1 order, N items, 1 payment, N stock events.
class SalePush {
  SalePush._();

  static const List<String> tables = [
    'orders',
    'order_items',
    'payments',
    'stock_events',
  ];

  /// (table, row) pairs in dependency order.
  static List<({String table, Map<String, dynamic> row})> rows(
    Map<String, dynamic> payload,
  ) {
    final out = <({String table, Map<String, dynamic> row})>[];
    final order = payload[SaleBundle.order];
    if (order is Map<String, dynamic>) out.add((table: 'orders', row: order));
    for (final r in _list(payload[SaleBundle.items])) {
      out.add((table: 'order_items', row: r));
    }
    final payment = payload[SaleBundle.payment];
    if (payment is Map<String, dynamic>) {
      out.add((table: 'payments', row: payment));
    }
    for (final r in _list(payload[SaleBundle.stockEvents])) {
      out.add((table: 'stock_events', row: r));
    }
    return out;
  }

  static List<Map<String, dynamic>> _list(Object? raw) =>
      raw is List ? raw.whereType<Map<String, dynamic>>().toList() : const [];
}

/// The void bundle in dependency order: the order_voids row first (its RLS
/// check needs the order), then the reversal stock events.
class VoidPush {
  VoidPush._();

  static const List<String> tables = ['order_voids', 'stock_events'];

  static List<({String table, Map<String, dynamic> row})> rows(
    Map<String, dynamic> payload,
  ) {
    final out = <({String table, Map<String, dynamic> row})>[];
    final voidRow = payload[VoidBundle.voidRow];
    if (voidRow is Map<String, dynamic>) {
      out.add((table: 'order_voids', row: voidRow));
    }
    for (final r in SalePush._list(payload[VoidBundle.stockEvents])) {
      out.add((table: 'stock_events', row: r));
    }
    return out;
  }
}

/// In-memory stand-in for the server's append-only tables. `_put` reproduces
/// `ON CONFLICT (id) DO NOTHING`, which is exactly what makes a replayed
/// bundle a no-op. Used by tests to prove idempotency without a live server.
class BundleServer {
  final Map<String, Map<String, dynamic>> orders = {};
  final Map<String, Map<String, dynamic>> items = {};
  final Map<String, Map<String, dynamic>> payments = {};
  final Map<String, Map<String, dynamic>> stockEvents = {};
  final Map<String, Map<String, dynamic>> voids = {};

  final List<Map<String, dynamic>> _ledger = [];
  List<Map<String, dynamic>> get ledger => List.unmodifiable(_ledger);

  /// One row into one table with `ON CONFLICT (id) DO NOTHING`: false when it
  /// was already there. [table] is the SERVER table name, so a test can drive
  /// the same per-row writer the Api uses.
  bool put(String table, Map<String, dynamic> row) {
    final id = row['id'] as String;
    final target = switch (table) {
      'orders' => orders,
      'order_items' => items,
      'payments' => payments,
      'stock_events' => stockEvents,
      'order_voids' => voids,
      _ => throw ArgumentError('unknown table $table'),
    };
    if (target.containsKey(id)) return false; // ON CONFLICT DO NOTHING
    target[id] = {...row, '_table': table};
    _ledger.add({'table': table, 'id': id});
    return true;
  }

  /// Apply one outbox payload. Returns the number of rows actually inserted
  /// (0 on a replayed bundle).
  int apply(Map<String, dynamic> payload) {
    var written = 0;
    for (final r in SalePush.rows(payload)) {
      if (put(r.table, r.row)) written++;
    }
    for (final r in VoidPush.rows(payload)) {
      if (put(r.table, r.row)) written++;
    }
    return written;
  }

  int get totalRows =>
      orders.length +
      items.length +
      payments.length +
      stockEvents.length +
      voids.length;
}
