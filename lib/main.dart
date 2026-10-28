import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' show TableUpdate;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/env.dart';
import 'core/icons.dart';
import 'core/theme.dart';
import 'core/tokens.dart';
import 'core/web_apis.dart' as web;
import 'data/api.dart';
import 'data/auth.dart';
import 'data/catalogue.dart';
import 'data/db.dart';
import 'data/db_open.dart';
import 'data/device.dart';
import 'data/local_backup.dart';
import 'data/logic.dart';
import 'data/sync.dart';
import 'ui/cart.dart';
import 'ui/orders.dart';
import 'ui/products.dart';
import 'ui/reports.dart';
import 'ui/adaptive.dart';
import 'ui/scope.dart';
import 'ui/sell.dart';
import 'ui/settings.dart';
import 'ui/sign_in.dart';
import 'ui/widgets.dart';

/// STAR:DOM POS — single-owner booth POS, installed as a PWA.
///
/// The shell owns what EVERY screen needs: the database, the sync engine, the
/// device registry, the open cart and the sync status. It publishes them
/// through [PosScope] ABOVE the [MaterialApp], so routes pushed from a tab
/// (Cart → Payment → Receipt) resolve the same instances.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final opened = await openAppDatabase();

  // The localStorage mirror is merged back BEFORE any screen reads a table:
  // an intact database keeps all of its rows (INSERT OR IGNORE), an emptied
  // one is refilled — sales, settings and payment methods come back after a
  // restart without anyone touching anything. See `data/local_backup.dart`.
  await LocalBackup.restore(opened.db);

  // W2: ask the browser to treat this origin as persistent, so WebKit does
  // not evict the local database under memory pressure. Brave/Chrome on
  // Android often refuse this permission — that's fine, the IndexedDB
  // backend itself persists data across restarts (reported via
  // opened.persistent). We call persist() as a best-effort hint, but the
  // database's own persistence verdict is what matters for data safety.
  if (Env.isConfigured) {
    await Api.instance.init();
    await OwnerAuth.instance.init();
  }
  await web.requestPersistentStorage(); // best-effort; result is not fatal

  runApp(StardomApp(opened: opened, storagePersisted: opened.persistent));
}

class StardomApp extends StatefulWidget {
  const StardomApp({
    super.key,
    required this.opened,
    required this.storagePersisted,
  });

  final DatabaseOpenResult opened;
  final bool storagePersisted;

  @override
  State<StardomApp> createState() => _StardomAppState();
}

class _StardomAppState extends State<StardomApp> with WidgetsBindingObserver {
  late final AppDatabase _db = widget.opened.db;
  late final DeviceRegistry _devices = DeviceRegistry(_db);
  late final SyncEngine _sync = SyncEngine(_db, _devices);

  /// One source of truth for the chip, the banner and the Settings rows —
  /// owned here, polled every 10 s, read everywhere through [PosScope].
  final ValueNotifier<SyncSummary> _status = ValueNotifier(SyncSummary.idle);

  /// The open basket, held above the tabs so switching Sell → Reports and
  /// back never loses it. In memory only: an uncharged cart is not a sale.
  final CartModel _cart = CartModel();

  String? _storeId;
  bool _booting = true;
  SyncState _state = SyncState.offline;
  int _pending = 0;
  Duration? _oldest;
  int _imageCount = 0;
  String _storagePersisted = 'unknown';
  int _catalogueProducts = 0;
  bool _catalogueSeeded = false;
  String? _catalogueError;

