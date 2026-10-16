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
      expect(
        OrderNo.generate('A1', DateTime.utc(2026, 1, 15), 1),
        'A1-260115-001',
      );
      expect(
        OrderNo.generate('A1', DateTime.utc(2026, 1, 15), 5),
        'A1-260115-005',
      );
      expect(
        OrderNo.generate('A1', DateTime.utc(2026, 1, 16), 1),
        'A1-260116-001',
      );
    });

    test('dayKey returns YYMMDD for the STORE-LOCAL day (B8)', () {
      expect(OrderNo.dayKey(DateTime.utc(2026, 1, 15, 4)), '260115');
      expect(OrderNo.dayKey(DateTime.utc(2026, 12, 31, 4)), '261231');
    });

    test('dayKey uses the local day, not the UTC one', () {
      // 2026-01-15 18:00 UTC is 2026-01-16 02:00 in Manila (UTC+8).
      final at = DateTime.utc(2026, 1, 15, 18);
      expect(OrderNo.dayKey(at), '260116');
      expect(OrderNo.dayKey(at, tzOffsetMinutes: 0), '260115');
    });
  });

  group('BusinessDate', () {
    test('startOfDayUtc is local midnight, stored as its UTC instant (B8)', () {
      // 23:59Z on the 15th is 07:59 on the 16th in Manila, so the business day
      // started at 2026-01-15T16:00Z.
      expect(
        BusinessDate.startOfDayUtc(DateTime.utc(2026, 1, 15, 23, 59)),
        DateTime.utc(2026, 1, 15, 16),
      );
      // With no offset it is the UTC midnight it always was.
      expect(
        BusinessDate.startOfDayUtc(
          DateTime.utc(2026, 1, 15, 23, 59),
          tzOffsetMinutes: 0,
        ),
        DateTime.utc(2026, 1, 15),
      );
    });

    test('key renders YYYY-MM-DD and sameDay compares the local day', () {
      expect(BusinessDate.key(DateTime.utc(2026, 1, 15, 4)), '2026-01-15');
      expect(
        BusinessDate.sameDay(
          DateTime.utc(2026, 1, 15, 4, 1),
          DateTime.utc(2026, 1, 15, 15, 59),
        ),
        true,
      );
      // 00:01Z and 23:59Z on the 15th are the 15th and the 16th locally.
      expect(
        BusinessDate.sameDay(
          DateTime.utc(2026, 1, 15, 0, 1),
          DateTime.utc(2026, 1, 15, 23, 59),
        ),
        false,
      );
      // …but with no offset the same pair is one UTC day.
      expect(
        BusinessDate.sameDay(
          DateTime.utc(2026, 1, 15, 0, 1),
          DateTime.utc(2026, 1, 15, 23, 59),
          tzOffsetMinutes: 0,
        ),
        true,
      );
      // The old UTC rule split the Manila evening across two business days;
      // 23:59Z and 00:01Z on the 16th are the SAME local day (the 16th).
      expect(
        BusinessDate.sameDay(
          DateTime.utc(2026, 1, 15, 23, 59),
          DateTime.utc(2026, 1, 16, 0, 1),
        ),
        true,
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
