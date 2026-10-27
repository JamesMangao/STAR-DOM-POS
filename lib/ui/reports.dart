import 'dart:async';

import 'package:drift/drift.dart' show TableUpdate, TableUpdateQuery;
import 'package:flutter/material.dart';

import '../core/format.dart';
import '../core/icons.dart';
import '../core/tokens.dart';
import '../data/db.dart';
import '../data/logic.dart';
import 'adaptive.dart';
import 'scope.dart';
import 'widgets.dart';

/// Screen 09 — REPORTS.
///
/// The owner's end-of-day view: what today took, by hour and by method, and
/// the cash count that closes the drawer. Expected cash is
/// float + (cash sales − voided cash sales), so the number the owner counts
/// against is the number actually in the drawer.
class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  DateTime _day = DateTime.now();

  /// Every day at once instead of one business day. The totals, the method /
  /// hour / category breakdowns all widen; the drawer tools (cash count, End
  /// of Day) stay day-scoped and disappear, because a drawer closes per day.
  bool _allTime = false;

  List<Order> _active = const [];
  Map<String, PaymentMethod> _methods = const {};
  int _voided = 0;
  double _cashSales = 0;
  double _float = 0;
  DayClose? _closed;
  final _counted = TextEditingController();
  bool _loading = true;
  bool _closing = false;
  bool _started = false;

  /// Category breakdown for the selected day (lazy-loaded).
  List<({String name, double total, int count})> _byCategory = const [];
  bool _categoryLoaded = false;

  /// Live figures: any local write to the tables this screen totals from
  /// (a sale, a void, a day close, a payment-method change) reloads the day
  /// in place — a purely local event, so it works with no signal.
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
            db.payments,
            db.paymentMethods,
            db.settings,
            db.dayCloses,
          ]),
        )
        .listen((_) {
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
    _counted.dispose();
    super.dispose();
  }

  PaymentMethod? get _cashMethod {
    for (final m in _methods.values) {
      if (m.type == 'cash' && m.isEnabled) return m;
    }
    return null;
  }

  double get _expected => Money.round(_cashSales + _float);

  double? get _countedValue {
    final text = _counted.text.trim();
    if (text.isEmpty) return null;
    final v = double.tryParse(text);
    return v == null || v.isNegative ? null : Money.round(v);
  }

  Future<void> _load() async {
    final scope = PosScope.read(context);
    final store = scope.store;
    final device = await scope.devices.ensureRegistered(store);
    final methods = await scope.db.listPaymentMethods(store);
    // No businessDate = every order the store has (the day-scoped helpers
    // treat a null date as "all of them").
    final date = _allTime ? null : _day;
    final active = await scope.db.activeOrders(store, businessDate: date);
    final voided = await scope.db.voidedCount(store, businessDate: date);
    final cash = _allTime
        ? 0.0
        : await scope.db.cashExpected(
            storeId: store,
            businessDate: _day,
            cashPaymentMethodId: _cashMethod?.id ?? '',
          );
    final floatSetting = await scope.db.getSetting(store, 'cash_float');
    final closed = _allTime
        ? null
        : await scope.db.dayClose(
            storeId: store,
            deviceId: device.id,
            businessDate: _day,
          );
    final tz = await scope.db.tzOffsetMinutes(store);
    final start = _allTime
        ? DateTime.utc(2000)
        : BusinessDate.startOfDayUtc(_day, tzOffsetMinutes: tz);
    final end = _allTime
        ? DateTime.now().toUtc().add(const Duration(days: 1))
        : start.add(const Duration(days: 1));
    final byCategory = await scope.db.salesByCategory(
      store,
      start: start,
      end: end,
    );
    if (!mounted) return;
    setState(() {
      _methods = {for (final m in methods) m.id: m};
      _active = active;
      _voided = voided;
      _cashSales = cash;
      _float = double.tryParse(floatSetting?.value ?? '') ?? 0;
      _closed = closed;
      _byCategory = byCategory;
      _categoryLoaded = true;
      _loading = false;
      if (closed?.cashActual != null && _counted.text.isEmpty) {
        _counted.text = closed!.cashActual!.toStringAsFixed(2);
      }
    });
  }

  Future<void> _pickDay() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _allTime ? DateTime.now() : _day,
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now(),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _day = picked;
      _allTime = false;
      _loading = true;
      _counted.clear();
    });
    _load();
  }

  /// The scope menu behind the Reports header button: one day (today or a
  /// picked date) or the whole history.
  void _applyScope(String scope) {
    if (scope == 'day') {
      unawaited(_pickDay());
      return;
    }
    setState(() {
      if (scope == 'today') {
        _day = DateTime.now();
        _allTime = false;
      } else {
        _allTime = true;
      }
      _loading = true;
      _counted.clear();
    });
    _load();
  }

  String get _scopeLabel => _allTime
      ? 'All time'
      : (_isToday ? 'Today' : Fmt.date(_day));

  Future<void> _saveFloat(String value) async {
    final scope = PosScope.read(context);
    final v = double.tryParse(value.trim());
    if (v == null || v.isNegative) return;
    final device = await scope.devices.ensureRegistered(scope.store);
    await scope.db.setSetting(
      scope.store,
      'cash_float',
      Money.round(v).toStringAsFixed(2),
      deviceId: device.id,
    );
    if (!mounted) return;
    setState(() => _float = Money.round(v));
  }

  Future<void> _closeDay() async {
    final cash = _cashMethod;
    if (cash == null || _closing) return;
    final counted = _countedValue;
    if (counted == null) {
      showSnack(
        context,
        'Count the drawer first and type the amount.',
        error: true,
      );
      return;
    }
    final variance = Money.round(counted - _expected);
    final ok = await confirm(
      context,
      title: 'Close ${_isToday ? 'today' : Fmt.date(_day)}?',
      message:
          'Expected ₱${_expected.toStringAsFixed(2)} in the drawer, you counted '
          '₱${counted.toStringAsFixed(2)} — variance ₱'
          '${variance.toStringAsFixed(2)}. Closing is saved on this device '
          'and syncs later; sales keep working.',
      confirmLabel: 'Close Day',
    );
    if (!ok || !mounted) return;
    setState(() => _closing = true);
    final scope = PosScope.read(context);
    final device = await scope.devices.ensureRegistered(scope.store);
    final closed = await scope.db.closeDay(
      storeId: scope.store,
      deviceId: device.id,
      businessDate: _day,
      cashPaymentMethodId: cash.id,
      cashActual: counted,
      cashFloat: _float,
      closedBy: device.deviceName,
    );
    await scope.sync.syncAll();
    if (!mounted) return;
    setState(() {
      _closed = closed;
      _closing = false;
    });
    showSnack(context, 'Day closed. Hand the count sheet to the owner.');
  }

  bool get _isToday {
    final now = DateTime.now();
    return _day.year == now.year &&
        _day.month == now.month &&
        _day.day == now.day;
  }

  @override
  Widget build(BuildContext context) {
    final total = Money.sum(_active.map((o) => o.total));
    return Scaffold(
      appBar: AppBar(
        title: const Text('Reports'),
        actions: [
          PopupMenuButton<String>(
            onSelected: _applyScope,
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'today', child: Text('Today')),
              PopupMenuItem(value: 'day', child: Text('Pick a date…')),
              PopupMenuItem(value: 'all', child: Text('All time')),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _allTime ? AppIcons.reports : AppIcons.calendar,
                    size: 18,
                    color: AppColors.ink,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _scopeLabel,
                    style: sora(13, weight: FontWeight.w700),
                  ),
                ],
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.only(right: 12),
            child: Center(child: SyncChip()),
          ),
        ],
      ),
      body: _loading
          ? Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: Adaptive.wideContentMax,
                ),
                child: ListView(
                  padding: const EdgeInsets.all(AppSpacing.screen),
                  children: [
                    Row(
                      children: [
                        Expanded(child: KpiSkeleton()),
                        const SizedBox(width: AppSpacing.md),
                        Expanded(child: KpiSkeleton()),
                        Expanded(child: KpiSkeleton()),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    SectionCard(
                      title: 'By payment method',
                      children: [
                        const KpiSkeleton(),
                        const KpiSkeleton(),
                        const KpiSkeleton(),
                      ],
                    ),
                    SectionCard(
                      title: 'By hour',
                      children: [
                        const KpiSkeleton(),
                        const KpiSkeleton(),
                        const KpiSkeleton(),
                      ],
                    ),
                    SectionCard(
                      title: 'By category',
                      children: [
                        const KpiSkeleton(),
                        const KpiSkeleton(),
                        const KpiSkeleton(),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.xl),
                  ],
                ),
              ),
            )
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: Adaptive.wideContentMax,
                ),
                child: RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(AppSpacing.screen),
                    children: [
                      if (!_allTime &&
                          _isToday &&
                          _closed == null &&
                          _active.isNotEmpty &&
                          _cashMethod != null) ...[
                        _EndOfDayNudge(
                          sales: _active.length,
                          total: total,
                          busy: _closing,
                          onClose: _closeDay,
                        ),
                        const SizedBox(height: AppSpacing.lg),
                      ],
                      Row(
                        children: [
                          Expanded(
                            child: _KpiCard(
                              label: 'Total sales',
                              icon: AppIcons.cash,
                              child: priceText(total, size: 22),
                            ),
                          ),
                          const SizedBox(width: AppSpacing.md),
                          Expanded(
                            child: _KpiCard(
                              label: 'Sales',
                              icon: AppIcons.orders,
                              child: Text(
                                '${_active.length}',
                                style: sora(22, weight: FontWeight.w800),
                              ),
                            ),
                          ),
                          const SizedBox(width: AppSpacing.md),
                          Expanded(
                            child: _KpiCard(
                              label: 'Voided',
                              icon: AppIcons.error,
                              child: Text(
                                '$_voided',
                                style: sora(
                                  22,
                                  weight: FontWeight.w800,
                                  color: _voided > 0
                                      ? AppColors.primary
                                      : AppColors.ink,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.lg),
                      SectionCard(
                        title: 'By payment method',
                        children: _methodRows(total),
                      ),
                      SectionCard(title: 'By hour', children: _hourRows()),
                      SectionCard(
                        title: 'By category',
                        children: _categoryRows(),
                      ),
                      // The drawer closes per business day — an all-time
                      // view has nothing to count or close.
                      if (!_allTime && _cashMethod != null)
                        SectionCard(
                          title: 'Cash count',
                          children: [
                            DetailRow('Cash sales', Fmt.peso(_cashSales)),
                            PosField(
                              label: 'Cash float (drawer start)',
                              value: _float.toStringAsFixed(2),
                              prefix: '₱',
                              hint: '0.00',
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                    decimal: true,
                                  ),
                              onChanged: _saveFloat,
                            ),
                            DetailRow(
                              'Expected in drawer',
                              Fmt.peso(_expected),
                              valueStyle: sora(14, weight: FontWeight.w800),
                            ),
                            PosField(
                              label: 'Counted cash',
                              controller: _counted,
                              prefix: '₱',
                              hint: '0.00',
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                    decimal: true,
                                  ),
                              onChanged: (_) => setState(() {}),
                            ),
                            if (_countedValue != null)
                              DetailRow(
                                'Variance',
                                Fmt.peso(
                                  Money.round(_countedValue! - _expected),
                                ),
                                valueStyle: sora(
                                  14,
                                  weight: FontWeight.w800,
                                  color:
                                      Money.round(_countedValue! - _expected) ==
                                          0
                                      ? AppColors.green
                                      : AppColors.primary,
                                ),
                              ),
                            if (_closed != null)
                              PosAlert.ok(
                                text:
                                    'Day closed — counted '
                                    '${Fmt.peso(_closed!.cashActual ?? 0)}, '
                                    'variance ${Fmt.peso(_closed!.variance ?? 0)}.',
                              )
                            else
                              PosButton(
                                label: 'Close Day',
                                icon: AppIcons.check,
                                busy: _closing,
                                onPressed: _closeDay,
                              ),
                          ],
                        )
                      else if (!_allTime)
                        const PosAlert.info(
                          text:
                              'Enable a Cash payment method to count and close the '
                              'drawer.',
                        ),
                      const SizedBox(height: AppSpacing.xl),
                    ],
                  ),
                ),
              ),
            ),
    );
  }

  List<Widget> _methodRows(double total) {
    final byMethod = <String, (double, int)>{};
    for (final o in _active) {
      final key = o.paymentMethodId ?? '';
      final prev = byMethod[key] ?? (0, 0);
      byMethod[key] = (Money.round(prev.$1 + o.total), prev.$2 + 1);
    }
    if (byMethod.isEmpty) {
      return [
        Text(
          _allTime ? 'No sales yet.' : 'No sales yet for this day.',
          style: jakarta(13, color: AppColors.inkSoft),
        ),
      ];
    }
    final rows = byMethod.entries.toList()
      ..sort((a, b) => b.value.$1.compareTo(a.value.$1));
    return [
      for (final e in rows)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(
            children: [
              Icon(
                _methods[e.key]?.type == 'cash' ||
                        (_methods[e.key] == null && e.key.isEmpty)
                    ? AppIcons.cash
                    : AppIcons.wallet,
                size: 18,
                color: AppColors.inkSoft,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _methods[e.key]?.name ?? 'Unpaid / removed method',
                  style: jakarta(13, weight: FontWeight.w600),
                ),
              ),
              Text(
                '${e.value.$2} sale${e.value.$2 == 1 ? '' : 's'}',
                style: jakarta(12, color: AppColors.inkSoft),
              ),
              const SizedBox(width: 12),
              priceText(e.value.$1, size: 14, color: AppColors.ink),
            ],
          ),
        ),
      const Divider(),
      DetailRow(
        'Total',
        Fmt.peso(total),
        valueStyle: sora(14, weight: FontWeight.w800),
      ),
    ];
  }

  List<Widget> _hourRows() {
    final byHour = <int, (double, int)>{};
    for (final o in _active) {
      final h = o.createdAt.toLocal().hour;
      final prev = byHour[h] ?? (0, 0);
      byHour[h] = (Money.round(prev.$1 + o.total), prev.$2 + 1);
    }
    if (byHour.isEmpty) {
      return [
        Text(
          _allTime ? 'No sales yet.' : 'No sales yet for this day.',
          style: jakarta(13, color: AppColors.inkSoft),
        ),
      ];
    }
    final hours = byHour.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return [
      // The mockup's chart first — bars that show SHAPE — then the exact
      // figures underneath (the progress bars are gone: they read as
      // "loading", not data).
      _HourlyChart(hours: hours),
      const SizedBox(height: AppSpacing.sm),
      const Divider(),
      for (final e in hours)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(
            children: [
              SizedBox(
                width: 64,
                child: Text(
                  _hourLabel(e.key),
                  style: mono(12, color: AppColors.inkSoft),
                ),
              ),
              Expanded(
                child: Text(
                  '${e.value.$2} sale${e.value.$2 == 1 ? '' : 's'}',
                  style: jakarta(12, color: AppColors.inkSoft),
                ),
              ),
              priceText(e.value.$1, size: 13, color: AppColors.ink),
            ],
          ),
        ),
    ];
  }

  static String _hourLabel(int hour) {
    final h = hour % 12 == 0 ? 12 : hour % 12;
    final suffix = hour < 12 ? 'AM' : 'PM';
    return '$h $suffix';
  }

  List<Widget> _categoryRows() {
    if (!_categoryLoaded) {
      return [
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    }
    if (_byCategory.isEmpty) {
      return [
        Text(
          _allTime
              ? 'No sales by category yet.'
              : 'No sales by category for this day.',
          style: jakarta(13, color: AppColors.inkSoft),
        ),
      ];
    }
    final total = _byCategory.fold<double>(0, (a, e) => a + e.total);
    final rows = _byCategory.toList()
      ..sort((a, b) => b.total.compareTo(a.total));
    return [
      for (final e in rows)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(e.name, style: jakarta(13, weight: FontWeight.w600)),
                    Text(
                      '${e.count} item${e.count == 1 ? '' : 's'}',
                      style: jakarta(11, color: AppColors.inkSoft),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              priceText(e.total, size: 14, color: AppColors.ink),
            ],
          ),
        ),
      const Divider(),
      DetailRow(
        'Total',
        Fmt.peso(total),
        valueStyle: sora(14, weight: FontWeight.w800),
      ),
    ];
  }
}