  /// The catalogue's built-in bundle deals — the fallback when the owner has
  /// no saved override in the synced settings table.
  List<BundleRule> _catalogueRules = const [];
  Timer? _ticker;
  StreamSubscription<SyncState>? _stateSub;
  Timer? _backupTimer;
  StreamSubscription<Set<TableUpdate>>? _backupSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _stateSub = _sync.stateStream.listen((s) {
      _state = s;
      refresh();
    });
    // Automatic background sync: the instant the browser reports online,
    // push pending sales to the server — no manual "Sync now" needed.
    web.listenForOnline(() {
      if (!mounted) return;
      _sync.onOnline();
    });
    // Every local change (a sale, a setting, a payment method, a void) is
    // mirrored to localStorage shortly after it lands, so a crash or a PC
    // restart right after selling still keeps the sale. Debounced: a sync
    // pull that writes a hundred rows results in ONE backup, not a hundred.
    _backupSub = _db.tableUpdates().listen((_) {
      _backupTimer?.cancel();
      _backupTimer = Timer(const Duration(milliseconds: 1000), () {
        unawaited(LocalBackup.save(_db));
      });
    });
    unawaited(_boot());
  }

  Future<void> _boot() async {
    await _loadCatalogue();
    final stores = await _db.allStores();
    if (stores.isNotEmpty) {
      _storeId = stores.first.id;
      await _db.setLocalSetting(
        _storeId!,
        'storage_persisted',
        widget.storagePersisted ? 'yes' : 'no',
      );
      // The owner's promo bundle edits ride in the synced settings table;
      // absent or unreadable falls back to the catalogue's built-in deals.
      final savedRules = BundleRulesCodec.tryDecode(
        (await _db.getSetting(_storeId!, BundleRulesCodec.key))?.value,
      );
      _cart.bundleRules = savedRules ?? _catalogueRules;
      // Both of these are local facts the FIRST frame needs: the photo-less
      // shelf sweep (one-shot, see deactivatePhotolessProducts) so Sell and
      // Products agree from the start, and the device row so the auth strip
      // can say whether this booth still needs its server code.
      await _db.deactivatePhotolessProducts(_storeId!);
      await _devices.ensureRegistered(_storeId!);
      // Record whether this device asked the browser to never evict its data
      // (W2), so Settings can show it per-device. Best-effort: if the browser
      // refused, the flag stays false and the device row still works.
      final persistent = await web.requestPersistentStorage();
      if (_devices.current != null) {
        await _db.setDevicePersistent(_devices.current!.id, persistent);
      }
      _sync.start(_storeId!);
      unawaited(_sync.syncAll());
    }
    await refresh();
    // First snapshot even when nothing changed yet — a fresh install must
    // have a mirror in place from minute one, not after the first sale.
    unawaited(LocalBackup.save(_db));
    _ticker = Timer.periodic(const Duration(seconds: 10), (_) => refresh());
    if (!mounted) return;
    setState(() => _booting = false);
  }

  /// The shop's shelf, straight from the app bundle.
  ///
  /// The catalogue carries the products, their artwork and the bundle deals,
  /// so the booth has a real shelf before it has a network. The seed is
  /// idempotent: a product the owner already changed on this device is never
  /// overwritten, and the opening stock is written with the same event id the
  /// server import uses, so the count is never doubled.
  Future<void> _loadCatalogue() async {
    try {
      final catalogue = await Catalogue.load();
      _catalogueRules = catalogue.bundleRules;
      _cart.bundleRules = _catalogueRules;
      final report = await CatalogueSeed.apply(_db, catalogue);
      _catalogueProducts = catalogue.products.length;
      _catalogueError = null;
      if (report.didAnything) {
        _catalogueSeeded = true;
      }
    } catch (e) {
      // A catalogue that cannot be read is NOT a crash: the app keeps
      // working with whatever the server sends, and says so in Settings.
      _catalogueError = '$e';
    }
  }

  @override
  void dispose() {
    // Both periodic timers belong to this State: the status ticker AND the
    // sync engine's 10s flush tick (started in _boot). Leaving either alive
    // is a pending-timer leak the instant the tree is torn down.
    _ticker?.cancel();
    _backupTimer?.cancel();
    _backupSub?.cancel();
    _sync.stop();
    _stateSub?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Device rule: keep the screen awake while the app is visible, and let
    // the browser take the lock back the moment it is not.
    if (state == AppLifecycleState.resumed) {
      unawaited(web.acquireWakeLock());
      // Coming back to the foreground: if online, sync pending rows immediately.
      if (web.isOnline) {
        unawaited(_sync.syncNow());
      }
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      unawaited(web.releaseWakeLock());
    }
  }

  Future<void> refresh() async {
    final storeId = _storeId;
    if (storeId != null) {
      final pending = await _db.pendingCount(storeId);
      final oldestAt = await _db.oldestPendingAt(storeId);
      final images = await _db.cachedImageCount();
      final persisted = await _db.getSetting(storeId, 'storage_persisted');
      if (!mounted) return;
      setState(() {
        _storagePersisted = persisted?.value ?? 'unknown';
        _pending = pending;
        _oldest = oldestAt == null
            ? null
            : DateTime.now().toUtc().difference(oldestAt);
        _imageCount = images;
      });
    }
    _status.value = SyncSummary(
      state: _state,
      pending: _pending,
      oldest: _oldest,
    );
    // Published even with NO store row: a fresh install must still report
    // which storage backend it got (scripts/offline-test.js reads it).
    _publishBootInfo();
  }

  /// The facts an operator needs about an installed PWA. No secrets.
  void _publishBootInfo() {
    web.setBootInfo(
      jsonEncode({
        'storageMode': widget.opened.storageMode,
        'persistent': widget.opened.persistent,
        'storagePersisted': _storagePersisted,
        'missingFeatures': widget.opened.missingFeatures,
        'storeId': _storeId,
        'pendingSales': _pending,
        'imagesCached': _imageCount,
        'catalogueProducts': _catalogueProducts,
        'catalogueSeeded': _catalogueSeeded,
        'catalogueError': _catalogueError,
        'localStorageBackup': LocalBackup.status,
        'signedIn': OwnerAuth.instance.signedIn,
        'configured': Env.isConfigured,
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    // InputMode: a finger resets it, a hardware key sets it. Focus-visible
    // rings (design §3) are drawn only in keyboard mode, so tapping the booth
    // never paints a ring while an external keyboard / scanner does.
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => InputMode.keyboard = false,
      child: Focus(
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent) InputMode.keyboard = true;
          return KeyEventResult.ignored;
        },
        child: PosScope(
          db: _db,
          sync: _sync,
          devices: _devices,
          storeId: _storeId,
          opened: widget.opened,
          status: _status,
          cart: _cart,
          child: MaterialApp(
            title: 'Stardom POS',
            theme: AppTheme.light(),
            debugShowCheckedModeBanner: false,
            home: _booting
                ? const _BootSplashScreen()
                : _storeId == null
                ? const _NotSeededScreen()
                : const PosShell(),
          ),
        ),
      ),
    );
  }
}

