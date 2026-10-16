import 'package:flutter_test/flutter_test.dart';

import 'package:stardom_pos/data/logic.dart';

void main() {
  group('ChangeCalc', () {
    test('received < due returns negative change', () {
      expect(ChangeCalc.compute(due: 100.0, received: 80.0), -20.0);
      expect(ChangeCalc.canComplete(due: 100.0, received: 80.0), false);
    });

    test('received == due returns zero change', () {
      expect(ChangeCalc.compute(due: 100.0, received: 100.0), 0.0);
      expect(ChangeCalc.canComplete(due: 100.0, received: 100.0), true);
    });

    test('received > due returns positive change', () {
      expect(ChangeCalc.compute(due: 100.0, received: 120.0), 20.0);
      expect(ChangeCalc.canComplete(due: 100.0, received: 120.0), true);
    });
  });

  group('OrderNo', () {
    test('sequence per device/day resets next day', () {
      expect(OrderNo.generate('A1', DateTime.utc(2026, 1, 15), 1), 'A1-260115-001');
      expect(OrderNo.generate('A1', DateTime.utc(2026, 1, 15), 5), 'A1-260115-005');
      expect(OrderNo.generate('A1', DateTime.utc(2026, 1, 16), 1), 'A1-260116-001');
    });

    test('dayKey returns YYMMDD format (UTC)', () {
      expect(OrderNo.dayKey(DateTime.utc(2026, 1, 15)), '260115');
      expect(OrderNo.dayKey(DateTime.utc(2026, 12, 31)), '261231');
    });

    test('dayKey normalises a local timestamp to UTC', () {
      // 2026-01-16 02:00 +08:00 == 2026-01-15 18:00 UTC.
      final local = DateTime.utc(2026, 1, 15, 18).toLocal();
      expect(OrderNo.dayKey(local), '260115');
    });
  });

  group('BusinessDate', () {
    test('startOfDayUtc zeroes the clock in UTC', () {
      expect(
        BusinessDate.startOfDayUtc(DateTime.utc(2026, 1, 15, 23, 59)),
        DateTime.utc(2026, 1, 15),
      );
    });

    test('key renders YYYY-MM-DD and sameDay compares UTC days', () {
      expect(BusinessDate.key(DateTime.utc(2026, 1, 15, 1)), '2026-01-15');
      expect(
        BusinessDate.sameDay(
          DateTime.utc(2026, 1, 15, 0, 1),
          DateTime.utc(2026, 1, 15, 23, 59),
        ),
        true,
      );
      expect(
        BusinessDate.sameDay(
          DateTime.utc(2026, 1, 15, 23, 59),
          DateTime.utc(2026, 1, 16, 0, 1),
        ),
        false,
      );
    });
  });

  group('OutboxEventId', () {
    test('v5 determinism: same input twice yields same UUID', () {
      final now = DateTime.utc(2026, 1, 15, 10, 30, 0);
      expect(
        OutboxEventId.of('products', 'prod-123', now),
        OutboxEventId.of('products', 'prod-123', now),
      );
    });

    test('v5 determinism: different input yields different UUID', () {
      final now = DateTime.utc(2026, 1, 15, 10, 30, 0);
      expect(
        OutboxEventId.of('products', 'prod-123', now),
        isNot(OutboxEventId.of('products', 'prod-456', now)),
      );
    });

    test('same instant in local vs UTC yields the same UUID', () {
      final utc = DateTime.utc(2026, 1, 15, 10, 30, 0);
      final local = utc.toLocal();
      expect(
        OutboxEventId.of('orders', 'o-1', utc),
        OutboxEventId.of('orders', 'o-1', local),
      );
    });
  });

  group('LastWriteWins', () {
    test('server wins when local is null', () {
      expect(
        LastWriteWins.serverWins(
          localUpdatedAt: null,
          serverUpdatedAt: DateTime.utc(2026, 1, 1),
        ),
        true,
      );
    });

    test('server wins when updated_at is newer', () {
      expect(
        LastWriteWins.serverWins(
          localUpdatedAt: DateTime.utc(2026, 1, 15),
          serverUpdatedAt: DateTime.utc(2026, 1, 16),
        ),
        true,
      );
    });

    test('server wins ties (device clock drift)', () {
      final now = DateTime.utc(2026, 1, 15, 10, 30, 0);
      expect(
        LastWriteWins.serverWins(localUpdatedAt: now, serverUpdatedAt: now),
        true,
      );
    });

    test('local wins when newer', () {
      expect(
        LastWriteWins.serverWins(
          localUpdatedAt: DateTime.utc(2026, 1, 16),
          serverUpdatedAt: DateTime.utc(2026, 1, 15),
        ),
        false,
      );
    });

    test('server null returns false', () {
      expect(
        LastWriteWins.serverWins(
          localUpdatedAt: DateTime.utc(2026, 1, 1),
          serverUpdatedAt: null,
        ),
        false,
      );
    });
  });

  group('StockDelta', () {
    test('sum of deltas', () {
      expect(StockDelta.sum([10, -3, 5, -2]), 10);
      expect(StockDelta.sum(const []), 0);
    });
  });

  group('OrderRules', () {
    test('isImmutable covers the append-only tables', () {
      expect(OrderRules.isImmutable('orders'), true);
      expect(OrderRules.isImmutable('order_items'), true);
      expect(OrderRules.isImmutable('payments'), true);
      expect(OrderRules.isImmutable('order_voids'), true);
      expect(OrderRules.isImmutable('products'), false);
    });

    test('voided is derived and a void may only be appended once', () {
      expect(OrderRules.isVoided(hasVoidRow: true), true);
      expect(OrderRules.isVoided(hasVoidRow: false), false);
      expect(OrderRules.canVoid(hasVoidRow: false), true);
      expect(OrderRules.canVoid(hasVoidRow: true), false);
    });
  });

  group('OrderChips', () {
    test('a void row always reads Voided', () {
      expect(
        OrderChips.of(hasVoid: true, synced: true, failed: false),
        OrderChip.voided,
      );
      expect(
        OrderChips.of(hasVoid: true, synced: false, failed: true),
        OrderChip.voided,
      );
    });

    test('otherwise the outbox decides Synced / Pending / Failed', () {
      expect(
        OrderChips.of(hasVoid: false, synced: true, failed: false),
        OrderChip.synced,
      );
      expect(
        OrderChips.of(hasVoid: false, synced: false, failed: false),
        OrderChip.pending,
      );
      expect(
        OrderChips.of(hasVoid: false, synced: false, failed: true),
        OrderChip.failed,
      );
    });
  });
}