class _KpiCard extends StatelessWidget {
  const _KpiCard({required this.label, required this.child, this.icon});

  final String label;
  final Widget child;

  /// The design system's `.kpi` icon tile (§2.3): 34 px, radius 9,
  /// `#FFE0DE` background, crimson glyph, top-right.
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return PosCard(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label.toUpperCase(),
                  style: sora(
                    9.5,
                    weight: FontWeight.w800,
                    color: AppColors.inkSoft,
                    letterSpacing: 0.6,
                  ),
                ),
              ),
              if (icon != null)
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: AppColors.kpiIconBg,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Icon(icon, size: 18, color: AppColors.primary),
                ),
            ],
          ),
          const SizedBox(height: 6),
          child,
        ],
      ),
    );
  }
}

/// End-of-day nudge: the drawer only gets counted when somebody remembers.
/// Sits at the TOP of today's report while sales exist and the day is still
/// open — the same [PosAlert] voice, with the action already on it.
class _EndOfDayNudge extends StatelessWidget {
  const _EndOfDayNudge({
    required this.sales,
    required this.total,
    required this.busy,
    required this.onClose,
  });

  final int sales;
  final double total;
  final bool busy;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: AppColors.infoBg,
      borderRadius: BorderRadius.circular(AppRadius.m),
      border: Border.all(color: AppColors.infoBorder),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(AppIcons.calendar, size: 18, color: AppColors.infoText),
        const SizedBox(width: 9),
        Expanded(
          child: Text(
            'End of day — $sales sale${sales == 1 ? '' : 's'} '
            '(${Fmt.peso(total)}) and the drawer is still open. Count it and '
            'close the day.',
            style: jakarta(
              13,
              weight: FontWeight.w600,
              color: AppColors.infoText,
            ),
          ),
        ),
        const SizedBox(width: 10),
        PosButton(
          label: 'Close day',
          icon: AppIcons.check,
          expanded: false,
          height: 36,
          busy: busy,
          variant: PosButtonVariant.ghost,
          onPressed: onClose,
        ),
      ],
    ),
  );
}