/// A pending sale older than this is a real risk, not a slow network.
const _staleAfter = Duration(hours: 24);

/// The five tabs. Each tab owns its own app bar (and its own SyncChip) — the
/// shell only carries the bottom navigation and the data-loss banner.
class PosShell extends StatefulWidget {
  const PosShell({super.key});

  @override
  State<PosShell> createState() => _PosShellState();
}

class _PosShellState extends State<PosShell> {
  int _index = 0;
  final Set<int> _activated = {0};

  /// Live session verdict: the auth strip appears and disappears with the
  /// sign-in itself, not on the next tab switch.
  bool _signedIn = false;
  StreamSubscription<bool>? _authSub;

  /// Set when index.html announces a freshly installed build waiting
  /// (`stardom-update-ready`). Nothing listened to that event before, so a
  /// deployed fix never reached an already-open booth.
  bool _updateReady = false;

  @override
  void initState() {
    super.initState();
    _signedIn = OwnerAuth.instance.signedIn;
    _authSub = OwnerAuth.instance.changes.listen((signedIn) {
      if (mounted) setState(() => _signedIn = signedIn);
    });
    web.listenForAppUpdate(() {
      if (mounted) setState(() => _updateReady = true);
    });
  }

  @override
  void dispose() {
    _authSub?.cancel();
    super.dispose();
  }

  static final _tabs = <Widget>[
    const SellScreen(key: ValueKey('sell')),
    const OrdersScreen(key: ValueKey('orders')),
    const ProductsScreen(key: ValueKey('products')),
    const ReportsScreen(key: ValueKey('reports')),
    const SettingsScreen(key: ValueKey('settings')),
  ];

  static const _destinations = [
    (AppIcons.sell, 'Sell'),
    (AppIcons.orders, 'Orders'),
    (AppIcons.products, 'Products'),
    (AppIcons.reports, 'Reports'),
    (AppIcons.settings, 'Settings'),
  ];

  void _onSelect(int i) {
    if (_index == i && _activated.contains(i)) return;
    setState(() {
      _activated.add(i);
      _index = i;
    });
  }

