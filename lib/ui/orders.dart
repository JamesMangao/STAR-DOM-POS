import 'dart:async';

import 'package:drift/drift.dart' show TableUpdate, TableUpdateQuery;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/format.dart';
import '../core/icons.dart';
import '../core/tokens.dart';
import '../data/db.dart';
import '../data/logic.dart';
import 'adaptive.dart';
import 'receipt.dart';
import 'scope.dart';
import 'security.dart';
import 'widgets.dart';

/// Screen 06 — ORDERS.
///
/// What was sold, when, how it was paid and whether it reached the shop.
/// Two filters only — Today / All and the payment method — because a cashier
/// answering "did Maya already pay for that?" must never build a query. The
/// All view is bounded: it shows the newest [pageLimit] orders, never the
/// whole history.
class OrdersScreen extends StatefulWidget {
  const OrdersScreen({super.key});

  @override
  State<OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends State<OrdersScreen> {
  static const pageLimit = 50;

  bool _today = true;
  String? _methodId;
  String _search = '';
  List<PaymentMethod> _methods = const [];
  List<Order> _orders = const [];
  Map<String, OrderChip> _chips = const {};
  int _voided = 0;
  bool _loading = true;
  bool _started = false;
  final _searchController = TextEditingController();

  /// The list follows the database instead of waiting for a rebuild: a sale
  /// taken on THIS device writes the local tables (no network involved),
  /// drift reports the change, and the page reloads by itself. Works with no
  /// internet or signal — it is a local event, not a sync tick.
  StreamSubscription<Set<TableUpdate>>? _dbSub;
  Timer? _reloadTimer;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _load();
    _watchDb();
  }

  void _watchDb() {
    final db = PosScope.read(context).db;
    _dbSub = db
        .tableUpdates(
          TableUpdateQuery.onAllTables([
            db.orders,
            db.orderVoids,
            db.syncOutbox,
            db.paymentMethods,
            db.settings,
          ]),
        )
        .listen((_) {
          // A single sale touches five tables in one transaction; sync marks
          // touch more. Coalesce the burst into ONE reload.
          _reloadTimer?.cancel();
          _reloadTimer = Timer(const Duration(milliseconds: 250), () {
            if (mounted) _load();
          });
        });
  }

  @override
  void dispose() {
    _reloadTimer?.cancel();
    _dbSub?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final scope = PosScope.read(context);
    final methods = await scope.db.listPaymentMethods(scope.store);
    final orders = await scope.db.listOrders(
      scope.store,
      businessDate: _today ? DateTime.now() : null,
      paymentMethodId: _methodId,
      limit: _today ? null : pageLimit,
    );
    final chips = await scope.db.chipsFor(orders);
    final voided = await scope.db.voidedCount(
      scope.store,
      businessDate: _today ? DateTime.now() : null,
    );
    // Client-side filter on order number and note (keeps the query simple).
    final filtered = _search.isEmpty
        ? orders
        : orders.where((o) {
            final s = _search.toLowerCase();
            return o.orderNo.toLowerCase().contains(s) ||
                o.note.toLowerCase().contains(s) ||
                o.referenceNo.toLowerCase().contains(s);
          }).toList();
    if (!mounted) return;
    setState(() {
      _methods = methods;
      _orders = filtered;
      _chips = chips;
      _voided = voided;
      _loading = false;
    });
  }

  /// The orders in the CURRENT view that have not reached the shop yet —
  /// the badge on the Sync button (pending = waiting for a tick, failed =
  /// refused and parked).
  int get _unsyncedCount => _orders
      .where(
        (o) =>
            (_chips[o.id] ?? OrderChip.pending) == OrderChip.pending ||
            _chips[o.id] == OrderChip.failed,
      )
      .length;

  /// One push for everything still queued — the same flush the 10-second
  /// tick runs, but NOW, on tap. Safe to hammer: the engine serialises runs.
  Future<void> _syncPending() async {
    final scope = PosScope.read(context);
    await scope.sync.syncAll();
    if (mounted) _load();
  }

