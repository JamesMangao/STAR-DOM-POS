import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;

import '../core/format.dart';
import '../core/icons.dart';
import '../core/tokens.dart';
import '../core/web_apis.dart' as web;
import '../data/db.dart';
import '../data/logic.dart';
import '../data/printing.dart';
import 'adaptive.dart';
import 'scope.dart';
import 'security.dart';
import 'widgets.dart';

/// Screen 05 — RECEIPT.
///
/// The 80 mm paper as the cashier will hold it: store block, dashed cut lines,
/// the sold lines, the money, and the PAID stamp the design calls for. One
/// screen serves two moments — the fresh sale (Print / Share / New Sale) and
/// the order opened from Orders (same paper, plus Void).
class ReceiptScreen extends StatefulWidget {
  const ReceiptScreen({
    super.key,
    required this.order,
    this.freshSale = false,
    this.canVoid = false,
  });

  final Order order;

  /// True when this receipt replaces the cart → payment → receipt flow: the
  /// sale banner and the New Sale button appear.
  final bool freshSale;

  /// True when opened from Orders: the Void action is offered (until the
  /// order carries a void row).
  final bool canVoid;

  @override
  State<ReceiptScreen> createState() => _ReceiptScreenState();
}

class _ReceiptScreenState extends State<ReceiptScreen> {
  final _paperKey = GlobalKey();