  @override
  Widget build(BuildContext context) {
    final status = PosScope.of(context).status;
    // Three-tier navigation:
    //   • Compact (< 600): bottom bar, full-width single-column content.
    //   • Medium (600–899): compact left rail (72 px, icon + label),
    //     single-column content with more horizontal room.
    //   • Wide (≥ 900): full left rail (250 px, icon + label + wordmark),
    //     two-pane content (iPad landscape / desktop is the gold standard).
    final medium = Adaptive.isMedium(context);
    final wide = Adaptive.isWide(context);
    return ValueListenableBuilder<SyncSummary>(
      valueListenable: status,
      builder: (context, summary, _) {
        final stale = summary.isStale(_staleAfter);
        final stack = Column(
          children: [
            if (stale) const _DataLossBanner(),
            if (!_signedIn && OwnerAuth.instance.configured) const _AuthStrip(),
            if (_updateReady) const _UpdateReadyBanner(),
            Expanded(
              child: Column(
                children: [
                  const PwaInstallBanner(),
                  // Design §2.10: no page-enter animation on a tab switch —
                  // the tab simply swaps (the old 250 ms crossfade also blew
                  // past the 200 ms tap budget on the booth's A13).
                  Expanded(child: _tabs[_index]),
                ],
              ),
            ),
          ],
        );
        return Scaffold(
          body: wide
              ? Row(
                  children: [
                    PosNavRail(
                      selectedIndex: _index,
                      onDestinationSelected: _onSelect,
                      destinations: _destinations,
                    ),
                    const VerticalDivider(width: 1, thickness: 1),
                    Expanded(child: stack),
                  ],
                )
              : medium
              ? Row(
                  children: [
                    PosNavRailCompact(
                      selectedIndex: _index,
                      onDestinationSelected: _onSelect,
                      destinations: _destinations,
                    ),
                    const VerticalDivider(width: 1, thickness: 1),
                    Expanded(child: stack),
                  ],
                )
              : stack,
          bottomNavigationBar: wide || medium
              ? null
              : PosNavBar(
                  selectedIndex: _index,
                  onDestinationSelected: _onSelect,
                  destinations: _destinations,
                ),
        );
      },
    );
  }
}

/// Active nav item — the design system's pill (§2.7): 135° yellow gradient,
/// gold border, hard `2px 3px 0` stamp shadow, filled glyph. Reduced motion
/// swaps the 150 ms pill slide for an instant change (§2.10).
class _NavPill extends StatelessWidget {
  const _NavPill({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.stacked = false,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  /// Phone bottom bar: glyph ABOVE the label. Five icon+label pills side by
  /// side cannot fit the design's 360–430 px base (spec §1.3/§2.1: 11px
  /// labels under an outlined glyph — at 360px each of the 5 tabs gets 72px,
  /// less than the glyph plus the word), so the bar stacks them, the same
  /// treatment the 72px compact rail uses. Without it the pill's Row
  /// overflows horizontally on every phone.
  final bool stacked;

  @override
  Widget build(BuildContext context) {
    final motion = posMotion(context);
    // Material Symbols are variable: FILL 1 is the active glyph the spec asks
    // for, FILL 0 the outlined resting glyph.
    final glyph = Icon(
      icon,
      size: 22,
      fill: selected ? 1 : 0,
      color: selected ? AppColors.primary : AppColors.inkSoft,
    );
    final labelText = Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: sora(
        11,
        weight: FontWeight.w700,
        color: selected ? AppColors.primary : AppColors.inkSoft,
        height: 1.1,
      ),
    );

    final pill = Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        splashColor: AppColors.yellow.withValues(alpha: 0.18),
        highlightColor: AppColors.yellow.withValues(alpha: 0.10),
        child: AnimatedContainer(
          duration: motion
              ? const Duration(milliseconds: 150)
              : Duration.zero,
          curve: Curves.easeOutCubic,
          padding: EdgeInsets.symmetric(
            horizontal: stacked ? 6 : 14,
            vertical: 7,
          ),
          decoration: BoxDecoration(
            gradient: selected ? AppShadows.navPillGradient : null,
            color: selected ? null : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadius.pill),
            border: Border.all(
              color: selected ? AppShadows.navPillBorder : Colors.transparent,
            ),
            boxShadow: selected
                ? const [AppShadows.navPillShadow]
                : const <BoxShadow>[],
          ),
          child: stacked
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    glyph,
                    const SizedBox(height: 2),
                    labelText,
                  ],
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [glyph, const SizedBox(width: 7), labelText],
                ),
        ),
      ),
    );
    return pill;
  }
}