/// The hourly chart from the mockup: crimson bars, the peak hour in gold,
/// mono hour labels under a hairline baseline. One [CustomPaint] pass — cheap
/// on the booth's A13 — with a semantics summary, because the exact numbers
/// live in the rows right below it.
class _HourlyChart extends StatelessWidget {
  const _HourlyChart({required this.hours});

  /// hour → (total, count), as the rows below build it.
  final List<MapEntry<int, (double, int)>> hours;

  @override
  Widget build(BuildContext context) {
    final peak = hours.fold<double>(
      0,
      (a, e) => e.value.$1 > a ? e.value.$1 : a,
    );
    if (peak <= 0) return const SizedBox.shrink();
    final peakHour = hours.firstWhere((e) => e.value.$1 == peak).key;
    return Semantics(
      label:
          'Hourly sales chart. ${_ReportsScreenState._hourLabel(peakHour)} '
          'is the peak at ${Fmt.peso(peak)}.',
      child: SizedBox(
        height: 132,
        width: double.infinity,
        child: CustomPaint(
          painter: _HourlyBarsPainter(
            bars: [for (final e in hours) (e.key, e.value.$1)],
            peak: peak,
          ),
        ),
      ),
    );
  }
}

class _HourlyBarsPainter extends CustomPainter {
  const _HourlyBarsPainter({required this.bars, required this.peak});

