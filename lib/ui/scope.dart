import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../data/db.dart';
import '../data/db_storage.dart';
import '../data/device.dart';
import '../data/sync.dart';
import 'cart.dart';

/// What the sync chip and the Settings screen show right now.
///
/// Owned by the shell (it already polls the outbox every 10 s) and published as
/// a [ValueListenable] so the chip in the app bar, the chip on pushed routes and
/// the Settings rows all read ONE source of truth instead of four timers.
class SyncSummary {
  const SyncSummary({required this.state, required this.pending, this.oldest});

  final SyncState state;
  final int pending;

  /// How long the OLDEST unsynced sale has been waiting; null when the outbox
  /// is empty. The data-loss banner needs it (stale after 24 h).
  final Duration? oldest;

  static const SyncSummary idle = SyncSummary(
    state: SyncState.offline,
    pending: 0,
  );

  /// True when a sale has been waiting longer than [staleAfter] — the W2
  /// "do not delete the app icon" condition.
  bool isStale(Duration staleAfter) =>
      pending > 0 && (oldest ?? Duration.zero) > staleAfter;
}

/// Everything the screens need, without a 6-parameter constructor chain.
///
/// Sits ABOVE the [MaterialApp] so pushed routes (Cart → Payment → Receipt)
/// resolve it too — a route pushed from a tab is NOT a descendant of the tab.
class PosScope extends InheritedWidget {
  const PosScope({
    super.key,
    required this.db,
    required this.sync,
    required this.devices,
    required this.storeId,
    required this.opened,
    required this.status,
    required this.cart,
    required super.child,
  });

  final AppDatabase db;
  final SyncEngine sync;
  final DeviceRegistry devices;
  final String? storeId;
  final DatabaseOpenResult opened;
  final ValueListenable<SyncSummary> status;
  final CartModel cart;

  static PosScope of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<PosScope>();
    assert(scope != null, 'PosScope missing above this route');
    return scope!;
  }

  /// Like [of] but without subscribing the caller to rebuilds — for one-off
  /// reads (opening a form) where a rebuild would restart an in-flight query.
  static PosScope read(BuildContext context) {
    final element = context.getElementForInheritedWidgetOfExactType<PosScope>();
    assert(element != null, 'PosScope missing above this route');
    return element!.widget as PosScope;
  }

  /// The single seeded store. The shell shows the "No store yet" notice when
  /// this is null, so screens can assert it is set.
  String get store => storeId!;

  @override
  bool updateShouldNotify(PosScope old) =>
      old.db != db ||
      old.sync != sync ||
      old.devices != devices ||
      old.storeId != storeId ||
      old.opened != opened ||
      old.status != status ||
      old.cart != cart;
}