/// The fixed phone-only bottom bar: five tabs, ≥56 pt targets, safe-area
/// aware — the stock Material `NavigationBar` replaced because it
/// cannot draw the spec's gradient pill or its hard stamp shadow.
class PosNavBar extends StatelessWidget {
  const PosNavBar({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.destinations,
  });

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final List<(IconData, String)> destinations;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.card,
        border: Border(top: BorderSide(color: AppColors.line)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: AppSpacing.bottomNav,
          child: Row(
            children: [
              for (var i = 0; i < destinations.length; i++)
                Expanded(
                  child: Center(
                    child: _NavPill(
                      icon: destinations[i].$1,
                      label: destinations[i].$2,
                      selected: i == selectedIndex,
                      stacked: true, // phone: glyph above the label (§2.1)
                      onTap: () => onDestinationSelected(i),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The left rail (iPad landscape): enhanced with a brand header, generous
/// spacing, and a clean active state. Background is `surfaceLow` (warm cream)
/// so the rail reads as a subtle panel beside the white content area — not a
/// hard white block that fights for attention.
///
/// Active items: yellow gradient pill + 4.5 px crimson left bar + hard stamp
/// shadow (spec §2.7). Inactive items: transparent with ink-soft glyphs, a
/// faint surface-mid tint on press. The bar slot is reserved in both states so
/// switching tabs never moves the icon or label sideways.
class PosNavRail extends StatelessWidget {
  const PosNavRail({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.destinations,
  });

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final List<(IconData, String)> destinations;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 250,
      color: AppColors.surfaceLow,
      child: SafeArea(
        right: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _RailBrand(),
            const Divider(height: 1, thickness: 1, color: AppColors.line),
            const SizedBox(height: 18),
            for (var i = 0; i < destinations.length; i++)
              Padding(
                // Only vertical spacing — horizontal extent is controlled by
                // _RailNavItem itself so the accent bar can bleed to the left
                // edge of the rail without being clipped by outer padding.
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: _RailNavItem(
                  icon: destinations[i].$1,
                  label: destinations[i].$2,
                  selected: i == selectedIndex,
                  onTap: () => onDestinationSelected(i),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The compact left rail (medium tier: portrait iPad, Android tablet).
/// 72 px wide — icon stacks above label, icon-only brand mark at top.
/// Same `surfaceLow` background and crimson left-bar active style as the
/// full rail, so the two tiers feel like one family.
class PosNavRailCompact extends StatelessWidget {
  const PosNavRailCompact({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.destinations,
  });

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final List<(IconData, String)> destinations;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 72,
      color: AppColors.surfaceLow,
      child: SafeArea(
        right: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _RailBrand(iconOnly: true),
            const Divider(height: 1, thickness: 1, color: AppColors.line),
            const SizedBox(height: 14),
            for (var i = 0; i < destinations.length; i++)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: _RailNavItem(
                  icon: destinations[i].$1,
                  label: destinations[i].$2,
                  selected: i == selectedIndex,
                  compact: true,
                  onTap: () => onDestinationSelected(i),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Brand header at the top of the rail: mark + the shop name.
///
/// The name is read LIVE from the store row, so renaming the shop in
/// Settings (Shop → name) updates this header on save — no restart. Falls
/// back to the brand while the row has not loaded yet.
///
/// When [iconOnly] is true (compact rail), only the mark is shown — there's
/// no room for the name on a 72 px rail.
class _RailBrand extends StatefulWidget {
  const _RailBrand({this.iconOnly = false});

  final bool iconOnly;

  @override
  State<_RailBrand> createState() => _RailBrandState();
}

class _RailBrandState extends State<_RailBrand> {
  Store? _store;
  StreamSubscription<Set<TableUpdate>>? _storeSub;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_storeSub != null) return;
    final scope = PosScope.read(context);
    final storeId = scope.storeId;
    if (storeId == null) return;
    final db = scope.db;
    unawaited(_loadName(db, storeId));
    // A Settings save rewrites the store row; this is the same reactive
    // table-update stream the shell already listens on, so the header
    // follows a rename without holding a live query open all session.
    _storeSub = db.tableUpdates().listen((_) {
      unawaited(_loadName(db, storeId));
    });
  }

  Future<void> _loadName(AppDatabase db, String storeId) async {
    final row = await db.store(storeId);
    if (!mounted) return;
    setState(() => _store = row);
  }

  @override
  void dispose() {
    _storeSub?.cancel();
    super.dispose();
  }

  /// Settings → Shop name, trimmed; the brand while it is empty/unknown.
  String get _name {
    final name = _store?.name.trim() ?? '';
    return name.isEmpty ? 'ST⭐️R:Dom' : name;
  }

  @override
  Widget build(BuildContext context) {
    final mark = Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: AppColors.primary,
        borderRadius: BorderRadius.circular(AppRadius.m),
        boxShadow: const [AppShadows.stamp],
      ),
      child: const Icon(
        AppIcons.store,
        size: 18,
        color: AppColors.onPrimary,
      ),
    );
    if (widget.iconOnly) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: mark,
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
      child: Row(
        children: [
          mark,
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: sora(
                    13,
                    weight: FontWeight.w800,
                    color: AppColors.ink,
                    letterSpacing: -0.5,
                    height: 1.15,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  'POS',
                  style: sora(
                    9,
                    weight: FontWeight.w700,
                    color: AppColors.inkSoft,
                    letterSpacing: 0.8,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A single rail destination: clean active state with crimson left bar,
/// subtle press feedback for inactive items.
///
/// When [compact] is true (medium tier), the icon stacks above the label
/// in a column instead of a row — suited to a 72 px wide rail.
class _RailNavItem extends StatefulWidget {
  const _RailNavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.compact = false,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool compact;

  @override
  State<_RailNavItem> createState() => _RailNavItemState();
}

class _RailNavItemState extends State<_RailNavItem> {
  bool _pressed = false;

  /// Spec §2.7 sidebar active style: a 4.5 px `--primary` left bar followed by
  /// a gap, then the item. The slot is always reserved — bar + gap — so the
  /// active pill and the idle rows start at the same x.
  static const _barWidth = 4.5;
  static const _barGap = 1.5;

  @override
  Widget build(BuildContext context) {
    final motion = posMotion(context);
    final active = widget.selected;
    final glyph = Icon(
      widget.icon,
      size: 22,
      fill: active ? 1 : 0,
      color: active ? AppColors.primary : AppColors.inkSoft,
    );
    final labelText = Text(
      widget.label,
      style: sora(
        widget.compact ? 9 : 12,
        weight: FontWeight.w700,
        color: active ? AppColors.primary : AppColors.inkSoft,
        height: 1.1,
      ),
    );

    // The pill (spec §2.7): it paints BEHIND the glyph and label, never
    // around them — the content box is the same in both states, so selecting
    // an item cannot nudge its icon or text sideways.
    //
    // `width: double.infinity` lets it take the whole row: the rail is 250 px
    // and an intrinsic pill used to leave a dead strip on the right.
    final pill = AnimatedContainer(
      width: double.infinity,
      duration: motion ? const Duration(milliseconds: 150) : Duration.zero,
      curve: Curves.easeOutCubic,
      padding: EdgeInsets.symmetric(
        horizontal: widget.compact ? 12 : 14,
        vertical: widget.compact ? 10 : 9,
      ),
      decoration: BoxDecoration(
        gradient: active ? AppShadows.navPillGradient : null,
        color: active
            ? null
            : (_pressed ? AppColors.surfaceMid : Colors.transparent),
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(
          color: active ? AppShadows.navPillBorder : Colors.transparent,
        ),
        boxShadow: active
            ? const [AppShadows.navPillShadow]
            : const <BoxShadow>[],
      ),
      child: widget.compact
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                glyph,
                const SizedBox(height: 4),
                labelText,
              ],
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                glyph,
                const SizedBox(width: 10),
                labelText,
              ],
            ),
    );

    return Semantics(
      button: true,
      selected: active,
      label: widget.label,
      excludeSemantics: true,
      child: InkWell(
        onTap: widget.onTap,
        onTapDown: active ? null : (_) => setState(() => _pressed = true),
        onTapUp: active ? null : (_) => setState(() => _pressed = false),
        onTapCancel: active ? null : () => setState(() => _pressed = false),
        borderRadius: BorderRadius.circular(AppRadius.pill),
        child: Stack(
          children: [
            // Crimson left accent bar — bleeds flush to the rail's left edge
            // and fills the item's full height. It is drawn in BOTH states
            // (transparent when idle) so it never costs the row a pixel.
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              child: AnimatedContainer(
                duration:
                    motion ? const Duration(milliseconds: 150) : Duration.zero,
                width: _barWidth,
                decoration: BoxDecoration(
                  color: active ? AppColors.primary : Colors.transparent,
                  borderRadius: const BorderRadius.only(
                    topRight: Radius.circular(3),
                    bottomRight: Radius.circular(3),
                  ),
                ),
              ),
            ),
            // Bar slot reserved in BOTH states: active and inactive items put
            // their glyph at the exact same x, so the pill stays flush with
            // the rest of the rail — active and idle rows line up pixel for
            // pixel. The 12 px right inset keeps the hard stamp shadow off
            // the rail's divider.
            Padding(
              padding: const EdgeInsets.only(
                left: _barWidth + _barGap,
                right: 12,
              ),
              child: pill,
            ),
          ],
        ),
      ),
    );
  }
}

/// The session, said out loud: a PERMANENT strip (not the corner chip) while
/// this install is signed out. Selling keeps working signed out — but nothing
/// reaches the shop, and a booth that has never registered cannot write a
/// sale at all, so the strip says which of the two it is looking at.
class _AuthStrip extends StatelessWidget {
  const _AuthStrip();

  @override
  Widget build(BuildContext context) {
    final scope = PosScope.read(context);
    final needsCode = (scope.devices.current?.deviceCode ?? '').isEmpty;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.failedBg,
        border: Border.all(color: AppColors.failedBorder),
        borderRadius: BorderRadius.circular(AppRadius.m),
      ),
      child: Row(
        children: [
          const Icon(AppIcons.cloudOff, size: 20, color: AppColors.failedText),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              needsCode
                  ? 'Not signed in — this booth cannot take a sale yet. Sign '
                        'in once so the shop can register it.'
                  : 'Signed out — sales stay on this device and never reach '
                        'the shop.',
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 12.5,
                color: AppColors.failedText,
              ),
            ),
          ),
          const SizedBox(width: 10),
          PosButton(
            label: 'Sign in',
            icon: AppIcons.sync,
            expanded: false,
            height: 36,
            variant: PosButtonVariant.ghost,
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const SignInScreen()),
            ),
          ),
        ],
      ),
    );
  }
}

/// "New version ready": index.html fires this once the service worker has
/// installed the next build. Refresh activates it and reloads — without this
/// bar a deploy waits for someone to think of hard-refreshing.
class _UpdateReadyBanner extends StatelessWidget {
  const _UpdateReadyBanner();

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
    decoration: BoxDecoration(
      color: AppColors.infoBg,
      border: Border.all(color: AppColors.infoBorder),
      borderRadius: BorderRadius.circular(AppRadius.m),
    ),
    child: Row(
      children: [
        const Icon(AppIcons.refresh, size: 20, color: AppColors.infoText),
        const SizedBox(width: 10),
        const Expanded(
          child: Text(
            'New version ready — refresh to pick it up.',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 12.5,
              color: AppColors.infoText,
            ),
          ),
        ),
        const SizedBox(width: 10),
        PosButton(
          label: 'Refresh',
          icon: AppIcons.refresh,
          expanded: false,
          height: 36,
          variant: PosButtonVariant.ghost,
          onPressed: web.applyAppUpdate,
        ),
      ],
    ),
  );
}

/// W2 data-loss guard: the one banner that is allowed to interrupt.
class _DataLossBanner extends StatefulWidget {
  const _DataLossBanner();

  @override
  State<_DataLossBanner> createState() => _DataLossBannerState();
}

class _DataLossBannerState extends State<_DataLossBanner> {
  bool _syncing = false;

  Future<void> _sync() async {
    if (_syncing) return;
    if (!OwnerAuth.instance.signedIn) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Please sign in as owner once to sync data with Supabase.',
          ),
          duration: Duration(seconds: 3),
        ),
      );
      Navigator.of(context)
          .push(MaterialPageRoute<void>(builder: (_) => const SignInScreen()));
      return;
    }
    if (!mounted) return;
    setState(() => _syncing = true);
    final appState = context.findAncestorStateOfType<_StardomAppState>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      final scope = PosScope.read(context);
      await scope.sync.syncAll();
      if (appState != null) await appState.refresh();
      if (!mounted) return;
      // Read the queue directly: the shared status notifier is refreshed
      // asynchronously and can lag the sync just done.
      final storeId = scope.storeId;
      final pending = storeId == null
          ? 0
          : await scope.db.pendingCount(storeId);
      // Green only when the queue is EMPTY AND the run recorded no failure:
      // a pull that skipped rows while nothing was queued must not claim
      // "synced successfully" — the red sentence carries the real reason.
      if (pending == 0 && scope.sync.lastSyncError == null) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text('All sales synced successfully!'),
            backgroundColor: Color(0xFF2E7D32),
            duration: Duration(seconds: 3),
          ),
        );
      } else {
        // Same sentence the sync chip shows — one incomplete sync gets ONE
        // story, no matter which button was tapped.
        messenger.showSnackBar(
          SnackBar(
            content: Text(scope.sync.incompleteMessage),
            backgroundColor: AppColors.primary,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(
            content: Text('Sync error: $e'),
            backgroundColor: AppColors.primary,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.failedBg,
        border: Border.all(color: AppColors.failedBorder),
        borderRadius: BorderRadius.circular(AppRadius.m),
      ),
      child: Row(
        children: [
          const Icon(AppIcons.warning, size: 20, color: AppColors.failedText),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'Unsynced sales on this device. Connect to the internet and tap '
              'Sync. Do not delete the app icon.',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 12.5,
                color: AppColors.failedText,
              ),
            ),
          ),
          const SizedBox(width: 12),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.failedText,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadius.pill),
              ),
            ),
            onPressed: _syncing ? null : _sync,
            icon: _syncing
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(AppIcons.sync, size: 16),
            label: Text(
              _syncing ? 'Syncing...' : 'Sync now',
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

class _NotSeededScreen extends StatelessWidget {
  const _NotSeededScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('ST⭐️R:Dom POS')),
      body: const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No store yet. Run the runbook (import.js) once on the shop '
            'computer, then reopen the app.',
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}

