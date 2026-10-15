import 'dart:async';
import 'dart:convert';

import 'api.dart';
import 'db.dart';
import 'logic.dart';
import 'models.dart';

enum SyncState { synced, offline, failed }

/// Background sync engine. Local DB is primary; this pushes the outbox and
/// pulls deltas when online. Manual "Sync now" triggers [syncNow].
class SyncEngine {
  SyncEngine(this._db);
  final AppDatabase _db;

  final _stateController = StreamController<SyncState>.broadcast();
  Stream<SyncState> get stateStream => _stateController.stream;

  SyncState _state = SyncState.offline;
  SyncState get state => _state;

  Timer? _timer;
  bool _flushing = false;

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => flush());
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

  /// Push pending outbox events. Idempotent (dedupe by event id).
  /// Exponential backoff: 1s, 2s, 4s … cap 60s; park after 8 attempts.
  Future<void> flush() async {
    if (_flushing || !Api.instance.isReady) return;
    _flushing = true;
    try {
      final pending = await _db.pendingOutbox(_storeId);
      if (pending.isEmpty) {
        _setState(SyncState.synced);
        return;
      }
      _setState(SyncState.offline);
      var failed = false;
      for (final e in pending) {
        if (e.attempts >= 8) {
          failed = true;
          continue;
        }
        try {
          await Api.instance.pushRow(e.entity, jsonDecode(e.payload) as Map<String, dynamic>);
          await _db.markOutboxSynced(e.id);
        } catch (err) {
          await _db.markOutboxFailed(e.id, err.toString());
          failed = true;
        }
      }
      _setState(failed ? SyncState.failed : SyncState.synced);
    } finally {
      _flushing = false;
    }
  }

  /// Pull delta since last_sync_at. New device: full pull.
  Future<void> pull({String? storeId}) async {
    if (!Api.instance.isReady) return;
    final sid = storeId ?? _storeId;
    final device = await _db.deviceById(_deviceId);
    final since = device?.lastSyncAt;
    for (final table in ['products', 'categories', 'payment_methods', 'settings']) {
      final rows = await Api.instance.pullRows(table, since: since);
      for (final row in rows) {
        await _applyRemote(table, row);
      }
    }
    if (_deviceId != null) await _db.touchSync(_deviceId!);
  }

  Future<void> _applyRemote(String table, Map<String, dynamic> row) async {
    final updatedAt = row['updated_at'] == null
        ? null
        : DateTime.tryParse(row['updated_at'] as String);
    switch (table) {
      case 'products':
        final existing = await _db.productById(row['id'] as String);
        if (LastWriteWins.serverWins(
            localUpdatedAt: existing?.updatedAt, serverUpdatedAt: updatedAt)) {
          await _db.upsertProduct(
            Product(
              id: row['id'] as String,
              storeId: row['store_id'] as String,
              categoryId: row['category_id'] as String?,
              name: row['name'] as String,
              price: (row['price'] as num).toDouble(),
              barcode: row['barcode'] as String?,
              imagePath: row['image_path'] as String?,
              stockQuantity: (row['stock_quantity'] as num?)?.toInt() ?? 0,
              isActive: row['is_active'] as bool? ?? true,
              createdAt: DateTime.now(),
              updatedAt: updatedAt,
            ),
            deviceId: _deviceId ?? '',
            storeId: row['store_id'] as String,
          );
        }
        break;
      case 'categories':
        await _db.upsertCategory(Category(
          id: row['id'] as String,
          storeId: row['store_id'] as String,
          name: row['name'] as String,
          sortOrder: (row['sort_order'] as num?)?.toInt() ?? 0,
          isActive: row['is_active'] as bool? ?? true,
        ));
        break;
      case 'payment_methods':
        await _db.upsertPaymentMethod(
          PaymentMethod(
            id: row['id'] as String,
            storeId: row['store_id'] as String,
            name: row['name'] as String,
            type: row['type'] as String,
            color: row['color'] as String? ?? '#B70011',
            qrImagePath: row['qr_image_path'] as String?,
            accountName: row['account_name'] as String? ?? '',
            accountNumber: row['account_number'] as String? ?? '',
            requireReference: row['require_reference'] as bool? ?? false,
            isEnabled: row['is_enabled'] as bool? ?? true,
            sortOrder: (row['sort_order'] as num?)?.toInt() ?? 0,
            updatedAt: updatedAt,
          ),
          deviceId: _deviceId ?? '',
          storeId: row['store_id'] as String,
        );
        break;
    }
  }

  /// Manual "Sync now" — flush outbox then pull.
  Future<void> syncNow({String? storeId, String? deviceId}) async {
    if (deviceId != null) _deviceId = deviceId;
    await flush();
    await pull(storeId: storeId);
  }

  String _storeId = '';
  String? _deviceId;

  void configure({required String storeId, required String deviceId}) {
    _storeId = storeId;
    _deviceId = deviceId;
  }

  /// Retry all parked (failed) outbox events.
  Future<void> retry() async {
    final pending = await _db.pendingOutbox(_storeId);
    for (final e in pending) {
      await _db.retryOutbox(e.id);
    }
    await flush();
  }
}
