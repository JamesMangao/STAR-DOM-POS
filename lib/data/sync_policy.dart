/// Pure sync policy: backoff, error classification, push/pull order, the
/// pull cursor and the plain-language report of a queue that was skipped.
/// No Flutter, no DB, no network — so every rule here is unit
/// tested (B4, B5, B6) and the engine in sync.dart can only obey it.
library;

/// What a push attempt means. `offline` is deliberately NOT a failure.
enum PushResult { ok, duplicate, authExpired, offline, failed }

/// How an outbox row is doing.
class OutboxState {
  const OutboxState({
    this.attempts = 0,
    this.nextAttemptAt,
    this.synced = false,
    this.lastError,
  });

  final int attempts;
  final DateTime? nextAttemptAt;
  final bool synced;
  final String? lastError;

  bool get parked => attempts >= PushPolicy.maxAttempts;

  OutboxState copyWith({
    int? attempts,
    DateTime? nextAttemptAt,
    bool? synced,
    String? lastError,
    bool clearError = false,
    bool clearNextAttempt = false,
  }) => OutboxState(
    attempts: attempts ?? this.attempts,
    nextAttemptAt: clearNextAttempt
        ? null
        : (nextAttemptAt ?? this.nextAttemptAt),
    synced: synced ?? this.synced,
    lastError: clearError ? null : (lastError ?? this.lastError),
  );

  @override
  String toString() =>
      'OutboxState(attempts: $attempts, nextAttemptAt: $nextAttemptAt, '
      'synced: $synced, parked: $parked)';
}

/// Backoff + attempt limits + the decision of what to do with a result.
class PushPolicy {
  PushPolicy._();

  /// Parked after this many real failures.
  static const int maxAttempts = 8;

  static const Duration baseDelay = Duration(seconds: 1);
  static const Duration maxDelay = Duration(seconds: 60);

  /// 1s, 2s, 4s … capped at 60s (B5).
  static Duration backoff(int attempts) {
    if (attempts <= 0) return Duration.zero;
    final ms = baseDelay.inMilliseconds * (1 << (attempts - 1).clamp(0, 20));
    return ms >= maxDelay.inMilliseconds
        ? maxDelay
        : Duration(milliseconds: ms);
  }

  /// HTTP status (nullable on a transport error) -> what to do.
  ///
  ///   409 duplicate      -> success, the row is already on the server
  ///   401                -> refresh the session and retry once
  ///   no status/timeout  -> offline: NOT an attempt, NOT a failure
  ///   other 4xx/5xx      -> a real failure, retry with backoff
  static PushResult classify({int? status, bool networkError = false}) {
    if (networkError || status == null) return PushResult.offline;
    if (status == 409) return PushResult.duplicate;
    if (status == 401) return PushResult.authExpired;
    if (status >= 200 && status < 300) return PushResult.ok;
    return PushResult.failed;
  }

  /// Should this row be attempted at [now]?
  static bool shouldAttempt(OutboxState s, DateTime now) {
    if (s.synced || s.parked) return false;
    final at = s.nextAttemptAt;
    if (at == null) return true;
    return !now.isBefore(at);
  }

  /// The next state after a result. `offline` changes nothing, so an offline
  /// booth never parks a sale no matter how long it is down.
  static OutboxState after(PushResult result, OutboxState s, DateTime now) {
    switch (result) {
      case PushResult.ok:
      case PushResult.duplicate:
        return s.copyWith(
          synced: true,
          clearError: true,
          clearNextAttempt: true,
        );
      case PushResult.offline:
        return s;
      case PushResult.authExpired:
        // The session is refreshed and the row retried; not the row's fault.
        return s;
      case PushResult.failed:
        final attempts = s.attempts + 1;
        return s.copyWith(
          attempts: attempts,
          nextAttemptAt: now.add(backoff(attempts)),
          lastError: 'attempt $attempts failed',
        );
    }
  }

  /// The sentence shown when a sync run ended with rows still queued but
  /// pushed NOTHING: every queued row was skipped — parked after
  /// [maxAttempts] real failures, or still inside a backoff window (both
  /// fail [shouldAttempt]). Null when there is nothing queued to explain.
  ///
  /// This is the engine's last line of defence: a run that could not get
  /// its rows out must never leave the UI guessing "what failed?".
  static String? explainSkipped(Iterable<OutboxState> rows) {
    final list = rows.toList(growable: false);
    if (list.isEmpty) return null;
    final parked = list.where((s) => s.parked).length;
    if (parked > 0) {
      return '$parked queued ${parked == 1 ? 'sale was' : 'sales were'} '
          'rejected by the server $maxAttempts times and stopped retrying — '
          'open Settings → Sync details and tap Retry.';
    }
    return 'The server rejected a recent attempt — the app retries '
        'automatically, or open Settings → Sync details to retry now.';
  }
}