  List<OrderItem> _items = const [];
  Payment? _payment;
  Store? _store;
  Device? _device;
  OrderChip _chip = OrderChip.pending;
  bool _voided = false;
  bool _loading = true;
  bool _started = false;
  bool _busy = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _load();
  }

  Future<void> _load() async {
    final scope = PosScope.read(context);
    final order = widget.order;
    final items = await scope.db.orderItemsOf(order.id);
    final payment = await scope.db.paymentOf(order.id);
    final store = await scope.db.store(scope.store);
    final device = await scope.db.deviceById(order.deviceId);
    final voided = await scope.db.isVoided(order.id);
    final chip = await scope.db.chipFor(order);
    if (!mounted) return;
    setState(() {
      _items = items;
      _payment = payment;
      _store = store;
      _device = device;
      _voided = voided;
      _chip = chip;
      _loading = false;
    });
  }

  @override
  void dispose() {
    super.dispose();
  }

  /// The paper data class the PDF printer and this preview SHARE, so the print
  /// can never show a different receipt than the screen.
  Receipt _paper() {
    final order = widget.order;
    final s = _store;
    return Receipt(
      storeName: s?.name ?? 'STAR:DOM',
      tagline: s?.tagline ?? '',
      receiptName: s?.receiptName ?? '',
      tin: s?.receiptTin ?? '',
      address: s?.receiptAddress ?? '',
      accreditation: s?.receiptAccreditation ?? '',
      footer: s?.receiptFooter ?? '',
      orderNo: order.orderNo,
      createdAt: order.createdAt.toLocal(),
      deviceName: _device?.deviceName ?? '',
      lines: [
        for (final it in _items)
          ReceiptLine(
            name: it.productName,
            quantity: it.quantity,
            unitPrice: it.unitPrice,
            lineTotal: it.lineTotal,
          ),
      ],
      subtotal: order.subtotal,
      discount: order.discount,
      total: order.total,
      paymentLabel: _payment?.methodName ?? '',
      amountReceived: order.amountReceived,
      change: order.changeAmount,
      referenceNo: order.referenceNo,
      note: order.note,
      voided: _voided,
    );
  }

  Future<void> _run(Future<void> Function() action, String failMessage) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (_) {
      if (mounted) showSnack(context, failMessage, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _print() => _run(
    () => PdfPrinter().print(_paper()),
    'Could not open the print sheet.',
  );

  Future<void> _sharePdf() => _run(() async {
    await _showPreview('PDF');
    await ShareReceiptPrinter().print(_paper());
  }, 'Could not share the receipt PDF.');

  /// Share as a picture: the preview rendered to a PNG at 3×, handed to the
  /// share sheet exactly like the PDF.
  Future<void> _sharePicture() => _run(() async {
    await _showPreview('picture');
    final ok = await web.shareFile(
      '${widget.order.orderNo}.png',
      'image/png',
      await _renderPaperPng(),
    );
    if (!ok) throw StateError('no share target');
  }, 'Could not share the receipt picture.');

  /// Save as a picture: the same 3× render, straight into a browser
  /// download — on iPad/iPhone Safari that lands in Files → Downloads and
  /// iOS offers "Save to Photos" from there. No share sheet, no dialog.
  Future<void> _savePicture() => _run(() async {
    web.downloadFile(
      '${widget.order.orderNo}.png',
      'image/png',
      await _renderPaperPng(),
    );
    showSnack(context, 'Receipt picture saved — check your downloads.');
  }, 'Could not save the receipt picture.');

  /// The paper at 3× as PNG bytes — one render both handouts SHARE, so the
  /// shared picture and the saved picture can never differ.
  Future<Uint8List> _renderPaperPng() async {
    final boundary =
        _paperKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null) throw StateError('paper not rendered');
    final image = await boundary.toImage(pixelRatio: 3);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) throw StateError('no png');
    return bytes.buffer.asUint8List();
  }

  /// Show a preview confirmation before sharing, so the cashier can confirm
  /// the receipt looks right before it leaves the device.
  Future<void> _showPreview(String format) async {
    final yes = await confirm(
      context,
      title: 'Preview receipt before sharing?',
      message:
          'Share this receipt as a $format. Check the paper above — once '
          'shared it cannot be taken back.',
      confirmLabel: 'Share $format',
    );
    if (!yes || !mounted) return;
  }

  /// Void asks for the booth PIN (when the owner set one), then a reason —
  /// the server keeps the reason with the void row.
  Future<void> _void() async {
    final scope = PosScope.read(context);
    if (!await voidPinAllowed(context, scope.db, scope.store)) return;
    final reason = await askVoidReason(context);
    if (reason == null || reason.isEmpty || !mounted) return;
    final device = await scope.devices.ensureRegistered(scope.store);
    final outcome = await scope.db.voidOrder(
      widget.order.id,
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

  // The shared top-level actions live at the bottom of this file — see
  // [askVoidReason] / [buildOrderReceipt] / [shareOrderPdf].

  void _newSale() => Navigator.of(context).popUntil((r) => r.isFirst);

  @override
  Widget build(BuildContext context) {
    final order = widget.order;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Receipt'),
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: 12),
            child: Center(child: SyncChip()),
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
                    if (widget.freshSale)
                      Padding(
                        padding: const EdgeInsets.only(bottom: AppSpacing.md),
                        child: PosAlert.ok(
                          text:
                              'Sale saved — order ${order.orderNo}. The chip in '
                              'the corner shows when it reaches the shop.',
                        ),
                      ),
                    Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 380),
                        child: Column(
                          children: [
                            _StatusRow(chip: _chip, voided: _voided),
                            const SizedBox(height: AppSpacing.md),
                            _Paper(receipt: _paper(), paperKey: _paperKey),
                            const SizedBox(height: AppSpacing.lg),
                            PosButton(
                              label: 'Print receipt',
                              icon: AppIcons.print,
                              busy: _busy,
                              onPressed: _print,
                            ),
                            const SizedBox(height: AppSpacing.sm),
                            Row(
                              children: [
                                Expanded(
                                  child: PosButton(
                                    label: 'Share PDF',
                                    icon: AppIcons.share,
                                    variant: PosButtonVariant.ghost,
                                    busy: _busy,
                                    onPressed: _sharePdf,
                                  ),
                                ),
                                const SizedBox(width: AppSpacing.sm),
                                Expanded(
                                  child: PosButton(
                                    label: 'Share picture',
                                    icon: AppIcons.image,
                                    variant: PosButtonVariant.ghost,
                                    busy: _busy,
                                    onPressed: _sharePicture,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: AppSpacing.sm),
                            PosButton(
                              label: 'Save picture to gallery',
                              icon: AppIcons.image,
                              variant: PosButtonVariant.quiet,
                              busy: _busy,
                              onPressed: _savePicture,
                            ),
                            if (widget.canVoid && !_voided) ...[
                              const SizedBox(height: AppSpacing.sm),
                              PosButton(
                                label: 'Void order',
                                icon: AppIcons.delete,
                                variant: PosButtonVariant.danger,
                                onPressed: _void,
                              ),
                            ],
                            if (widget.freshSale) ...[
                              const SizedBox(height: AppSpacing.md),
                              PosButton(
                                label: 'New Sale',
                                icon: AppIcons.sell,
                                onPressed: _newSale,
                              ),
                            ],
                            const SizedBox(height: AppSpacing.xl),
                          ],
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

/// Pending / Synced / Failed / Voided — the same badge the Orders list shows.
class _StatusRow extends StatelessWidget {
  const _StatusRow({required this.chip, required this.voided});

  final OrderChip chip;
  final bool voided;

  @override
  Widget build(BuildContext context) {
    final (label, kind) = switch (chip) {
      OrderChip.voided => ('Voided', BadgeKind.voided),
      OrderChip.failed => ('Sync failed', BadgeKind.failed),
      OrderChip.pending => ('Pending sync', BadgeKind.pending),
      OrderChip.synced => ('Synced', BadgeKind.synced),
    };
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        StatusBadge(label, kind: kind),
        if (voided && chip != OrderChip.voided) ...[
          const SizedBox(width: AppSpacing.sm),
          const StatusBadge('Voided', kind: BadgeKind.voided),
        ],
      ],
    );
  }
}

/// The 80 mm-style paper: store block, dashed cut lines, sold lines, money and
/// the PAID stamp. Wrapped in a [RepaintBoundary] so "Share picture" can
/// render exactly this widget.
class _Paper extends StatelessWidget {
  const _Paper({required this.receipt, required this.paperKey});

  final Receipt receipt;
  final GlobalKey paperKey;

  @override
  Widget build(BuildContext context) {
    final r = receipt;
    return RepaintBoundary(
      key: paperKey,
      child: Container(
        width: 340,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 22),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(AppRadius.l),
          border: Border.all(color: AppColors.line),
          boxShadow: AppShadows.sh2,
        ),
        child: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // The brand, first thing on the paper: the clean STAR:DOM
                // wordmark. Bundled, never fetched — the receipt must print
                // with no signal.
                // The collab lockup on paper: the STAR:DOM wordmark, the
                // partner mark beside it. Both bundled, never fetched — the
                // receipt must print with no signal.
                Center(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Image.asset(
                        'assets/stardom-logo.webp',
                        height: 30,
                        fit: BoxFit.contain,
                        filterQuality: FilterQuality.medium,
                        errorBuilder: (context, error, stackTrace) =>
                            const SizedBox.shrink(),
                      ),
                      const SizedBox(width: 8),
                      Text('×', style: jakarta(11, weight: FontWeight.w700)),
                      const SizedBox(width: 8),
                      Image.asset(
                        'assets/ka1ofakind.png',
                        height: 30,
                        fit: BoxFit.contain,
                        filterQuality: FilterQuality.medium,
                        errorBuilder: (context, error, stackTrace) =>
                            const SizedBox.shrink(),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Center(
                  child: Text(
                    r.receiptName.isEmpty ? r.storeName : r.receiptName,
                    textAlign: TextAlign.center,
                    style: sora(15, weight: FontWeight.w800),
                  ),
                ),
                if (r.tagline.isNotEmpty)
                  Center(
                    child: Text(
                      r.tagline,
                      textAlign: TextAlign.center,
                      style: jakarta(11, color: AppColors.inkSoft),
                    ),
                  ),
                if (r.tin.isNotEmpty)
                  Center(
                    child: Text(
                      'TIN: ${r.tin}',
                      style: mono(
                        10,
                        weight: FontWeight.w400,
                        color: AppColors.inkSoft,
                      ),
                    ),
                  ),
                if (r.address.isNotEmpty)
                  Center(
                    child: Text(
                      r.address,
                      textAlign: TextAlign.center,
                      style: mono(
                        10,
                        weight: FontWeight.w400,
                        color: AppColors.inkSoft,
                      ),
                    ),
                  ),
                if (r.accreditation.isNotEmpty)
                  Center(
                    child: Text(
                      r.accreditation,
                      textAlign: TextAlign.center,
                      style: mono(
                        10,
                        weight: FontWeight.w400,
                        color: AppColors.inkSoft,
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
                const _Dash(),
                const SizedBox(height: 6),
                Center(
                  child: Text(
                    Receipt.title,
                    style: mono(11, weight: FontWeight.w700),
                  ),
                ),
                if (r.voided)
                  Center(
                    child: Text(
                      '*** VOID ***',
                      style: sora(
                        14,
                        weight: FontWeight.w800,
                        color: AppColors.primary,
                      ),
                    ),
                  ),
                const SizedBox(height: 4),
                _kv('Order', r.orderNo, mono: true),
                _kv(
                  'Date',
                  '${Fmt.date(r.createdAt)} ${Fmt.time(r.createdAt)}',
                ),
                if (r.deviceName.isNotEmpty) _kv('Device', r.deviceName),
                const SizedBox(height: 6),
                const _Dash(),
                const SizedBox(height: 6),
                for (final l in r.lines) ...[
                  Text(l.name, style: jakarta(12, weight: FontWeight.w600)),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '  ${l.quantity} × ${l.unitLabel}',
                          style: mono(
                            11,
                            weight: FontWeight.w400,
                            color: AppColors.inkSoft,
                          ),
                        ),
                        Text(
                          l.totalLabel,
                          style: mono(12, weight: FontWeight.w700),
                        ),
                      ],
                    ),
                  ),
                ],
                const _Dash(),
                const SizedBox(height: 6),
                if (r.subtotal != null) _kv('Subtotal', Fmt.peso(r.subtotal!)),
                if (r.discount > 0) _kv('Discount', '-${Fmt.peso(r.discount)}'),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('TOTAL', style: sora(14, weight: FontWeight.w800)),
                      Text(
                        Fmt.peso(r.total),
                        style: sora(16, weight: FontWeight.w800),
                      ),
                    ],
                  ),
                ),
                if (r.paymentLabel.isNotEmpty) _kv('Paid via', r.paymentLabel),
                if (r.amountReceived != null)
                  _kv('Received', Fmt.peso(r.amountReceived!)),
                if (r.change != null) _kv('Change', Fmt.peso(r.change!)),
                if (r.referenceNo.isNotEmpty)
                  _kv('Reference', r.referenceNo, mono: true),
                if (r.note.isNotEmpty) _kv('Note', r.note),
                const SizedBox(height: 6),
                const _Dash(),
                if (r.footer.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      r.footer,
                      textAlign: TextAlign.center,
                      style: jakarta(10, color: AppColors.inkSoft),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'Thank you!',
                    textAlign: TextAlign.center,
                    style: jakarta(11, weight: FontWeight.w700),
                  ),
                ),
                const SizedBox(height: 4),
              ],
            ),
            if (!r.voided)
              Positioned(
                // +40 for the wordmark above: the stamp keeps its old spot
                // beside the TIN/address block instead of the logo.
                top: 74,
                right: 0,
                child: _PaidStamp(),
              ),
          ],
        ),
      ),
    );
  }

  static Widget _kv(String k, String v, {bool mono = false}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(k, style: _label),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            v,
            textAlign: TextAlign.right,
            style: mono ? _valueMono : _value,
          ),
        ),
      ],
    ),
  );
}

