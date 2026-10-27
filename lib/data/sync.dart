import 'dart:async';
import 'dart:convert';

import 'api.dart';
import 'bundle.dart';
import 'db.dart';
import 'device.dart';
import 'sync_policy.dart';

enum SyncState { synced, offline, failed }

/// Background sync engine. The local DB is primary; this pushes the outbox and
/// pulls deltas when online.
///
/// Two rules it exists to obey (see sync_policy.dart, which owns the decisions):
///   * OFFLINE IS NOT FAILED. A timeout or socket error parks nothing; a booth
///     can be offline all day and still hold every sale as pending (B5).
///   * A BUNDLE IS PUSHED PARENTS FIRST (B6) and a whole entity at a time, so a
///     failure halfway leaves a valid prefix that the next replay completes.
class SyncEngine {
  SyncEngine(this._db, [this._devices]);

  final AppDatabase _db;
  final DeviceRegistry? _devices;

  final _stateController = StreamController<SyncState>.broadcast();
  Stream<SyncState> get stateStream => _stateController.stream;

  SyncState _state = SyncState.offline;
  SyncState get state => _state;

  Timer? _timer;

  /// Runs QUEUED or executing: [_start] increments at enqueue and the run's
  /// finally decrements, so the flag stays true for the whole chain and
  /// background ticks are dropped until the queue drains.
  int _queueDepth = 0;
  bool get _busy => _queueDepth > 0;

  /// The serialization chain: every run awaits the previous one before it
  /// touches the database, so a background tick and a manual "Sync now" can
  /// never write at the same time. Two overlapping runs are two writers on
  /// one SQLite file — on a slow Android phone that is a swallowed
  /// SQLITE_BUSY, racing error state, and a "server could not be reached"
  /// verdict no run ever produced.
  Future<void>? _tail;
  int _ticks = 0;
  String? _storeId;

  /// Every flush tick is 10s; a (paged) pull runs every [_pullEveryTicks].
  static const Duration tick = Duration(seconds: 10);
  static const int _pullEveryTicks = 6;

