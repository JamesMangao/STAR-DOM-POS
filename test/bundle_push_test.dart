import 'package:flutter_test/flutter_test.dart';

import 'package:stardom_pos/data/bundle.dart';

/// A sale with two lines and one payment — the shape the outbox stores.
Map<String, dynamic> sale() => {
  SaleBundle.order: {
    'id': 'order-1',
    'store_id': 'store-1',
    'device_id': 'device-1',
    'order_no': 'A0-261016-001',
    'total': 59.97,
  },
  SaleBundle.items: [
    {'id': 'item-1', 'order_id': 'order-1', 'quantity': 3, 'line_total': 59.97},
    {'id': 'item-2', 'order_id': 'order-1', 'quantity': 1, 'line_total': 0.0},
  ],
  SaleBundle.payment: {'id': 'pay-1', 'order_id': 'order-1', 'amount': 59.97},
  SaleBundle.stockEvents: [
    {'id': 'ev-1', 'product_id': 'p-1', 'delta': -3, 'reason': 'sale'},
    {'id': 'ev-2', 'product_id': 'p-2', 'delta': -1, 'reason': 'sale'},
  ],
};

void main() {
  group('Push order (B6)', () {
    test('a sale is pushed parents-first, stock_events last', () {
      expect(SalePush.rows(sale()).map((r) => r.table).toList(), [
        'orders',
        'order_items',
        'order_items',
        'payments',
        'stock_events',
        'stock_events',
      ]);
    });

    test('a void pushes the void row before its reversal stock events', () {
      final payload = {
        VoidBundle.voidRow: {
          'id': 'void-1',
          'order_id': 'order-1',
          'device_id': 'device-1',
        },
        VoidBundle.stockEvents: [
          {'id': 'ev-3', 'product_id': 'p-1', 'delta': 3, 'reason': 'void'},
        ],
      };
      expect(VoidPush.rows(payload).map((r) => r.table).toList(), [
        'order_voids',
        'stock_events',
      ]);
    });
  });

  group('Push is idempotent (B6)', () {
    test('a push that dies at step 3 leaves a valid prefix, and the replay '
        'still yields 1 order, 2 items, 1 payment, 2 stock events', () async {
      final server = BundleServer();
      final seen = <String>[];
      var calls = 0;

      Future<void> push() async {
        for (final r in SalePush.rows(sale())) {
          calls++;
          if (calls == 3) throw StateError('connection dropped');
          seen.add(r.table);
          server.put(r.table, r.row);
        }
      }

      await expectLater(push(), throwsStateError);
      // The prefix the server accepted: the parent order and one item.
      expect(seen, ['orders', 'order_items']);
      expect(server.orders, hasLength(1));
      expect(server.items, hasLength(1));
      expect(server.payments, isEmpty);

      // The retry replays the WHOLE bundle.
      await push();

      expect(server.orders, hasLength(1));
      expect(server.items, hasLength(2));
      expect(server.payments, hasLength(1));
      expect(server.stockEvents, hasLength(2));
      expect(server.totalRows, 6);

      // …and a third replay is a no-op: that is what stops a bell from
      // duplicating sales.
      await push();
      expect(server.totalRows, 6);
    });

    test('an item is never sent before its order', () {
      final tables = SalePush.rows(sale()).map((r) => r.table).toList();
      final orderAt = tables.indexOf('orders');
      for (final child in ['order_items', 'payments', 'stock_events']) {
        expect(
          tables.indexOf(child),
          greaterThan(orderAt),
          reason: '$child references orders and RLS walks up to it',
        );
      }
    });
  });
}