const _label = TextStyle(
  fontFamily: 'Consolas',
  fontFamilyFallback: ['Courier New', 'monospace'],
  fontSize: 10,
  color: AppColors.inkSoft,
);

const _value = TextStyle(
  fontFamily: 'PlusJakartaSans',
  fontSize: 11,
  fontWeight: FontWeight.w600,
  color: AppColors.ink,
);

const _valueMono = TextStyle(
  fontFamily: 'Consolas',
  fontFamilyFallback: ['Courier New', 'monospace'],
  fontSize: 10,
  fontWeight: FontWeight.w700,
  color: AppColors.ink,
);

/// The PAID stamp — one-shot SLAM when the receipt lands (scale 2.2 → 1.0
/// with a back-curve impact squash and a rotation settle, ~180 ms), then
/// completely static. This is the app's single orchestrated moment: the old
/// version breathed forever, which distracted from the receipt and burned
/// cycles on the booth's A13 for nothing. Reduced motion → it simply appears.
class _PaidStamp extends StatefulWidget {
  const _PaidStamp();

  @override
  State<_PaidStamp> createState() => _PaidStampState();
}

class _PaidStampState extends State<_PaidStamp>
    with SingleTickerProviderStateMixin {
  late final AnimationController _slam;

  @override
  void initState() {
    super.initState();
    _slam = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    );
    // Post-frame so reading posMotion(context) is legal; normal motion plays
    // the slam, reduced motion jumps straight to the settled stamp.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (posMotion(context)) {
        _slam.forward();
      } else {
        _slam.value = 1;
      }
    });
  }

  @override
  void dispose() {
    _slam.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _slam,
    builder: (context, child) {
      // easeOutBack briefly overshoots past 1 → the scale dips just below
      // final size (the impact squash) before settling at exactly 1.0.
      final t = Curves.easeOutBack.transform(_slam.value);
      final scale = 2.2 - (1.2 * t);
      final angle = -0.21 + ((1 - _slam.value) * 0.6);
      final opacity = 0.7 + (0.25 * _slam.value);
      return Transform.scale(
        scale: scale,
        child: Transform.rotate(
          angle: angle,
          child: Opacity(opacity: opacity, child: child),
        ),
      );
    },
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.primary, width: 2.5),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        'PAID',
        style: sora(
          20,
          weight: FontWeight.w800,
          color: AppColors.primary,
          letterSpacing: 2,
        ),
      ),
    ),
  );
}

