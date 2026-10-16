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

  bool _put(Map<String, Map<String, dynamic>> table, Map<String, dynamic> row) {
    final id = row['id'] as String;
    if (table.containsKey(id)) return false; // ON CONFLICT DO NOTHING
    table[id] = row;
    _ledger.add({'table': row['_table'], 'id': id});
    return true;
  }

  /// Apply one outbox payload. Returns the number of rows actually inserted
  /// (0 on a replayed bundle).
  int apply(Map<String, dynamic> payload) {
    var written = 0;

    final order = payload[SaleBundle.order];
    if (order is Map<String, dynamic>) {
      if (_put(orders, {...order, '_table': 'orders'})) written++;
    }
    final payment = payload[SaleBundle.payment];
    if (payment is Map<String, dynamic>) {
      if (_put(payments, {...payment, '_table': 'payments'})) written++;
    }
    final items = payload[SaleBundle.items];
    if (items is List) {
      for (final r in items.cast<Map<String, dynamic>>()) {
        if (_put(this.items, {...r, '_table': 'order_items'})) written++;
      }
    }
    final stock = payload[SaleBundle.stockEvents];
    if (stock is List) {
      for (final r in stock.cast<Map<String, dynamic>>()) {
        if (_put(stockEvents, {...r, '_table': 'stock_events'})) written++;
      }
    }
    final voidRow = payload[VoidBundle.voidRow];
    if (voidRow is Map<String, dynamic>) {
      if (_put(voids, {...voidRow, '_table': 'order_voids'})) written++;
    }
    return written;
  }
}