/// A sale must reach the server parents-first: order_items and payments carry
/// an FK to orders, and stock_events is checked against the order too (B6).
class PushOrder {
  PushOrder._();

  static const List<String> tables = [
    'orders',
    'order_items',
    'payments',
    'stock_events',
  ];

  static int indexOf(String table) {
    final i = tables.indexOf(table);
    return i < 0 ? tables.length : i;
  }
}

/// Pull plan: every table a fresh device needs, parents first, with the cursor
/// column each one uses (B3, B4).
class PullPlan {
  PullPlan._();

  /// Mutable tables cursor on server_updated_at; append-only ones have no
  /// update, so they cursor on server_created_at. NEVER the device clock.
  static const List<String> mutableTables = [
    'stores',
    'categories',
    'products',
    'payment_methods',
    'settings',
    'devices',
    'day_closes',
  ];

  static const List<String> appendOnlyTables = [
    'orders',
    'order_items',
    'payments',
    'stock_events',
    'order_voids',
  ];

  /// Parents first: stores before categories before products, and orders
  /// before order_items/payments, so a fresh device can insert them in order.
  static const List<String> tables = [
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
  ];

  static const int pageSize = 500;

  /// Safety valve: a single pull never loops further than this many pages per
  /// table (500 x 100 rows), so a server bug cannot spin forever.
  static const int maxPages = 100;

  static bool isAppendOnly(String table) => appendOnlyTables.contains(table);

  static String cursorColumn(String table) =>
      isAppendOnly(table) ? 'server_created_at' : 'server_updated_at';

  static String cursorKey(String table) => 'pull_cursor:$table';
}

/// Which rows of a fetched page still have to be applied.
///
/// The query filters with `>=` on the cursor value, so the rows AT the cursor
/// timestamp come back again; this drops them, using the pk to keep every row
/// at that timestamp exactly once (B4).
class PullPage {
  PullPage._();

  static bool isAfter(
    Map<String, dynamic> row,
    PullCursor cursor,
    String cursorColumn,
  ) {
    final raw = row[cursorColumn];
    if (raw == null) return false; // never pull a row without a server clock
    final at = DateTime.tryParse(raw.toString())?.toUtc();
    if (at == null) return false;
    final c = cursor.cursorValue;
    if (c == null) return true;
    if (at.isAfter(c)) return true;
    if (!at.isAtSameMomentAs(c)) return false;
    final pk = (row['id'] ?? row['key'] ?? '').toString();
    final lastPk = cursor.lastPk;
    return lastPk == null || pk.compareTo(lastPk) > 0;
  }

  static List<Map<String, dynamic>> after(
    Iterable<Map<String, dynamic>> rows,
    PullCursor cursor,
    String cursorColumn,
  ) => rows.where((r) => isAfter(r, cursor, cursorColumn)).toList();
}

/// Keyset paging over (cursor, pk). Clock skew cannot lose a row because the
/// cursor only ever moves forward to a value the SERVER wrote (B4).
class PullCursor {
  const PullCursor({this.cursorValue, this.lastPk});

  final DateTime? cursorValue;
  final String? lastPk;

  bool get isEmpty => cursorValue == null;

  /// The next cursor after applying a page of rows.
  PullCursor advance(Iterable<Map<String, dynamic>> rows, String cursorColumn) {
    DateTime? max = cursorValue;
    String? pk;
    for (final r in rows) {
      final raw = r[cursorColumn];
      if (raw == null) continue;
      final at = DateTime.tryParse(raw.toString())?.toUtc();
      if (at == null) continue;
      final rowPk = (r['id'] ?? r['key'] ?? '').toString();
      if (max == null || at.isAfter(max)) {
        max = at;
        pk = rowPk;
      } else if (at.isAtSameMomentAs(max) &&
          pk != null &&
          rowPk.compareTo(pk) > 0) {
        pk = rowPk;
      }
    }
    return PullCursor(cursorValue: max, lastPk: pk ?? lastPk);
  }

  /// Keyset filter, applied in SQL by [Api.pullPage].
  String describe() => cursorValue == null
      ? 'full'
      : '${cursorValue!.toIso8601String()}|${lastPk ?? ''}';

  static PullCursor parse(String? s) {
    if (s == null || s.isEmpty) return const PullCursor();
    final parts = s.split('|');
    return PullCursor(
      cursorValue: DateTime.tryParse(parts[0])?.toUtc(),
      lastPk: parts.length > 1 && parts[1].isNotEmpty ? parts[1] : null,
    );
  }
}
