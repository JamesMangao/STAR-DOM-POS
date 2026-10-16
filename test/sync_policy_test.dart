import 'package:flutter_test/flutter_test.dart';

import 'package:stardom_pos/data/logic.dart';
import 'package:stardom_pos/data/sync_policy.dart';

void main() {
  group('Money (B10: comparisons and sums in integer centavos)', () {
    test('0.1 + 0.2 is exactly 0.3 in cents', () {
      expect(Money.sum([0.1, 0.2]), 0.3);
      expect(Money.equal(0.1 + 0.2, 0.3), isTrue);
      expect(Money.cents(0.1 + 0.2), 30);
    });

    test('3 x 19.99 is exactly 59.97', () {
      expect(Money.multiply(19.99, 3), 59.97);
      expect(Money.cents(Money.multiply(19.99, 3)), 5997);
    });

    test('a hundred 0.01 lines sum to exactly 1.00', () {
      expect(Money.sum(List.filled(100, 0.01)), 1.0);
    });

    test('change is cent-exact', () {
      expect(ChangeCalc.compute(due: 100.00, received: 105.50), 5.5);
      expect(ChangeCalc.compute(due: 100.00, received: 50.00), -50.0);
      expect(ChangeCalc.compute(due: 100.00, received: 100.00), 0.0);
      expect(ChangeCalc.canComplete(due: 100.00, received: 99.99), isFalse);
      expect(ChangeCalc.canComplete(due: 100.00, received: 100.00), isTrue);
    });
  });

  group('BusinessDate is the STORE-LOCAL day (B8)', () {
    test('17:00Z on the 15th is the 16th in Manila (UTC+8)', () {
      final at = DateTime.parse('2026-10-15T17:00:00Z');
      expect(BusinessDate.key(at), '2026-10-16');
      expect(BusinessDate.key(at, tzOffsetMinutes: 0), '2026-10-15');
    });

    test('a 07:00 Manila sale belongs to that local day, not the UTC one', () {
      // 23:30Z on the 15th is 07:30 on the 16th in Manila.
      final at = DateTime.parse('2026-10-15T23:30:00Z');
      expect(BusinessDate.key(at), '2026-10-16');
      expect(
        BusinessDate.sameDay(at, DateTime.parse('2026-10-16T02:00:00Z')),
        isTrue,
      );
    });

    test('local midnight is stored as the matching UTC instant', () {
      final at = DateTime.parse('2026-10-15T17:00:00Z'); // 01:00 16th Manila
      final start = BusinessDate.startOfDayUtc(at);
      expect(start.toIso8601String(), '2026-10-15T16:00:00.000Z');
      expect(BusinessDate.key(start), '2026-10-16');
    });

    test('order_no day key uses the local day, and generate agrees', () {
      final at = DateTime.parse('2026-10-15T17:00:00Z');
      expect(OrderNo.dayKey(at), '261016');
      expect(OrderNo.generate('A1', at, 1), 'A1-261016-001');
      expect(OrderNo.dayKey(at, tzOffsetMinutes: 0), '261015');
    });

    test('a configurable offset is honoured', () {
      final at = DateTime.parse('2026-10-15T17:00:00Z');
      expect(BusinessDate.key(at, tzOffsetMinutes: 0), '2026-10-15');
      expect(BusinessDate.key(at, tzOffsetMinutes: -300), '2026-10-15');
      expect(BusinessDate.key(at, tzOffsetMinutes: 900), '2026-10-16');
    });
  });

  group('PushPolicy (B5)', () {
    test('backoff doubles from 1s and caps at 60s', () {
      expect(PushPolicy.backoff(1), const Duration(seconds: 1));
      expect(PushPolicy.backoff(2), const Duration(seconds: 2));
      expect(PushPolicy.backoff(3), const Duration(seconds: 4));
      expect(PushPolicy.backoff(4), const Duration(seconds: 8));
      expect(PushPolicy.backoff(5), const Duration(seconds: 16));
      expect(PushPolicy.backoff(6), const Duration(seconds: 32));
      expect(PushPolicy.backoff(7), const Duration(seconds: 60));
      expect(PushPolicy.backoff(8), const Duration(seconds: 60));
    });

    test(
      'classification: 409 duplicate, 401 auth, timeout offline, 5xx failed',
      () {
        expect(PushPolicy.classify(status: 201), PushResult.ok);
        expect(PushPolicy.classify(status: 409), PushResult.duplicate);
        expect(PushPolicy.classify(status: 401), PushResult.authExpired);
        expect(PushPolicy.classify(), PushResult.offline);
        expect(PushPolicy.classify(networkError: true), PushResult.offline);
        expect(PushPolicy.classify(status: 500), PushResult.failed);
        expect(PushPolicy.classify(status: 400), PushResult.failed);
        expect(PushPolicy.classify(status: 422), PushResult.failed);
      },
    );

    test('100 offline flush ticks park nothing: all sales stay pending', () {
      var state = const OutboxState();
      final t0 = DateTime.utc(2026, 10, 16, 2);
      for (var tick = 0; tick < 100; tick++) {
        final now = t0.add(Duration(seconds: tick * 10));
        if (PushPolicy.shouldAttempt(state, now)) {
          state = PushPolicy.after(PushResult.offline, state, now);
        }
      }
      expect(state.attempts, 0, reason: 'offline is not a failure');
      expect(state.parked, isFalse);
    });

    test('a duplicate counts as success', () {
      final now = DateTime.utc(2026, 10, 16);
      final s = PushPolicy.after(
        PushResult.duplicate,
        const OutboxState(),
        now,
      );
      expect(s.synced, isTrue);
      expect(s.attempts, 0);
    });

    test('real failures back off, then park at 8 attempts', () {
      var s = const OutboxState();
      final now = DateTime.utc(2026, 10, 16);
      for (var i = 1; i <= PushPolicy.maxAttempts; i++) {
        s = PushPolicy.after(PushResult.failed, s, now);
        expect(s.attempts, i);
        expect(s.nextAttemptAt, now.add(PushPolicy.backoff(i)));
        expect(PushPolicy.shouldAttempt(s, now), isFalse, reason: 'must wait');
        if (i < PushPolicy.maxAttempts) {
          expect(
            PushPolicy.shouldAttempt(s, now.add(PushPolicy.backoff(i))),
            isTrue,
            reason: 'ready once the backoff elapses',
          );
        }
      }
      expect(s.parked, isTrue);
      expect(
        PushPolicy.shouldAttempt(s, now.add(const Duration(days: 1))),
        isFalse,
      );
    });

    test('auth expiry does not burn an attempt', () {
      final now = DateTime.utc(2026, 10, 16);
      final s = PushPolicy.after(
        PushResult.authExpired,
        const OutboxState(),
        now,
      );
      expect(s.attempts, 0);
      expect(s.synced, isFalse);
    });
  });

  group('PushOrder (B6)', () {
    test('orders before items/payments, stock_events last', () {
      expect(
        PushOrder.indexOf('orders'),
        lessThan(PushOrder.indexOf('order_items')),
      );
      expect(
        PushOrder.indexOf('orders'),
        lessThan(PushOrder.indexOf('payments')),
      );
      expect(
        PushOrder.indexOf('order_items'),
        lessThan(PushOrder.indexOf('stock_events')),
      );
      expect(
        PushOrder.indexOf('payments'),
        lessThan(PushOrder.indexOf('stock_events')),
      );
      expect(PushOrder.indexOf('unknown'), PushOrder.tables.length);
    });
  });

  group('PullPlan + PullCursor (B3, B4)', () {
    test('every table a fresh device needs is pulled, parents first', () {
      for (final t in [
        'stores',
        'categories',
        'products',
        'payment_methods',
        'settings',
        'devices',
        'orders',
        'order_items',
        'payments',
        'stock_events',
        'order_voids',
        'day_closes',
      ]) {
        expect(PullPlan.tables, contains(t), reason: '$t must be pulled');
      }
      expect(
        PullPlan.tables.indexOf('stores'),
        lessThan(PullPlan.tables.indexOf('categories')),
      );
      expect(
        PullPlan.tables.indexOf('products'),
        lessThan(PullPlan.tables.indexOf('order_items')),
      );
      expect(
        PullPlan.tables.indexOf('orders'),
        lessThan(PullPlan.tables.indexOf('order_items')),
      );
      expect(
        PullPlan.tables.indexOf('orders'),
        lessThan(PullPlan.tables.indexOf('payments')),
      );
      expect(PullPlan.pageSize, 500);
    });

    test('cursor column is server_updated_at, or server_created_at when append-only', () {
      expect(PullPlan.cursorColumn('products'), 'server_updated_at');
      expect(PullPlan.cursorColumn('settings'), 'server_updated_at');
      expect(PullPlan.cursorColumn('orders'), 'server_created_at');
      expect(PullPlan.cursorColumn('stock_events'), 'server_created_at');
      expect(PullPlan.cursorColumn('order_voids'), 'server_created_at');
      expect(PullPlan.cursorKey('products'), 'pull_cursor:products');
    });

    test('advance keeps the newest server timestamp and its pk', () {
      const cursor = PullCursor();
      final next = cursor.advance([
        {'id': 'a', 'server_updated_at': '2026-10-16T01:00:00Z'},
        {'id': 'b', 'server_updated_at': '2026-10-16T03:00:00Z'},
        {'id': 'c', 'server_updated_at': '2026-10-16T02:00:00Z'},
      ], 'server_updated_at');
      expect(next.cursorValue!.toIso8601String(), '2026-10-16T03:00:00.000Z');
      expect(next.lastPk, 'b');
      expect(next.describe(), '2026-10-16T03:00:00.000Z|b');
      expect(PullCursor.parse(next.describe()).cursorValue, next.cursorValue);
    });

    test('paging with a +/-10 min clock skew loses nothing and duplicates nothing', () {
      // The server wrote 10 rows; the device clock is irrelevant to the cursor.
      final rows = [
        for (var i = 0; i < 10; i++)
          {
            'id': 'p$i',
            'server_updated_at': DateTime.utc(
              2026,
              10,
              16,
              0,
              i,
            ).toIso8601String(),
          },
      ];
      const page = 3;
      var cursor = const PullCursor();
      final seen = <String>[];
      for (var guard = 0; guard < 20; guard++) {
        // What Api.pullPage returns: `>=` on the cursor value, take(page).
        final fetched = rows
            .where(
              (r) =>
                  cursor.cursorValue == null ||
                  !DateTime.parse(r['server_updated_at'] as String)
                      .isBefore(cursor.cursorValue!),
            )
            .take(page)
            .toList();
        // What the engine applies: everything strictly after the cursor.
        final remaining = PullPage.after(fetched, cursor, 'server_updated_at');
        if (remaining.isEmpty) break;
        seen.addAll(remaining.map((r) => r['id'] as String));
        cursor = cursor.advance(fetched, 'server_updated_at');
      }
      expect(seen.length, 10);
      expect(seen.toSet().length, 10, reason: 'no duplicates');
      expect(seen, containsAll(['p0', 'p9']));
    });

    test('a device clock 10 minutes ahead never advances the cursor', () {
      // The row carries the client clock too; only the SERVER column counts.
      final fetched = [
        {
          'id': 'a',
          'updated_at': '2026-10-16T00:10:00Z',
          'server_updated_at': '2026-10-16T00:00:00Z',
        },
      ];
      final next = PullPage.after(
        fetched,
        const PullCursor(),
        'server_updated_at',
      );
      expect(next, hasLength(1));
      expect(
        const PullCursor()
            .advance(fetched, 'server_updated_at')
            .cursorValue!
            .toIso8601String(),
        '2026-10-16T00:00:00.000Z',
      );
      // A row the server wrote at exactly the cursor is re-served once, then
      // dropped by the pk tie-break instead of looping forever.
      final cursor = PullCursor(
        cursorValue: DateTime.utc(2026, 10, 16),
        lastPk: 'a',
      );
      expect(PullPage.after(fetched, cursor, 'server_updated_at'), isEmpty);
    });
  });
}