/// The dashed cut line on the paper.
class _Dash extends StatelessWidget {
  const _Dash();

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 9,
    child: CustomPaint(
      size: const Size(double.infinity, 9),
      painter: _DashPainter(),
    ),
  );
}

class _DashPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = AppColors.lineHi
      ..strokeWidth = 1;
    const dash = 4.0, gap = 4.0;
    for (double x = 0; x < size.width; x += dash + gap) {
      canvas.drawLine(
        Offset(x, size.height / 2),
        Offset(x + dash, size.height / 2),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ---------------------------------------------------------------------------
// Shared actions — used by the Receipt screen AND the Orders long-press menu,
// so the two paths can never drift apart.
// ---------------------------------------------------------------------------

/// The reason dialog every void shares — the server keeps it with the void
/// row. The caller supplies the PIN gate before this.
Future<String?> askVoidReason(BuildContext context) async {
  final controller = TextEditingController();
  final reason = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.xl),
        side: const BorderSide(color: AppColors.lineHi),
      ),
      title: Text('Void this order?', style: sora(18, weight: FontWeight.w800)),
      content: TextField(
        controller: controller,
        style: jakarta(16, weight: FontWeight.w500),
        decoration: const InputDecoration(
          labelText: 'Reason',
          hintText: 'e.g. wrong item, customer changed mind',
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: Text('Cancel', style: sora(13, color: AppColors.inkSoft)),
        ),
        PosButton(
          label: 'Void order',
          expanded: false,
          height: 44,
          variant: PosButtonVariant.danger,
          onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
        ),
      ],
    ),
  );
  controller.dispose();
  return reason;
}

