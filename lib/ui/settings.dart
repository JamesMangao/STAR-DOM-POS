import 'dart:convert';

import 'package:flutter/material.dart';

import '../core/format.dart';
import '../core/icons.dart';
import '../core/tokens.dart';
import '../core/web_apis.dart' as web;
import '../data/api.dart';
import '../data/auth.dart';
import '../data/db.dart';
import '../data/export_pdf.dart';
import '../data/local_backup.dart';
import '../data/logic.dart';
import 'adaptive.dart';
import 'bundles.dart';
import 'devices.dart';
import 'payment_methods.dart';
import 'products.dart' show CategoriesScreen;
import 'scope.dart';
import 'security.dart';
import 'sign_in.dart';
import 'widgets.dart';

/// Screen 10 — SETTINGS.
///
/// The owner's half of the app: what the shop is called, what the receipt
/// says, how this device syncs, and the export button for the monthly backup.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  Store? _store;
  final _name = TextEditingController();
  final _tagline = TextEditingController();
  final _receiptName = TextEditingController();
  final _tin = TextEditingController();
  final _address = TextEditingController();
  final _accreditation = TextEditingController();
  final _footer = TextEditingController();
  final _deviceName = TextEditingController();
  String _storageMode = '—';
  String _persisted = 'unknown';
  int _imageCount = 0;
  int _imageBytes = 0;
  List<String> _missing = const [];
  bool _saving = false;
  bool _signedIn = false;
  bool _started = false;
  bool _repulling = false;
  bool _persisting = false;
  bool _voidPinOn = false;
  bool _pinBusy = false;

  /// Export time range: 'day', 'week', 'month', 'quarter', 'all'.
  String _timeRange = 'all';
  bool _exportingPdf = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _signedIn = OwnerAuth.instance.signedIn;
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    _tagline.dispose();
    _receiptName.dispose();
    _tin.dispose();
    _address.dispose();
    _accreditation.dispose();
    _footer.dispose();
    _deviceName.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final scope = PosScope.read(context);
    final store = await scope.db.store(scope.store);
    final images = await scope.db.cachedImageCount();
    final bytes = await scope.db.cachedImageBytes();
    final persisted = await scope.db.getSetting(
      scope.store,
      'storage_persisted',
    );
    final device = await scope.devices.ensureRegistered(scope.store);
    final voidPin = await scope.db.getSetting(scope.store, VoidPin.key);
    if (!mounted) return;
    setState(() {
      _store = store;
      if (store != null) {
        _name.text = store.name;
        _tagline.text = store.tagline;
        _receiptName.text = store.receiptName;
        _tin.text = store.receiptTin;
        _address.text = store.receiptAddress;
        _accreditation.text = store.receiptAccreditation;
        _footer.text = store.receiptFooter;
      }
      _deviceName.text = device.deviceName;
      _storageMode = scope.opened.description;
      _persisted = persisted?.value ?? 'unknown';
      _imageCount = images;
      _imageBytes = bytes;
      _voidPinOn = (voidPin?.value ?? '').isNotEmpty;
      _missing = scope.opened.missingFeatures;
    });
  }

  /// Ask the browser AGAIN for persistent storage and record the verdict the
  /// same way boot does, so this screen and the next launch tell one story.
  /// The prompt may only be raised from a real gesture — this button is it.
  Future<void> _retryPersist() async {
    if (_persisting) return;
    setState(() => _persisting = true);
    final ok = await web.requestPersistentStorage();
    final scope = PosScope.read(context);
    await scope.db.setLocalSetting(
      scope.store,
      'storage_persisted',
      ok ? 'yes' : 'no',
    );
    if (!mounted) return;
    setState(() {
      _persisting = false;
      _persisted = ok ? 'yes' : 'no';
    });
    showSnack(
      context,
      ok
          ? 'Storage is permanent now — this device keeps the shop data.'
          : 'This browser still refuses to promise permanent storage.',
    );
  }

  /// Set / change / remove the Void PIN — one synced setting, so every booth
  /// enforces the same gate. Reloads the row's verdict when it returns.
  Future<void> _editVoidPin() async {
    if (_pinBusy) return;
    setState(() => _pinBusy = true);
    try {
      final value = await editVoidPin(context);
      if (value == null) return;
      if (!mounted) return;
      setState(() => _voidPinOn = value.isNotEmpty);
      showSnack(
        context,
        value.isEmpty
            ? 'Void PIN off — voids need only a reason again.'
            : 'Void PIN saved — every booth asks for it now.',
      );
    } finally {
      if (mounted) setState(() => _pinBusy = false);
    }
  }

  Future<void> _saveShop() async {
    final store = _store;
    if (store == null || _saving) return;
    setState(() => _saving = true);
    final scope = PosScope.read(context);
    final device = await scope.devices.ensureRegistered(scope.store);
    await scope.db.upsertStore(
      store.copyWith(
        name: _name.text.trim().isEmpty ? store.name : _name.text.trim(),
        tagline: _tagline.text.trim(),
        receiptName: _receiptName.text.trim(),
        receiptTin: _tin.text.trim(),
        receiptAddress: _address.text.trim(),
        receiptAccreditation: _accreditation.text.trim(),
        receiptFooter: _footer.text.trim(),
        updatedAt: DateTime.now().toUtc(),
      ),
      deviceId: device.id,
    );
    await scope.sync.syncAll();
    if (!mounted) return;
    setState(() => _saving = false);
    showSnack(context, 'Shop details saved.');
  }

  Future<void> _renameDevice() async {
    final name = _deviceName.text.trim();
    if (name.isEmpty) return;
    final scope = PosScope.read(context);
    await scope.devices.rename(name);
    if (!mounted) return;
    showSnack(context, 'This device is now “$name”.');
  }

  Future<void> _exportData() async {
    final scope = PosScope.read(context);
    final dump = await scope.db.exportAll();
    final stamp = DateTime.now().toUtc().toIso8601String().substring(0, 10);
    web.downloadFile(
      'stardom-pos-export-$stamp.json',
      'application/json',
      utf8.encode(const JsonEncoder.withIndent('  ').convert(dump)),
    );
    if (!mounted) return;
    showSnack(context, 'Backup downloaded — keep it somewhere safe.');
  }

  Future<void> _exportPdf() async {
    final scope = PosScope.read(context);
    final store = scope.store;
    final storeRow = await scope.db.store(store);
    final storeName = storeRow?.name ?? 'Stardom';

    final now = DateTime.now().toUtc();
    final tz = await scope.db.tzOffsetMinutes(store);
    final localNow = BusinessDate.local(now, tzOffsetMinutes: tz);

    DateTime start;
    String periodLabel;
    switch (_timeRange) {
      case 'day':
        start = BusinessDate.startOfDayUtc(localNow, tzOffsetMinutes: tz);
        periodLabel = 'Past day';
        break;
      case 'week':
        start = localNow.subtract(const Duration(days: 7));
        start = BusinessDate.startOfDayUtc(start, tzOffsetMinutes: tz);
        periodLabel = 'Past 7 days';
        break;
      case 'month':
        start = localNow.subtract(const Duration(days: 30));
        start = BusinessDate.startOfDayUtc(start, tzOffsetMinutes: tz);
        periodLabel = 'Past 30 days';
        break;
      case 'quarter':
        start = localNow.subtract(const Duration(days: 90));
        start = BusinessDate.startOfDayUtc(start, tzOffsetMinutes: tz);
        periodLabel = 'Past 90 days';
        break;
      case 'all':
      default:
        start = DateTime.utc(2000, 1, 1);
        periodLabel = 'All time';
    }
    final end = now.add(const Duration(days: 1));

    setState(() => _exportingPdf = true);

    final active = await scope.db.ordersInRange(store, start: start, end: end);
    final voided = await scope.db.voidedOrdersInRange(
      store,
      start: start,
      end: end,
    );
    final orderIds = [...active.map((o) => o.id), ...voided.map((o) => o.id)];
    final items = await scope.db.orderItemsForOrders(orderIds);
    final payments = await scope.db.paymentsForOrders(orderIds);

    final pdf = ExportPdf.instance;
    final bytes = await pdf.build(
      storeName: storeName,
      periodLabel: periodLabel,
      activeOrders: active,
      voidedOrders: voided,
      items: items,
      payments: payments,
    );

    final stamp = DateTime.now().toUtc().toIso8601String().substring(0, 16);
    web.downloadFile('stardom-pos-report-$stamp.pdf', 'application/pdf', bytes);

    if (!mounted) return;
    setState(() => _exportingPdf = false);
    showSnack(context, 'Sales report downloaded ($_timeRange).');
  }

  Future<void> _exportCsv() async {
    final scope = PosScope.read(context);
    final store = scope.store;

    final now = DateTime.now().toUtc();
    final tz = await scope.db.tzOffsetMinutes(store);
    final localNow = BusinessDate.local(now, tzOffsetMinutes: tz);

    DateTime start;
    switch (_timeRange) {
      case 'day':
        start = BusinessDate.startOfDayUtc(localNow, tzOffsetMinutes: tz);
        break;
      case 'week':
        start = localNow.subtract(const Duration(days: 7));
        start = BusinessDate.startOfDayUtc(start, tzOffsetMinutes: tz);
        break;
      case 'month':
        start = localNow.subtract(const Duration(days: 30));
        start = BusinessDate.startOfDayUtc(start, tzOffsetMinutes: tz);
        break;
      case 'quarter':
        start = localNow.subtract(const Duration(days: 90));
        start = BusinessDate.startOfDayUtc(start, tzOffsetMinutes: tz);
        break;
      case 'all':
      default:
        start = DateTime.utc(2000, 1, 1);
    }
    final end = now.add(const Duration(days: 1));

    setState(() => _exportingPdf = true);

    final active = await scope.db.ordersInRange(store, start: start, end: end);
    final voided = await scope.db.voidedOrdersInRange(
      store,
      start: start,
      end: end,
    );
    final allOrders = [...active, ...voided];
    final orderIds = allOrders.map((o) => o.id).toList();
    final items = await scope.db.orderItemsForOrders(orderIds);
    final payments = await scope.db.paymentsForOrders(orderIds);
    final methods = await scope.db.listPaymentMethods(store);
    final methodById = {for (final m in methods) m.id: m.name};

    // Build CSV: one row per order item
    final lines = <String>[];
    lines.add(
      'order_no,date,status,product,quantity,unit_price,line_total,payment_method,reference_no,note,voided',
    );
    for (final o in allOrders) {
      final isVoid = voided.any((v) => v.id == o.id);
      final payment = payments.firstWhere(
        (p) => p.orderId == o.id,
        orElse: () => Payment(
          id: '',
          storeId: '',
          deviceId: '',
          orderId: o.id,
          methodId: '',
          methodName: 'Cash',
          methodType: 'cash',
          amount: o.total,
          referenceNo: '',
          createdAt: o.createdAt,
        ),
      );
      final methodName =
          methodById[payment.methodId ?? ''] ??
          (payment.methodName.isEmpty ? 'Cash' : payment.methodName);
      final orderItems = items.where((it) => it.orderId == o.id).toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      for (final it in orderItems) {
        lines.add(
          _csvCell(o.orderNo) +
              ',' +
              _csvCell(Fmt.date(o.createdAt) + ' ' + Fmt.time(o.createdAt)) +
              ',' +
              _csvCell(isVoid ? 'Voided' : 'Completed') +
              ',' +
              _csvCell(it.productName) +
              ',' +
              it.quantity.toString() +
              ',' +
              Fmt.peso(it.unitPrice).replaceAll('₱', '') +
              ',' +
              Fmt.peso(it.lineTotal).replaceAll('₱', '') +
              ',' +
              _csvCell(methodName) +
              ',' +
              _csvCell(o.referenceNo) +
              ',' +
              _csvCell(o.note) +
              ',' +
              isVoid.toString(),
        );
      }
      if (orderItems.isEmpty) {
        lines.add(
          _csvCell(o.orderNo) +
              ',' +
              _csvCell(Fmt.date(o.createdAt) + ' ' + Fmt.time(o.createdAt)) +
              ',' +
              _csvCell(isVoid ? 'Voided' : 'Completed') +
              ',' +
              _csvCell('') +
              ',0,0.00,0.00,' +
              _csvCell(methodName) +
              ',' +
              _csvCell(o.referenceNo) +
              ',' +
              _csvCell(o.note) +
              ',' +
              isVoid.toString(),
        );
      }
    }

    final csv = lines.join('\n');
    final stamp = DateTime.now().toUtc().toIso8601String().substring(0, 16);
    web.downloadFile(
      'stardom-pos-sales-$stamp.csv',
      'text/csv',
      utf8.encode(csv),
    );

    if (!mounted) return;
    setState(() => _exportingPdf = false);
    showSnack(context, 'Sales CSV downloaded ($_timeRange).');
  }

  String _csvCell(String v) {
    final needsQuote = v.contains(',') || v.contains('"') || v.contains('\n');
    if (!needsQuote) return v;
    return '"${v.replaceAll('"', '""')}"';
  }

  Future<void> _toggleSession() async {
    if (_signedIn) {
      final yes = await confirm(
        context,
        title: 'Sign out?',
        message:
            'Sales keep working on this device, but nothing syncs until the '
            'owner signs in again.',
        confirmLabel: 'Sign out',
      );
      if (!yes || !mounted) return;
      await OwnerAuth.instance.signOut();
      if (mounted) setState(() => _signedIn = false);
    } else {
      await Navigator.of(context)
          .push(MaterialPageRoute<void>(builder: (_) => const SignInScreen()));
      if (!mounted) return;
      setState(() => _signedIn = OwnerAuth.instance.signedIn);
      if (_signedIn) {
        // Immediately sync after a fresh sign-in — no need to wait for the
        // background tick.
        final scope = PosScope.read(context);
        await scope.sync.syncAll();
        if (mounted) showSnack(context, 'Signed in — data synced!');
      }
    }
  }

  /// Owner recovery: download EVERY table from the server again. Needed after
  /// the server data was wiped or rebuilt — a stale per-table pull cursor
  /// would otherwise hide re-created rows older than that cursor forever.
  Future<void> _rePullFromServer() async {
    final yes = await confirm(
      context,
      title: 'Fetch everything from the server again?',
      message:
          'Use this when the server data was wiped or rebuilt. Nothing '
          'on this device is deleted, and each table is downloaded from the '
          'start. Sales already here are kept and pushed back up.',
      confirmLabel: 'Fetch all',
    );
    if (!yes || !mounted) return;
    final scope = PosScope.read(context);
    setState(() => _repulling = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await scope.db.resetPullCursors(scope.store);
      // The dialog promises sales are "pushed back up" — a queue parked from
      // older rejections would silently ignore that, so give it fresh
      // attempts before the run that must carry it.
      await scope.db.resetOutboxAttempts(scope.store);
      if (!mounted) return;
      await scope.sync.syncAll();
      if (!mounted) return;
      final pending = await scope.db.pendingCount(scope.store);
      // Green only when EVERYTHING landed: empty queue AND no recorded
      // failure. Re-pull saying "Fetched everything" after a pull that
      // skipped rows would be the exact lie this screen exists to prevent.
      if (pending == 0 && scope.sync.lastSyncError == null) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text('Fetched everything from the server!'),
            backgroundColor: Color(0xFF2E7D32),
            duration: Duration(seconds: 3),
          ),
        );
      } else {
        // One shared sentence for every incomplete-sync entry point.
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
            content: Text('Re-pull failed: $e'),
            backgroundColor: AppColors.primary,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _repulling = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scope = PosScope.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: 12),
            child: Center(child: SyncChip()),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: Adaptive.formMax),
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.screen),
            children: [
              SectionCard(
                title: 'Shop',
                children: [
                  PosField(label: 'Shop name', controller: _name),
                  PosField(
                    label: 'Tagline',
                    controller: _tagline,
                    hint: 'Optional',
                  ),
                ],
              ),
              SectionCard(
                title: 'Receipt',
                children: [
                  PosField(
                    label: 'Receipt name',
                    controller: _receiptName,
                    hint: 'Defaults to the shop name',
                  ),
                  PosField(label: 'TIN', controller: _tin, hint: 'Optional'),
                  PosField(
                    label: 'Address',
                    controller: _address,
                    hint: 'Optional',
                  ),
                  PosField(
                    label: 'Accreditation',
                    controller: _accreditation,
                    hint: 'Optional',
                  ),
                  PosField(
                    label: 'Footer line',
                    controller: _footer,
                    hint: 'Printed under “Thank you!”',
                  ),
                  PosButton(
                    label: 'Save shop & receipt',
                    icon: AppIcons.check,
                    busy: _saving,
                    onPressed: _saveShop,
                  ),
                ],
              ),
              SectionCard(
                title: 'Selling setup',
                children: [
                  _LinkTile(
                    icon: AppIcons.cash,
                    title: 'Payment methods',
                    subtitle: 'Cash, GCash, GoTyme — QR codes and order',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const PaymentMethodsScreen(),
                      ),
                    ),
                  ),
                  _LinkTile(
                    icon: AppIcons.category,
                    title: 'Categories',
                    subtitle: 'The chips on the Sell screen',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const CategoriesScreen(),
                      ),
                    ),
                  ),
                  _LinkTile(
                    icon: AppIcons.discount,
                    title: 'Promo bundles',
                    subtitle: '“Any 4 stickers for ₱100” — edit the deals',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const BundleRulesScreen(),
                      ),
                    ),
                  ),
                ],
              ),
              SectionCard(
                title: 'This device',
                children: [
                  PosField(
                    label: 'Device name',
                    controller: _deviceName,
                    onSubmitted: (_) => _renameDevice(),
                  ),
                  PosButton(
                    label: 'Rename device',
                    icon: AppIcons.device,
                    variant: PosButtonVariant.quiet,
                    onPressed: _renameDevice,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  _LinkTile(
                    icon: AppIcons.history,
                    title: 'All devices',
                    subtitle:
                        'Every booth row this shop keeps — deactivate the '
                        'stale ones',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const DevicesScreen(),
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  DetailRow('Storage', _storageMode),
                  DetailRow(
                    'Persistent storage',
                    '$_persisted (browser: ${scope.opened.persistent ? 'yes' : 'no'})',
                  ),
                  // The browser said no at boot (WebKit evicts a
                  // non-persistent origin — sales included). Asking again
                  // needs a fresh gesture, so the button IS the gesture.
                  if (_persisted != 'yes') ...[
                    const SizedBox(height: AppSpacing.sm),
                    PosButton(
                      label: 'Allow persistent storage',
                      icon: AppIcons.warning,
                      variant: PosButtonVariant.quiet,
                      busy: _persisting,
                      onPressed: _retryPersist,
                    ),
                  ],
                  // Proof of the localStorage mirror: what was last written, and
                  // what came back at launch. Read live so it is current when
                  // this screen is on top.
                  DetailRow('Local backup', LocalBackup.status),
                  DetailRow(
                    'Images cached offline',
                    '$_imageCount (${(_imageBytes / 1024).round()} KB)',
                  ),
                  if (_missing.isNotEmpty)
                    DetailRow('Browser limits', _missing.join(', ')),
                  const SizedBox(height: AppSpacing.sm),
                  _LinkTile(
                    icon: AppIcons.key,
                    title: 'Void PIN',
                    subtitle: _voidPinOn
                        ? 'On — asked before every void'
                        : 'Off — voids ask only for a reason',
                    onTap: () => _editVoidPin(),
                  ),
                ],
              ),
              SectionCard(
                title: 'Sync',
                children: [
                  DetailRow(
                    'Session',
                    Api.instance.isReady
                        ? (_signedIn
                              ? 'signed in — syncing when online'
                              : 'not signed in — selling still works')
                        : 'sync not configured on this build',
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  PosButton(
                    label: 'Sync now',
                    icon: AppIcons.sync,
                    onPressed: () => scope.sync.syncAll(),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  PosButton(
                    label: 'Re-pull from server',
                    icon: AppIcons.refresh,
                    variant: PosButtonVariant.quiet,
                    busy: _repulling,
                    onPressed: _rePullFromServer,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  PosButton(
                    label: 'Sync details',
                    icon: AppIcons.history,
                    variant: PosButtonVariant.ghost,
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const SyncDetailsScreen(),
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  if (Api.instance.isReady)
                    PosButton(
                      label: _signedIn ? 'Sign out' : 'Sign in to sync',
                      icon: _signedIn ? AppIcons.logout : AppIcons.sync,
                      variant: PosButtonVariant.quiet,
                      onPressed: _toggleSession,
                    ),
                ],
              ),
              SectionCard(
                title: 'Backup & export',
                children: [
                  Text(
                    'Downloads the whole database — products, sales, day closes — '
                    'as one JSON file. Keep a copy at the end of every month.',
                    style: jakarta(12.5, color: AppColors.inkSoft),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  PosButton(
                    label: 'Export data (JSON)',
                    icon: AppIcons.upload,
                    variant: PosButtonVariant.ghost,
                    onPressed: _exportData,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    'Sales report (PDF)',
                    style: jakarta(
                      11,
                      weight: FontWeight.w800,
                      color: AppColors.inkSoft,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Wrap(
                    spacing: AppSpacing.xs,
                    runSpacing: AppSpacing.xs,
                    children: [
                      for (var i = 0; i < _timeRangeLabels.length; i++)
                        _TimeRangeChip(
                          label: _timeRangeLabels[i],
                          value: _timeRangeValues[i],
                          selected: _timeRange == _timeRangeValues[i],
                          onTap: (v) => setState(() => _timeRange = v),
                        ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  PosButton(
                    label: 'Export data (PDF)',
                    icon: AppIcons.pictureAsPdf,
                    variant: PosButtonVariant.ghost,
                    busy: _exportingPdf,
                    onPressed: _exportPdf,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  PosButton(
                    label: 'Export sales (CSV)',
                    icon: AppIcons.tableView,
                    variant: PosButtonVariant.ghost,
                    busy: _exportingPdf,
                    onPressed: _exportCsv,
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.xl),
            ],
          ),
        ),
      ),
    );
  }
}

/// Settings → SYNC DETAILS.
///
/// The W2 data-loss guard, in full: how many sales are waiting, how long the
/// oldest has waited, why anything failed, and a retry that does not punish
/// the whole queue.
class SyncDetailsScreen extends StatefulWidget {
  const SyncDetailsScreen({super.key});

  @override
  State<SyncDetailsScreen> createState() => _SyncDetailsScreenState();
}

class _SyncDetailsScreenState extends State<SyncDetailsScreen> {
  List<SyncOutboxData> _pending = const [];
  bool _signedIn = false;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _signedIn = OwnerAuth.instance.signedIn;
    _load();
  }

  Future<void> _load() async {
    final scope = PosScope.read(context);
    final pending = await scope.db.pendingOutbox(scope.store);
    if (!mounted) return;
    setState(() => _pending = pending);
  }

  static String _human(Duration d) {
    if (d.inHours >= 24) return '${d.inDays}d ${d.inHours % 24}h';
    if (d.inHours >= 1) return '${d.inHours}h ${d.inMinutes % 60}m';
    return '${d.inMinutes}m';
  }

  @override
  Widget build(BuildContext context) {
    final scope = PosScope.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sync details'),
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: 12),
            child: Center(child: SyncChip()),
          ),
        ],
      ),
      body: ValueListenableBuilder<SyncSummary>(
        valueListenable: scope.status,
        builder: (context, summary, _) {
          final stale = summary.isStale(const Duration(hours: 24));
          return ListView(
            padding: const EdgeInsets.all(AppSpacing.screen),
            children: [
              if (stale)
                const Padding(
                  padding: EdgeInsets.only(bottom: AppSpacing.md),
                  child: PosAlert.err(
                    text:
                        'Unsynced sales on this device for over a day. Connect '
                        'to the internet and tap Sync now. Do not delete the '
                        'app icon.',
                  ),
                ),
              SectionCard(
                title: 'Outbox',
                children: [
                  DetailRow('Waiting to send', '${summary.pending}'),
                  DetailRow(
                    'Oldest waiting',
                    summary.oldest == null ? '—' : _human(summary.oldest!),
                  ),
                  DetailRow(
                    'Session',
                    _signedIn ? 'signed in' : 'not signed in',
                  ),
                  if (!_signedIn && Api.instance.isReady)
                    Padding(
                      padding: const EdgeInsets.only(top: AppSpacing.sm),
                      child: PosAlert.info(
                        text:
                            'Selling works signed out — sign in to let these '
                            'sales reach the shop.',
                      ),
                    ),
                ],
              ),
              SectionCard(
                title: 'Sales waiting (${_pending.length})',
                children: _pending.isEmpty
                    ? [
                        Text(
                          'Nothing waiting — everything on this device has '
                          'reached the shop.',
                          style: jakarta(13, color: AppColors.inkSoft),
                        ),
                      ]
                    : [
                        for (final e in _pending)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        e.entity,
                                        style: sora(
                                          13,
                                          weight: FontWeight.w700,
                                        ),
                                      ),
                                      if (e.lastError != null)
                                        Text(
                                          e.lastError!,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: jakarta(
                                            11.5,
                                            color: AppColors.failedText,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                if (e.lastError != null)
                                  PosButton(
                                    label: 'Retry',
                                    expanded: false,
                                    height: 40,
                                    variant: PosButtonVariant.quiet,
                                    onPressed: () async {
                                      await scope.db.retryOutbox(e.id);
                                      await scope.sync.syncAll();
                                      await _load();
                                    },
                                  ),
                              ],
                            ),
                          ),
                      ],
              ),
              const SizedBox(height: AppSpacing.sm),
              PosButton(
                label: 'Sync now',
                icon: AppIcons.sync,
                onPressed: () async {
                  await scope.sync.syncAll();
                  await _load();
                },
              ),
            ],
          );
        },
      ),
    );
  }
}

