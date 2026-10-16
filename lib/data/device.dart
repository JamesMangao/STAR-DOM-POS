import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

import 'api.dart';
import 'db.dart';
import 'logic.dart';

/// Device identity + order_no allocation.
///
/// B7: `device_code` is assigned by the SERVER (register_device picks the next
/// free 2-character code for the store). order_no is globally unique and
/// built from that code, so two devices inventing their own code would collide
/// permanently. Until the registration succeeds the device has NO code and a
/// sale cannot be created — the app blocks it instead of risking a 409 that
/// never resolves.
class DeviceRegistry {
  DeviceRegistry(this._db);
  final AppDatabase _db;

  static const _kDeviceId = 'device_id';
  static const _kStoreId = 'store_id';
  static const _storage = FlutterSecureStorage();

  Device? _current;
  Device? get current => _current;

  /// True when this device already carries a server-assigned code.
  bool get isRegistered => (_current?.deviceCode ?? '').isEmpty == false;

  /// Registers (or loads) this device LOCALLY. [storeId] comes from seed/config.
  /// The code stays empty until [registerWithServer] succeeds.
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
    // No existing device — generate a new local identity.
    final now = DateTime.now().toUtc();
    final device = Device(
      id: const Uuid().v4(),
      storeId: storeId,
      deviceName: await _defaultName(),
      deviceCode: '', // the server fills this in
      isActive: true,
      lastSyncAt: null,
      createdAt: now,
      updatedAt: now,
    );
    await _db.upsertDevice(device);
    _current = device;
    return _current!;
  }

  /// B7: ask the server for this device's code. Idempotent — the server keys on
  /// the device id, so a retry returns the same code. Returns true when the
  /// device now has one; offline it simply returns false and the caller keeps
  /// blocking sales.
  Future<bool> registerWithServer({required String storeId}) async {
    final device = _current ?? await ensureRegistered(storeId);
    if (device.deviceCode.isNotEmpty) return true;
    if (!Api.instance.isReady) return false;
    try {
      final res = await Api.instance.registerDevice(
        deviceId: device.id,
        storeId: storeId,
        deviceName: device.deviceName,
      );
      final now = DateTime.now().toUtc();
      final updated = Device(
        id: device.id,
        storeId: device.storeId,
        deviceName: device.deviceName,
        deviceCode: res.deviceCode,
        isActive: device.isActive,
        lastSyncAt: device.lastSyncAt,
        createdAt: device.createdAt,
        updatedAt: now,
      );
      _current = await _db.upsertDevice(updated);
      return true;
    } catch (_) {
      return false;
    }
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

  /// order_no = {device_code}-{YYMMDD}-{seq}, unique per store (globally, in
  /// fact). The day is the STORE-LOCAL day (B8): Manila is UTC+8, so a 07:00
  /// sale belongs to that local day and not to the UTC day before it.
  Future<String> nextOrderNo({int? tzOffsetMinutes}) async {
    final device = _current;
    if (device == null) throw StateError('Device not registered');
    if (device.deviceCode.isEmpty) {
      throw StateError('Device has no server-assigned code yet');
    }
    final now = DateTime.now().toUtc();
    final tz = tzOffsetMinutes ?? await _db.tzOffsetMinutes(device.storeId);
    final seq = await _db.dailyOrderSeq(
      device.deviceCode,
      OrderNo.dayKey(now, tzOffsetMinutes: tz),
    );
    return OrderNo.generate(device.deviceCode, now, seq, tzOffsetMinutes: tz);
  }
}