/// The paper data class for one order, built straight from the local tables.
/// The Orders long-press menu uses it to share a receipt without opening the
/// Receipt screen, so the shared PDF can never differ from the printed one.
Future<Receipt> buildOrderReceipt(
  AppDatabase db,
  String storeId,
  Order order,
) async {
  final items = await db.orderItemsOf(order.id);
  final payment = await db.paymentOf(order.id);
  final store = await db.store(storeId);
  final device = await db.deviceById(order.deviceId);
  final voided = await db.isVoided(order.id);
  final s = store;
  return Receipt(
    storeName: s?.name ?? 'STAR:DOM',
    tagline: s?.tagline ?? '',
    receiptName: s?.receiptName ?? '',
    tin: s?.receiptTin ?? '',
    address: s?.receiptAddress ?? '',
    accreditation: s?.receiptAccreditation ?? '',
    footer: s?.receiptFooter ?? '',
    orderNo: order.orderNo,
    createdAt: order.createdAt.toLocal(),
    deviceName: device?.deviceName ?? '',
    lines: [
      for (final it in items)
        ReceiptLine(
          name: it.productName,
          quantity: it.quantity,
          unitPrice: it.unitPrice,
          lineTotal: it.lineTotal,
        ),
    ],
    subtotal: order.subtotal,
    discount: order.discount,
    total: order.total,
    paymentLabel: payment?.methodName ?? '',
    amountReceived: order.amountReceived,
    change: order.changeAmount,
    referenceNo: order.referenceNo,
    note: order.note,
    voided: voided,
  );
}

/// Share one order's receipt as PDF, straight from anywhere (Orders
/// long-press). The same preview-confirm step the Receipt screen runs before
/// anything leaves the device.
Future<void> shareOrderPdf(BuildContext context, Order order) async {
  final scope = PosScope.read(context);
  final yes = await confirm(
    context,
    title: 'Preview receipt before sharing?',
    message:
        'Share the receipt PDF for ${order.orderNo}. Once shared it cannot '
        'be taken back.',
    confirmLabel: 'Share PDF',
  );
  if (!yes || !context.mounted) return;
  final receipt = await buildOrderReceipt(scope.db, scope.store, order);
  try {
    await ShareReceiptPrinter().print(receipt);
  } catch (_) {
    if (context.mounted) {
      showSnack(context, 'Could not share the receipt PDF.', error: true);
    }
  }
}