  void _select({bool? today, String? methodId}) {
    setState(() {
      if (today != null) _today = today;
      _methodId = methodId;
      _loading = true;
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Orders'),
        actions: [
          if (_unsyncedCount > 0)
            IconButton(
              tooltip:
                  'Sync $_unsyncedCount pending order'
                  '${_unsyncedCount == 1 ? '' : 's'} now',
              onPressed: _loading ? null : _syncPending,
              icon: Badge(
                label: Text('$_unsyncedCount'),
                child: const Icon(AppIcons.sync),
              ),
            ),
          const Padding(
            padding: EdgeInsets.only(right: 12),
            child: Center(child: SyncChip()),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: Adaptive.wideContentMax),
          child: Column(
            children: [
              SizedBox(
                height: 54,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.screen,
                    vertical: 8,
                  ),
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: PillChip(
                        label: 'Today',
                        selected: _today,
                        onTap: () => _select(today: true, methodId: _methodId),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: PillChip(
                        label: 'All',
                        selected: !_today,
                        onTap: () => _select(today: false, methodId: _methodId),
                      ),
                    ),
                    for (final m in _methods.where((m) => m.isEnabled))
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: PillChip(
                          label: m.name,
                          selected: _methodId == m.id,
                          dense: true,
                          onTap: () => _select(
                            methodId: _methodId == m.id ? null : m.id,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              _buildSearch(),
              Expanded(child: _buildList()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSearch() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.screen,
        AppSpacing.sm,
        AppSpacing.screen,
        0,
      ),
      child: SearchField(
        controller: _searchController,
        hint: 'Search order number, note or reference',
        onChanged: (v) {
          _search = v;
          _load();
        },
        onSubmitted: (_) => _load(),
      ),
    );
  }

  Widget _buildList() {
    if (_loading) {
      return ListView.builder(
        padding: const EdgeInsets.all(AppSpacing.screen),
        itemCount: 6,
        itemBuilder: (context, i) => const OrderSkeleton(),
      );
    }
    if (_orders.isEmpty) {
      return EmptyState(
        icon: AppIcons.orders,
        title: _today ? 'No sales yet today' : 'No sales yet',
        message:
            'Every sale lands here the moment it is taken — paid, pending or '
            'voided.',
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.screen,
          AppSpacing.sm,
          AppSpacing.screen,
          AppSpacing.lg,
        ),
        children: [
          if (_voided > 0)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: Text(
                '$_voided order${_voided == 1 ? '' : 's'} voided — excluded '
                'from totals.',
                style: jakarta(12, color: AppColors.inkSoft),
              ),
            ),
          if (!_today && _orders.length == pageLimit)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: Text(
                'Showing the newest $pageLimit orders. Use Today for a '
                'specific day.',
                style: jakarta(12, color: AppColors.inkSoft),
              ),
            ),
          for (final o in _orders)
            _OrderRow(
              order: o,
              chip: _chips[o.id] ?? OrderChip.pending,
              onTap: () => _open(o),
              onLongPress: () => _quickMenu(o),
            ),
        ],
      ),
    );
  }

  Future<void> _open(Order order) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ReceiptScreen(order: order, canVoid: true),
      ),
    );
    // A void appended in the detail screen changes this list's badges.
    if (mounted) _load();
  }