class _BootSplashScreen extends StatefulWidget {
  const _BootSplashScreen();

  @override
  State<_BootSplashScreen> createState() => _BootSplashScreenState();
}

class _BootSplashScreenState extends State<_BootSplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim;
  late final Animation<double> _scale;
  late final Animation<double> _fade;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );
    _scale = Tween<double>(
      begin: 0.96,
      end: 1.04,
    ).animate(CurvedAnimation(parent: _anim, curve: Curves.easeInOut));
    _fade = Tween<double>(
      begin: 0.5,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _anim, curve: Curves.easeInOut));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Design §2.10: the logo breathes only when motion is allowed; reduced
    // motion holds a mid-fade static card.
    final animate = posMotion(context);
    if (animate && !_anim.isAnimating) {
      _anim.repeat(reverse: true);
    } else if (!animate && _anim.isAnimating) {
      _anim.stop();
      _anim.value = 0.5;
    }
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surface,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 24),
            padding: const EdgeInsets.fromLTRB(28, 40, 28, 32),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.9),
              borderRadius: BorderRadius.circular(28),
              border: Border.all(
                color: AppColors.primary.withValues(alpha: 0.08),
              ),
              boxShadow: [
                BoxShadow(
                  color: AppColors.primary.withValues(alpha: 0.08),
                  blurRadius: 36,
                  offset: const Offset(0, 14),
                ),
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.03),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedBuilder(
                  animation: _anim,
                  builder: (context, child) {
                    return Stack(
                      alignment: Alignment.center,
                      children: [
                        Transform.scale(
                          scale: _scale.value * 1.15,
                          child: Container(
                            width: 100,
                            height: 100,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: RadialGradient(
                                colors: [
                                  AppColors.primary.withValues(
                                    alpha: 0.12 * _fade.value,
                                  ),
                                  AppColors.yellow.withValues(
                                    alpha: 0.06 * _fade.value,
                                  ),
                                  Colors.transparent,
                                ],
                              ),
                            ),
                          ),
                        ),
                        Transform.scale(scale: _scale.value, child: child),
                      ],
                    );
                  },
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Image.asset(
                        'assets/stardom-logo.webp',
                        height: 68,
                        fit: BoxFit.contain,
                        errorBuilder: (context, error, trace) => const Text(
                          'ST⭐️R:Dom',
                          style: TextStyle(
                            fontSize: 26,
                            fontWeight: FontWeight.w900,
                            color: AppColors.primary,
                            letterSpacing: 2,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        '×',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: AppColors.inkSoft,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Image.asset(
                        'assets/ka1ofakind.png',
                        height: 60,
                        fit: BoxFit.contain,
                        errorBuilder: (context, error, trace) =>
                            const SizedBox.shrink(),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF4F0),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: AppColors.primary.withValues(alpha: 0.18),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 7,
                        height: 7,
                        decoration: const BoxDecoration(
                          color: Color(0xFF10B981),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          'TERMINAL · OFFLINE READY',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: sora(
                            10.5,
                            weight: FontWeight.w800,
                            color: AppColors.primary,
                            letterSpacing: 0.8,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  'ST⭐️R:Dom × ka1ofakind',
                  style: sora(
                    20,
                    weight: FontWeight.w900,
                    color: AppColors.ink,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Preparing offline database & catalogue…',
                  textAlign: TextAlign.center,
                  style: jakarta(13, color: AppColors.inkSoft),
                ),
                const SizedBox(height: 24),
                ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                  child: const SizedBox(
                    height: 5,
                    child: LinearProgressIndicator(
                      backgroundColor: AppColors.line,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        AppColors.primary,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('⚡', style: TextStyle(fontSize: 12)),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        'Offline-First Convention & Booth Engine',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: jakarta(11, color: AppColors.inkFaint),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