  void start(String storeId) {
    _storeId = storeId;
    _timer?.cancel();
    _timer = Timer.periodic(tick, (_) => unawaited(syncNow()));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void _setState(SyncState s) {
    if (_state == s) return;
    _state = s;
    _stateController.add(s);
  }

  /// One background tick: register the device if needed, pull deltas
  /// periodically, then flush. Never queues: a tick while a run is in
  /// flight is simply dropped — the next one, 10 s later, is enough.
  Future<void> syncNow() async {
    final storeId = _storeId;
    if (storeId == null) return;
    if (!Api.instance.isReady) {
      _setState(SyncState.offline);
      return;
    }
    if (_busy) return;
    _ticks++;
    final pull = _ticks % _pullEveryTicks == 1;
    await _start(storeId, doPull: pull);
  }

  String? _lastSyncError;
  String? get lastSyncError => _lastSyncError;

  /// Rows the last completed run left queued when it reported no explicit
  /// failure — the only fact [incompleteMessage]'s fallback may state. Null
  /// until a run reads the queue, and reset with every run, so it can never
  /// quote a stale count.
  int? _pendingAfterLastRun;

  /// Rows skipped per table during the last pull because applying them threw
  /// (see [_pull]). Reported through [incompleteMessage], never silently.
  final Map<String, int> pullSkips = {};

  /// One table stops skipping further after this many poison rows in a run:
  /// enough to survive a handful of bad rows, few enough that a table gone
  /// wholly wrong does not grind through 500-row pages tick after tick.
  static const int maxRowSkipsPerTable = 25;

  /// Why the last sync left rows on this device — the ONLY text the sync
  /// chip and the data-loss banner show for an incomplete sync. Both entry
  /// points read this one getter, so tapping "Failed · N" and tapping
  /// "Sync now" can never tell two different stories about one failure.
  String get incompleteMessage {
    final err = _lastSyncError;
    if (err == null) {
      // No run recorded a failure, yet rows are still queued — say exactly
      // THAT. The old text blamed the server/connection here, which was
      // wrong often enough to send the owner chasing wifi for what was a
      // local queue wait (or a run that never got to write its reason).
      final n = _pendingAfterLastRun;
      if (n == null) {
        return 'Sync incomplete. The last sync did not finish cleanly — tap '
            'Sync again to retry.';
      }
      return 'Sync incomplete. $n row${n == 1 ? '' : 's'} still waiting to '
          'be sent to the server — tap Sync again.';
    }
    return 'Sync incomplete. $err';
  }

  /// Explicit "Sync now" from the UI: registration, pull and flush.
  ///
  /// Queues BEHIND runs already in flight and awaits its own run, so the
  /// caller always reads [incompleteMessage] AFTER a run that really touched
  /// the network — never mid-flush, while the reason is still blank and the
  /// UI would fall back to a generic sentence.
  Future<void> syncAll() async {
    final storeId = _storeId;
    if (storeId == null) return;
    if (!Api.instance.isReady) {
      _lastSyncError = 'Sync is not configured on this build.';
      _setState(SyncState.offline);
      return;
    }
    await _start(storeId, doPull: true);
  }

  Future<void> _start(String storeId, {required bool doPull}) {
    // Captured BEFORE _tail is reassigned below: the chain links at enqueue.
    final previous = _tail;
    _queueDepth++;
    final run = () async {
      if (previous != null) {
        try {
          await previous;
        } catch (_) {
          // Failures surface through _lastSyncError (and the UI), never by
          // breaking the chain for every run behind this one.
        }
      }
      try {
        await _run(storeId, doPull: doPull);
      } finally {
        _queueDepth--;
      }
    }();
    _tail = run.catchError((_) {});
    return run;
  }

  /// One full run. Callers guarantee the engine is idle, so whatever the
  /// UI reads afterwards is the verdict of a run that really ran.
  Future<void> _run(String storeId, {required bool doPull}) async {
    _lastSyncError = null;
    _pendingAfterLastRun = null;
    // RLS is owner-only (`to authenticated`): a signed-out device is refused
    // with 42501 "permission denied" on EVERY table — reproduced against the
    // live project. Attempting the flush anyway would burn attempts and blame
    // the network for what is really a missing sign-in, so say the real thing
    // and wait. Selling is untouched: the local DB is primary (B5).
    if (!Api.instance.isReady ||
        Api.instance.client.auth.currentSession == null) {
      _lastSyncError = 'Not signed in on this device — tap "Sign in to sync" '
          'in Settings. Sales are safe locally; syncing waits for the '
          'sign-in.';
      _setState(SyncState.offline);
      return;
    }
    // B7: a device without a server code cannot sell. Register first — it is
    // idempotent, so this is a cheap no-op once it has one.
    try {
      await _devices?.registerWithServer(storeId: storeId);
    } catch (e) {
      _lastSyncError = 'Device registration failed: $e';
    }

    if (doPull) {
      try {
        await _pull(storeId);
      } catch (e) {
        _lastSyncError = 'Pull failed: $e';
      }
      // Local dedupe is PURE LOCAL WORK and runs EVEN WHEN THE PULL FAILED:
      // a booth with dead wifi still must not show the same shelf chip twice.
      // Each pass is isolated so one broken merge cannot skip the rest.
      final passes = <String, Future<void> Function(String)>{
        'categories': _db.deduplicateCategories,
        'payment methods': _db.deduplicatePaymentMethods,
        'devices': _db.deduplicateDevices,
        'products': _db.deduplicateProducts,
      };
      for (final e in passes.entries) {
        try {
          await e.value(storeId);
        } catch (err) {
          _lastSyncError = 'Local cleanup of ${e.key} failed: $err';
        }
      }
    }

    try {
      await _flush(storeId);
    } catch (e) {
      _lastSyncError = 'Flush outbox failed: $e';
      _setState(SyncState.failed);
    }

    // A run that ends with rows still queued ALWAYS says why they are
    // queued: either the push itself reported why (offline / session /
    // rejected above), or every queued row was skipped — parked after too
    // many failures, or waiting out a backoff — which is the story
    // [PushPolicy.explainSkipped] tells.
    if (_lastSyncError == null) {
      try {
        final pending = await _db.pendingOutbox(storeId);
        _pendingAfterLastRun = pending.length;
        _lastSyncError = PushPolicy.explainSkipped(
          pending.map(_db.outboxState),
        );
      } catch (_) {
        // A queue we cannot read is not a new sync failure — stay silent
        // rather than invent one. The fallback in [incompleteMessage] then
        // reports the run, not a fabricated network story.
      }
    }
  }

  // ------------------------------------------------------------------ push

  /// Push pending outbox rows, observing the backoff schedule.
  ///
  /// A network error stops the whole loop for this tick: nothing changed, no
  /// attempt was spent, and the state is Offline — the booth keeps selling.
  Future<void> _flush(String storeId) async {
    final pending = await _db.pendingOutbox(storeId);
    if (pending.isEmpty) {
      _setState(SyncState.synced);
      return;
    }

    // Parents first, then oldest first (B6).
    final ordered = [...pending]
      ..sort((a, b) {
        final byOrder = PushOrder.indexOf(a.entity)
            .compareTo(PushOrder.indexOf(b.entity));
        if (byOrder != 0) return byOrder;
        return a.createdAt.compareTo(b.createdAt);
      });

    // Orders whose SALE bundle has not reached the server yet from this
    // device. RLS on order_voids walks UP to the parent order (003_sync_rls),
    // so a void pushed before its order lands is refused with "new row
    // violates row-level security policy for table order_voids" — an error on
    // a row that was never wrong, and a wasted attempt on both rows. The QA
    // device saw exactly that: void an order while its sale is still queued
    // (or failing) and the void errors on every retry.
    final queuedSales = <String>{};
    for (final e in pending) {
      if (e.entity != SaleBundle.entity) continue;
      final id = _saleOrderId(e.payload);
      if (id != null) queuedSales.add(id);
    }

    var failed = false;
    var offline = false;
    var deferredVoid = false;
    for (final e in ordered) {
      final now = DateTime.now().toUtc();
      final state = _db.outboxState(e);
      if (!PushPolicy.shouldAttempt(state, now)) {
        // Skipped because it FAILED before: parked, or still inside its
        // backoff window. This run could not get the row out, so the run
        // must report Failed — never Synced (which would hide the wait).
        failed = true;
        continue;
      }
      if (e.entity == VoidBundle.entity) {
        final orderId = _voidOrderId(e.payload);
        if (orderId != null && queuedSales.contains(orderId)) {
          // The sale this void reverses is still queued here. Wait for it:
          // no attempt is spent, and the run reports the SALE's reason —
          // which is the one that is actually broken. The void is retried
          // (and succeeds) on the run after the sale lands.
          deferredVoid = true;
          failed = true;
          continue;
        }
      }

      var (result, detail) = await _attempt(e.entity, e.payload);
      if (result == PushResult.authExpired) {
        // The session is refreshed and the row retried ONCE; a 401 is never
        // the row's fault, so it must not burn an attempt.
        final ok = await Api.instance.refreshSession();
        if (ok) (result, detail) = await _attempt(e.entity, e.payload);
      }

      final next = PushPolicy.after(result, state, now);
      switch (result) {
        case PushResult.ok:
        case PushResult.duplicate:
          await _db.markOutboxSynced(e.id);
          // The order is on the server now: its void (queued behind it)
          // may be pushed later in THIS same run.
          if (e.entity == SaleBundle.entity) {
            final id = _saleOrderId(e.payload);
            if (id != null) queuedSales.remove(id);
          }
        case PushResult.offline:
          // The transport's own words travel with the sentence: "check your
          // internet" alone sends the owner chasing wifi when the real
          // signal is a 20 s timeout or a refused connection on one device.
          await _db.markOutboxOffline(e.id, detail ?? 'offline');
          offline = true;
          _lastSyncError = detail == null
              ? 'Supabase tables unreachable — check your internet and Supabase setup.'
              : 'Supabase tables unreachable — check your internet and Supabase setup.'
                  ' ($detail)';
        case PushResult.authExpired:
          await _db.markOutboxOffline(e.id, 'session expired');
          offline = true;
          _lastSyncError = 'Sign-in expired — sign in again to sync.';
        case PushResult.failed:
          // The server's REASON, kept and shown: "attempt N failed" told the
          // owner nothing about WHY the row was refused.
          final why = detail ?? 'server rejected the write';
          await _db.markOutboxFailed(
            e.id,
            'attempt ${next.attempts} failed: $why',
            attempts: next.attempts,
            nextAttemptAt: next.nextAttemptAt,
          );
          failed = true;
          _lastSyncError =
              'Push failed for ${e.entity} (attempt ${next.attempts}): $why.';
      }
      if (offline) break; // no point hammering a dead connection
    }

    if (offline) {
      _setState(SyncState.offline);
      return;
    }
    if (deferredVoid && _lastSyncError == null) {
      // Nothing else went wrong and a void still waits on its sale — say
      // THAT instead of a generic server story.
      _lastSyncError = 'A void is waiting for its sale to reach the server — '
          'tap Sync again once the sale has synced.';
    }
    _setState(failed ? SyncState.failed : SyncState.synced);
  }

  /// The order id inside a queued SALE payload; null when the payload is not
  /// the expected shape. Never throws — a broken payload must not stop the
  /// flush of every other row.
  static String? _saleOrderId(String payload) =>
      _orderIdOf(payload, SaleBundle.order, 'id');

  /// The order id inside a queued VOID payload (see [_saleOrderId]).
  static String? _voidOrderId(String payload) =>
      _orderIdOf(payload, VoidBundle.voidRow, 'order_id');

  static String? _orderIdOf(String payload, String key, String field) {
    try {
      final bundle = jsonDecode(payload);
      final row = bundle is Map<String, dynamic> ? bundle[key] : null;
      final id = row is Map<String, dynamic> ? row[field] : null;
      return id is String && id.isNotEmpty ? id : null;
    } catch (_) {
      return null;
    }
  }

  /// One push: the policy verdict for this row, plus the server's own words
  /// when it refused the write (null for ok/offline shapes). The detail is
  /// what lands in the outbox's last_error and the snackbar, so "Failed · N"
  /// finally says WHY and not only how many attempts were burned.
  Future<(PushResult, String?)> _attempt(String entity, String payload) async {
    try {
      final decoded = jsonDecode(payload) as Map<String, dynamic>;
      await Api.instance.pushRow(entity, decoded).timeout(Api.pushTimeout);
      return (PushResult.ok, null);
    } catch (err) {
      return (Api.classifyError(err), Api.describeError(err));
    }
  }

  // ------------------------------------------------------------------ pull

  /// Delta pull of every table a fresh device needs (B3), keyset-paged on the
  /// SERVER clock (B4): the cursor holds `server_updated_at` for mutable tables
  /// and `server_created_at` for append-only ones, and is stored per table.
  /// Device clock skew therefore cannot lose a row, and every applied row is
  /// kept as the server wrote it — applyRemote* never enqueues (B1).
  ///
  /// QUARANTINE: a row that cannot be applied locally used to throw out of the
  /// whole pull — and because the cursor only advances past rows that
  /// applied, the SAME page re-served the same poison row on every tick:
  /// that table's sync was wedged forever. Rows are now skipped after a
  /// bounded number of failures per table; the cursor moves past them and
  /// [incompleteMessage] says exactly how many were left behind, so a full
  /// re-pull after a fix can fetch them again.
  Future<void> _pull(String storeId) async {
    pullSkips.clear();
    String? fetchError;
    for (final table in PullPlan.tables) {
      final col = PullPlan.cursorColumn(table);
      var cursor = await _db.getPullCursor(storeId, table);
      var pages = 0;
      var skips = 0;
      while (pages < PullPlan.maxPages) {
        pages++;
        final List<Map<String, dynamic>> fetched;
        try {
          fetched = await Api.instance.pullPage(table, cursor: cursor);
        } catch (e) {
          // A page that cannot be FETCHED is a network/server problem, not a
          // poison row: stop this table, but let the other tables try.
          fetchError ??= '$table: $e';
          break;
        }
        if (fetched.isEmpty) break;
        // The `>=` filter re-serves the boundary; this is where it is dropped.
        final rows = PullPage.after(fetched, cursor, col);
        var stopTable = false;
        for (final row in rows) {
          try {
            await _db.applyRemoteRow(table, row);
          } catch (_) {
            skips++;
            pullSkips[table] = (pullSkips[table] ?? 0) + 1;
            if (skips >= maxRowSkipsPerTable) {
              stopTable = true;
              break;
            }
          }
        }
        cursor = cursor.advance(fetched, col);
        await _db.setPullCursor(storeId, table, cursor);
        if (stopTable) break;
        if (fetched.length < PullPlan.pageSize) break;
      }
    }

    final parts = <String>[
      if (fetchError != null) 'Pull failed for $fetchError',
      if (pullSkips.isNotEmpty)
        'Pull skipped ${pullSkips.values.fold<int>(0, (a, b) => a + b)} '
            'unapplyable row(s) (${pullSkips.entries.map((e) => '${e.value} ${e.key}').join(', ')}) — '
            'sync continued past them; tap “Re-pull from server” in Settings '
            'after fixing the data to fetch them again',
    ];
    if (parts.isNotEmpty) _lastSyncError = parts.join('. ');
  }
}
