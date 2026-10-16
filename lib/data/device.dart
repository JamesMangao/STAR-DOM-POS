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
///
/// W2: the web has no hardware id and no `device_info_plus`, so the identity is
/// a UUID generated once and persisted in the local database (settings), and
/// the name defaults to a human label the owner can rename in Settings. The
/// session/identity never depends on `flutter_secure_storage`.
class DeviceRegistry {
  DeviceRegistry(this._db);
  final AppDatabase _db;

  static const _kDeviceId = 'device_id';

  /// What a fresh web install calls itself until the owner renames it.
  static const defaultDeviceName = 'Booth iPad';

  Device? _current;
  Device? get current => _current;

  /// True when this device already carries a server-assigned code.
  bool get isRegistered => (_current?.deviceCode ?? '').isEmpty == false;

  /// Registers (or loads) this device LOCALLY. [storeId] comes from seed/config.
  /// The code stays empty until [registerWithServer] succeeds.
  Future<Device> ensureRegistered(String storeId) async {
    if (_current != null) return _current!;

    // A device id minted on a previous visit lives in settings, so a reload or
    // a reinstall of the PWA keeps the same identity (and the same device row).
    final saved = await _db.getSetting(storeId, _kDeviceId);
    final savedId = saved?.value;
    if (savedId != null && savedId.isNotEmpty) {
      final fresh = await _db.deviceById(savedId);
      if (fresh != null) {
        _current = fresh;
        await _remember(storeId, fresh.id);
        return fresh;
      }
    }

    // No existing device — generate a new local identity.
    final now = DateTime.now().toUtc();
    final device = Device(
      id: const Uuid().v4(),
      storeId: storeId,
      deviceName: defaultDeviceName,
      deviceCode: '', // the server fills this in
      isActive: true,
      lastSyncAt: null,
      createdAt: now,
      updatedAt: now,
    );
    await _db.upsertDevice(device);
    await _remember(storeId, device.id);
    _current = device;
    return _current!;
  }

  Future<void> _remember(String storeId, String deviceId) =>
      _db.setLocalSetting(storeId, _kDeviceId, deviceId);

  /// The store this install belongs to: the single seeded store row.
  Future<String?> savedStoreId() async {
    final stores = await _db.allStores();
    if (stores.length != 1) return stores.isEmpty ? null : stores.first.id;
    return stores.first.id;
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
