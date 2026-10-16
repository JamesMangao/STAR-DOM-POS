import 'dart:async';
import 'dart:convert';

import 'api.dart';
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
  bool _busy = false;
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
  /// periodically, then flush.
  Future<void> syncNow() async {
    final storeId = _storeId;
    if (storeId == null) return;
    if (!Api.instance.isReady) {
      _setState(SyncState.offline);
      return;
    }
    _ticks++;
    final pull = _ticks % _pullEveryTicks == 1;
    await _run(storeId, doPull: pull);
  }

  /// Explicit "Sync now" from the UI: registration, pull and flush.
  Future<void> syncAll() async {
    final storeId = _storeId;
    if (storeId == null) return;
    await _run(storeId, doPull: true);
  }

  Future<void> _run(String storeId, {required bool doPull}) async {
    if (_busy || !Api.instance.isReady) return;
    _busy = true;
    try {
      // B7: a device without a server code cannot sell. Register first — it is
      // idempotent, so this is a cheap no-op once it has one.
      await _devices?.registerWithServer(storeId: storeId);

      if (doPull) await _pull(storeId);
      await _flush(storeId);
    } finally {
      _busy = false;
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

    var failed = false;
    var offline = false;
    for (final e in ordered) {
      final now = DateTime.now().toUtc();
      final state = _db.outboxState(e);
      if (!PushPolicy.shouldAttempt(state, now)) {
        if (state.parked) failed = true;
        continue;
      }

      var result = await _attempt(e.entity, e.payload);
      if (result == PushResult.authExpired) {
        // The session is refreshed and the row retried ONCE; a 401 is never
        // the row's fault, so it must not burn an attempt.
        final ok = await Api.instance.refreshSession();
        if (ok) result = await _attempt(e.entity, e.payload);
      }

      final next = PushPolicy.after(result, state, now);
      switch (result) {
        case PushResult.ok:
        case PushResult.duplicate:
          await _db.markOutboxSynced(e.id);
        case PushResult.offline:
          await _db.markOutboxOffline(e.id, 'offline');
          offline = true;
        case PushResult.authExpired:
          await _db.markOutboxOffline(e.id, 'session expired');
          offline = true;
        case PushResult.failed:
          await _db.markOutboxFailed(
            e.id,
            'attempt ${next.attempts} failed',
            attempts: next.attempts,
            nextAttemptAt: next.nextAttemptAt,
          );
          failed = true;
      }
      if (offline) break; // no point hammering a dead connection
    }

    if (offline) {
      _setState(SyncState.offline);
      return;
    }
    _setState(failed ? SyncState.failed : SyncState.synced);
  }

  /// One push. Returns the policy verdict for this row.
  Future<PushResult> _attempt(String entity, String payload) async {
    try {
      final decoded = jsonDecode(payload) as Map<String, dynamic>;
      await Api.instance.pushRow(entity, decoded).timeout(Api.pushTimeout);
      return PushResult.ok;
    } catch (err) {
      return Api.classifyError(err);
    }
  }

  // ------------------------------------------------------------------ pull

  /// Delta pull of every table a fresh device needs (B3), keyset-paged on the
  /// SERVER clock (B4): the cursor holds `server_updated_at` for mutable tables
  /// and `server_created_at` for append-only ones, and is stored per table.
  /// Device clock skew therefore cannot lose a row, and every applied row is
  /// kept as the server wrote it — applyRemote* never enqueues (B1).
  Future<void> _pull(String storeId) async {
    for (final table in PullPlan.tables) {
      final col = PullPlan.cursorColumn(table);
      var cursor = await _db.getPullCursor(storeId, table);
      var pages = 0;
      while (pages < PullPlan.maxPages) {
        pages++;
        final fetched = await Api.instance.pullPage(table, cursor: cursor);
        if (fetched.isEmpty) break;
        // The `>=` filter re-serves the boundary; this is where it is dropped.
        final rows = PullPage.after(fetched, cursor, col);
        for (final row in rows) {
          await _db.applyRemoteRow(table, row);
        }
        cursor = cursor.advance(fetched, col);
        await _db.setPullCursor(storeId, table, cursor);
        if (fetched.length < PullPlan.pageSize) break;
      }
    }
  }
}