  /// (hour, total) for every hour with sales, ascending.
  final List<(int, double)> bars;
  final double peak;

  static const _labelBand = 18.0;

  @override
  void paint(Canvas canvas, Size size) {
    if (bars.isEmpty || size.width <= 0) return;
    final chartH = size.height - _labelBand;
    const gap = 5.0;
    final n = bars.length;
    final barW = (size.width - gap * (n - 1)) / n;
    final maxH = chartH - 6;
    // Thin columns get every second label — they would collide otherwise.
    final labelEvery = barW >= 26 ? 1 : 2;
    for (var i = 0; i < n; i++) {
      final (hour, total) = bars[i];
      final raw = (total / peak) * maxH;
      final h = raw < 4 ? 4.0 : raw;
      final x = i * (barW + gap);
      final bar = Paint()
        ..color = total >= peak ? AppColors.yellow : AppColors.primary;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, chartH - h, barW, h),
          const Radius.circular(3),
        ),
        bar,
      );
      if (i % labelEvery == 0) {
        final h12 = hour % 12 == 0 ? 12 : hour % 12;
        final suffix = hour < 12 ? 'a' : 'p';
        final tp = TextPainter(
          text: TextSpan(
            text: '$h12$suffix',
            style: mono(9.5, color: AppColors.inkFaint),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(x + (barW - tp.width) / 2, chartH + 5));
      }
    }
    final baseline = Paint()
      ..color = AppColors.line
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(0, chartH + 0.5),
      Offset(size.width, chartH + 0.5),
      baseline,
    );
  }

  @override
  bool shouldRepaint(covariant _HourlyBarsPainter old) =>
      old.peak != peak || old.bars.toString() != bars.toString();
}
