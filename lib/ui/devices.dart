import 'package:flutter/material.dart';

import '../core/icons.dart';
import '../core/tokens.dart';
import '../data/db.dart';
import 'adaptive.dart';
import 'scope.dart';
import 'widgets.dart';

/// The shop's devices, seen from THIS install.
///
/// One device row was being minted every time the owner cleared browser site
/// data, so the register_device API fills the register now — this screen is
/// the leftover-cleaner: it shows every row the shop keeps, marks the one that
/// is THIS booth, and lets the owner deactivate (or reactivate) the rest.
/// Deactivating does not rewrite history: terms/O(n) sales keep the code they
/// were issued under.
class DevicesScreen extends StatefulWidget {
  const DevicesScreen({super.key});

  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  List<Device> _devices = const [];
  String? _ownId;
  bool _loading = true;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _load();
  }

  Future<void> _load() async {
    final scope = PosScope.read(context);
    final rows = await scope.db.listDevices(scope.store);
    final own = (await scope.db.getSetting(scope.store, 'device_id'))?.value;
    if (!mounted) return;
    setState(() {
      _ownId = own;
      // Newest registration first, regardless of activity.
      _devices = [...rows]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      _loading = false;
    });
  }

  Future<void> _setActive(Device d, bool active) async {
    final scope = PosScope.read(context);
    // The one thing that must reach the server: without the push, two booths
    // keep disagreeing about which of them is the live one.
    await scope.db.setDeviceActive(
      d.id,
      active,
      storeId: scope.store,
      byDeviceId: _ownId,
    );
    if (!mounted) return;
    showSnack(
      context,
      active
          ? '“${d.deviceName}” (${d.deviceCode}) is back on rotation.'
          : '“${d.deviceName}” (${d.deviceCode}) is now inactive.',
    );
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Devices'),
        actions: [
          IconButton(
            icon: const Icon(AppIcons.refresh),
            tooltip: 'Reload',
            onPressed: _loading ? null : () => _load(),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: Adaptive.formMax),
                child: ListView(
                  padding: const EdgeInsets.all(AppSpacing.screen),
                  children: [
                    Text(
                      'The cups a device row costs: each new row the server '
                      'registers gets its own till code, so stale ones '
                      'sit idle unless deactivated. Every line below is one '
                      'booth identity.',
                      style: jakarta(12.5, color: AppColors.inkSoft),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    for (final d in _devices)
                      _DeviceRow(
                        device: d,
                        isOwn: d.id == _ownId,
                        onActiveChanged: d.id == _ownId
                            ? null
                            : (active) => _setActive(d, active),
                      ),
                    const SizedBox(height: AppSpacing.lg),
                  ],
                ),
              ),
            ),
    );
  }
}

class _DeviceRow extends StatelessWidget {
  const _DeviceRow({
    required this.device,
    required this.isOwn,
    required this.onActiveChanged,
  });

  final Device device;
  final bool isOwn;
  final ValueChanged<bool>? onActiveChanged;

  @override
  Widget build(BuildContext context) {
    final d = device;
    return PosCard(
      margin: const EdgeInsets.only(bottom: AppSpacing.md),
      onTap: null,
      child: Row(
        children: [
          Icon(
            AppIcons.device,
            color: d.isActive ? AppColors.primary : AppColors.inkFaint,
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isOwn ? '${d.deviceName} — this device' : d.deviceName,
                  style: sora(14, weight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(
                  'Till code ${d.deviceCode.isEmpty ? '—' : d.deviceCode} · '
                  'registered ${_stamp(d.createdAt)}',
                  style: mono(11, color: AppColors.inkSoft),
                ),
              ],
            ),
          ),
          StatusBadge(
            d.isActive ? 'Active' : 'Inactive',
            kind: d.isActive ? BadgeKind.synced : BadgeKind.neutral,
          ),
          if (onActiveChanged != null) ...[
            const SizedBox(width: AppSpacing.sm),
            PosButton(
              label: d.isActive ? 'Deactivate' : 'Reactivate',
              height: 32,
              expanded: false,
              variant: PosButtonVariant.quiet,
              onPressed: () => onActiveChanged!(d.isActive),
            ),
          ],
        ],
      ),
    );
  }

  String _stamp(DateTime t) {
    final l = t.toLocal();
    return '${l.year}-${l.month.toString().padLeft(2, '0')}-'
        '${l.day.toString().padLeft(2, '0')}';
  }
}
