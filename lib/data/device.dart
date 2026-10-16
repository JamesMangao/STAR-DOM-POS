import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

import '../core/format.dart';
import 'db.dart';

/// Auto device registration on first launch + order_no generation.
class DeviceRegistry {
  DeviceRegistry(this._db);
  final AppDatabase _db;

  static const _kDeviceId = 'device_id';
  static const _kStoreId = 'store_id';
  static const _storage = FlutterSecureStorage();

  Device? _current;
  Device? get current => _current;

  /// Registers (or loads) this device. [storeId] comes from seed/config.
  Future<Device> ensureRegistered(String storeId) async {
    if (_current != null) return _current!;
    final savedId = await _storage.read(key: _kDeviceId);
    if (savedId != null) {
      final fresh = await _db.deviceById(savedId);
      if (fresh != null) {
        _current = fresh;
        return fresh;
      }
    }
    // No existing device — generate a new one via the db repo.
    final code = _shortCode();
    final now = DateTime.now().toUtc();
    final device = Device(
      id: const Uuid().v4(),
      storeId: storeId,
      deviceName: await _defaultName(),
      deviceCode: code,
      isActive: true,
      lastSyncAt: null,
      createdAt: now,
      updatedAt: now,
    );
    await _db.upsertDevice(device);
    _current = await _db.deviceById(device.id);
    return _current!;
  }

  Future<String?> savedStoreId() => _storage.read(key: _kStoreId);

  Future<String> _defaultName() async {
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      return info.model;
    } catch (_) {
      return 'Phone';
    }
  }

  /// Short 2-char code used in order numbers (e.g. "A1").
  String _shortCode() {
    final id = Uuid().v4().replaceAll('-', '').toUpperCase();
    return id.substring(0, 2);
  }

  /// order_no = {device_code}-{YYMMDD}-{seq}, unique per store.
  Future<String> nextOrderNo() async {
    final device = _current;
    if (device == null) throw StateError('Device not registered');
    final now = DateTime.now().toUtc();
    final dayKey = Fmt.dayKey(now);
    final seq = await _db.dailyOrderSeq(device.deviceCode, dayKey);
    return Fmt.orderNo(device.deviceCode, now, seq);
  }
}