class _LinkTile extends StatelessWidget {
  const _LinkTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.m),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Icon(icon, size: 20, color: AppColors.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: sora(14, weight: FontWeight.w700)),
                  Text(subtitle, style: jakarta(12, color: AppColors.inkSoft)),
                ],
              ),
            ),
            const Icon(
              Icons.chevron_right,
              size: 22,
              color: AppColors.inkFaint,
            ),
          ],
        ),
      ),
    );
  }
}

/// Time-range chips for the PDF export. Value is stored in [_timeRange].
const List<String> _timeRangeLabels = <String>[
  'Past day',
  'Past 7 days',
  'Past 30 days',
  'Past 90 days',
  'All time',
];

const List<String> _timeRangeValues = <String>[
  'day',
  'week',
  'month',
  'quarter',
  'all',
];

/// One pill chip in the export time-range row.
class _TimeRangeChip extends StatelessWidget {
  const _TimeRangeChip({
    required this.label,
    required this.value,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String value;
  final bool selected;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    return FilterChip(
      label: Text(
        label,
        style: sora(
          11.5,
          weight: FontWeight.w800,
          color: selected ? AppColors.onPrimary : AppColors.inkSoft,
        ),
      ),
      selected: selected,
      onSelected: (_) => onTap(value),
      backgroundColor: AppColors.card,
      selectedColor: AppColors.primary,
      checkmarkColor: AppColors.onPrimary,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.pill),
        side: BorderSide(color: selected ? AppColors.primary : AppColors.line),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }
}