  /// LONG-PRESS a row → the quick-action sheet: the things a cashier does
  /// repeatedly without needing the full receipt screen. The same Void path
  /// (PIN gate + reason) the Receipt screen runs — one gate, everywhere.
  Future<void> _quickMenu(Order order) async {
    final chip = _chips[order.id] ?? OrderChip.pending;
    final voided = chip == OrderChip.voided;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(order.orderNo, style: mono(13, color: AppColors.inkSoft)),
              const SizedBox(height: AppSpacing.md),
              _MenuTile(
                icon: AppIcons.pictureAsPdf,
                title: 'Share receipt PDF',
                subtitle: 'Opens the preview, then the share sheet or download',
                onTap: () => Navigator.of(ctx).pop(),
              ),
              _MenuTile(
                icon: AppIcons.cart,
                title: 'Re-sell same items',
                subtitle:
                    'Refills the cart with today\'s prices and stock rules',
                onTap: () {
                  Navigator.of(ctx).pop();
                  _reSell(order);
                },
              ),
              if (!voided)
                _MenuTile(
                  icon: AppIcons.delete,
                  title: 'Void order',
                  subtitle:
                      'PIN gate + reason, exactly like the receipt screen',
                  destructive: true,
                  onTap: () {
                    Navigator.of(ctx).pop();
                    _voidOrder(order);
                  },
                ),
              _MenuTile(
                icon: AppIcons.copy,
                title: 'Copy order number',
                subtitle: order.orderNo,
                onTap: () {
                  Navigator.of(ctx).pop();
                  Clipboard.setData(ClipboardData(text: order.orderNo));
                  showSnack(context, 'Order number copied.');
                },
              ),
            ],
          ),
        ),
      ),
    );
    // The sheet's actions may have changed this order — keep the badges true.
    if (mounted) _load();
  }

  /// Puts one order's items back into the cart at TODAY'S prices — the
  /// snapshot on the receipt stays what was actually paid. Inactive or deleted
  /// products are skipped and counted, so a stale order can't resurrect a
  /// hidden item.
  Future<void> _reSell(Order order) async {
    final scope = PosScope.read(context);
    final items = await scope.db.orderItemsOf(order.id);
    final qty = <String, int>{};
    for (final it in items) {
      final pid = it.productId;
      if (pid == null) continue; // custom/one-off line — nothing to re-add
      qty[pid] = (qty[pid] ?? 0) + it.quantity;
    }
    var skipped = 0;
    var lines = 0;
    for (final entry in qty.entries) {
      final product = await scope.db.productById(entry.key);
      if (product == null || !product.isActive) {
        skipped += 1;
        continue;
      }
      for (var i = 0; i < entry.value; i++) {
        scope.cart.add(product);
      }
      lines += 1;
    }
    if (!mounted) return;
    if (lines == 0 && skipped > 0) {
      showSnack(
        context,
        'No sellable items on that order anymore.',
        error: true,
      );
    } else {
      showSnack(
        context,
        skipped == 0
            ? 'Added to the cart — finish the sale in Sell.'
            : 'Added to the cart — $skipped item${skipped == 1 ? '' : 's'} skipped '
                  '(inactive/missing),',
      );
    }
  }

  /// The full void flow — the same gate and outcome handling as the Receipt
  /// screen, run from the quick menu.
  Future<void> _voidOrder(Order order) async {
    final scope = PosScope.read(context);
    if (!await voidPinAllowed(context, scope.db, scope.store)) return;
    if (!mounted) return;
    final reason = await askVoidReason(context);
    if (reason == null || reason.isEmpty || !mounted) return;
    final device = await scope.devices.ensureRegistered(scope.store);
    final outcome = await scope.db.voidOrder(
      order.id,
      reason: reason,
      deviceId: device.id,
      storeId: scope.store,
    );
    if (!mounted) return;
    switch (outcome) {
      case VoidOutcome.created:
        showSnack(context, 'Order voided — stock is back on the shelf.');
        await scope.sync.syncAll();
        await _load();
      case VoidOutcome.alreadyVoided:
        showSnack(context, 'This order was already voided.');
        await _load();
      case VoidOutcome.notFound:
        showSnack(context, 'Order not found on this device.', error: true);
    }
  }
}

class _OrderRow extends StatelessWidget {
  const _OrderRow({
    required this.order,
    required this.chip,
    this.onTap,
    this.onLongPress,
  });

  final Order order;
  final OrderChip chip;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final (label, kind) = switch (chip) {
      OrderChip.voided => ('Voided', BadgeKind.voided),
      OrderChip.failed => ('Failed', BadgeKind.failed),
      OrderChip.pending => ('Pending', BadgeKind.pending),
      OrderChip.synced => ('Synced', BadgeKind.synced),
    };
    final voided = chip == OrderChip.voided;
    return PosCard(
      margin: const EdgeInsets.only(bottom: AppSpacing.md),
      padding: const EdgeInsets.all(AppSpacing.md),
      onTap: onTap,
      onLongPress: onLongPress,
      child: Row(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(Fmt.time(order.createdAt.toLocal()), style: mono(13)),
              const SizedBox(height: 4),
              Text(order.orderNo, style: mono(11, color: AppColors.inkSoft)),
            ],
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  order.referenceNo.isEmpty
                      ? (order.note.isEmpty ? 'Sale' : order.note)
                      : 'Ref ${order.referenceNo}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: jakarta(12, color: AppColors.inkSoft),
                ),
                const SizedBox(height: 4),
                StatusBadge(label, kind: kind),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          priceText(
            order.total,
            size: 16,
            color: voided ? AppColors.inkFaint : AppColors.ink,
          ),
        ],
      ),
    );
  }
}

/// One row of the long-press quick sheet.
class _MenuTile extends StatelessWidget {
  const _MenuTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.destructive = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: PosCard(
        padding: const EdgeInsets.all(AppSpacing.md),
        onTap: onTap,
        child: Row(
          children: [
            Icon(
              icon,
              size: 22,
              color: destructive ? AppColors.primary : AppColors.ink,
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: sora(
                      14,
                      weight: FontWeight.w700,
                      color: destructive ? AppColors.primary : AppColors.ink,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(subtitle, style: jakarta(12, color: AppColors.inkSoft)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
