import 'dart:async';

import 'package:flutter/material.dart';

import '../core/format.dart';
import '../core/icons.dart';
import '../core/tokens.dart';
import '../data/auth.dart';
import '../data/db.dart';
import '../data/logic.dart';
import 'adaptive.dart';
import 'receipt.dart';
import 'scope.dart';
import 'widgets.dart';

/// Creates the sale for BOTH payment screens and clears the cart.
///
/// Returns the created order, or a message to show the cashier. The device
/// code rule (B7) is enforced here, once: a sale cannot be written without a
/// server-assigned device code, because `order_no` is built from it and a
/// collision would never resolve.
Future<(Order?, String?)> submitSale(
  BuildContext context, {
  required PaymentMethod method,
  double? amountReceived,
  double? changeAmount,
  String referenceNo = '',
}) async {
  final scope = PosScope.read(context);
  final cart = scope.cart;
  if (cart.isEmpty) return (null, 'The cart is empty — nothing to charge.');

  try {
    var device = await scope.devices.ensureRegistered(scope.store);
    if (device.deviceCode.isEmpty) {
      await scope.devices.registerWithServer(storeId: scope.store);
      final refreshed = scope.devices.current;
      if (refreshed == null || refreshed.deviceCode.isEmpty) {
        return (
          null,
          OwnerAuth.instance.signedIn
              ? 'This device has no device code yet — the shop server '
                    'issues one so order numbers can never collide. Connect '
                    'to the internet and tap Sync in Settings, then try again.'
              : 'This booth is not signed in yet, so the shop server cannot '
                    'give it a device code. Sign in once — Settings → Sign '
                    'in to sync — and this sale will go through.',
        );
      }
      device = refreshed;
    }

    // The lines are frozen as order rows; `createOrder` snapshots name and
    // price again and allocates the order_no inside its transaction.
    final items = [
      for (final l in cart.lines)
        OrderItem(
          id: '',
          orderId: '',
          productId: l.productId,
          productName: l.name,
          unitPrice: l.unitPrice,
          quantity: l.quantity,
          lineTotal: l.lineTotal,
          createdAt: DateTime.now().toUtc(),
        ),
    ];

    // The bundle deals are part of the money: what they save is the order's
    // discount, and the order note says which deal did it, so the receipt
    // and the reports can explain the price later.
    final bundleNote = cart.bundleSummary.join('; ');
    final note = [
      cart.note,
      if (bundleNote.isNotEmpty) 'Bundle: $bundleNote',
    ].where((n) => n.isNotEmpty).join(' · ');

    final order = await scope.db.createOrder(
      storeId: scope.store,
      deviceId: device.id,
      subtotal: cart.subtotal,
      discount: cart.totalDiscount,
      total: cart.total,
      note: note,
      paymentMethodId: method.id,
      amountReceived: amountReceived,
      changeAmount: changeAmount,
      referenceNo: referenceNo,
      items: items,
    );

    // The sale is on disk before anything else runs: the push is best-effort
    // and the sync chip tells the cashier the truth either way.
    cart.clear();
    unawaited(scope.sync.syncAll());
    return (order, null);
  } catch (e) {
    return (null, 'The sale could not be saved: $e');
  }
}

void _openReceipt(BuildContext context, Order order) {
  Navigator.of(context).pushAndRemoveUntil(
    MaterialPageRoute<void>(
      builder: (_) => ReceiptScreen(order: order, freshSale: true),
    ),
    (route) => route.isFirst,
  );
}

// ---------------------------------------------------------------- cash ------

/// Screen 03 — CASH.
///
/// Amount due, quick notes, a 3 × 4 keypad and the change, computed as every
/// key is pressed (cent-exact). Complete Sale stays off until the amount
/// received covers the total.
class CashPaymentScreen extends StatefulWidget {
  const CashPaymentScreen({super.key, required this.method});

  final PaymentMethod method;

  @override
  State<CashPaymentScreen> createState() => _CashPaymentScreenState();
}

class _CashPaymentScreenState extends State<CashPaymentScreen> {
  static const _keys = [
    '1',
    '2',
    '3',
    '4',
    '5',
    '6',
    '7',
    '8',
    '9',
    '.',
    '0',
    '⌫',
  ];

  /// What the cashier has typed. Kept as text so `12.` and `0.5` work.
  String _typed = '';
  bool _busy = false;
  String? _error;

  /// Captured once, on open: the cart is cleared the moment the sale is
  /// written, and the receipt transition must not flicker a zero total.
  double _due = 0;
  bool _emptyCart = false;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final cart = PosScope.read(context).cart;
    _due = cart.total;
    _emptyCart = cart.isEmpty;
  }

  double get _received => Money.round(double.tryParse(_typed) ?? 0);
  double get _change => ChangeCalc.compute(due: _due, received: _received);
  bool get _covers => ChangeCalc.canComplete(due: _due, received: _received);

  void _onKey(String k) {
    setState(() {
      _error = null;
      if (k == '⌫') {
        if (_typed.isNotEmpty) _typed = _typed.substring(0, _typed.length - 1);
      } else if (k == '.') {
        if (!_typed.contains('.') && _typed.length < 11) {
          _typed = _typed.isEmpty ? '0.' : '$_typed.';
        }
      } else if (_typed.length < 12) {
        _typed = '$_typed$k';
      }
    });
  }

  Future<void> _complete() async {
    if (!_covers || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final (order, error) = await submitSale(
      context,
      method: widget.method,
      amountReceived: _received,
      changeAmount: _change,
    );
    if (!mounted) return;
    if (order == null) {
      setState(() {
        _busy = false;
        _error = error;
      });
      return;
    }
    _openReceipt(context, order);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Cash · ${widget.method.name}'),
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: 12),
            child: Center(child: SyncChip()),
          ),
        ],
      ),
      body: _emptyCart
          ? const EmptyState(
              icon: AppIcons.cash,
              title: 'The cart is empty',
              message: 'Go back and add products before taking a payment.',
            )
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: Adaptive.formMax),
                child: Column(
                  children: [
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.all(AppSpacing.screen),
                        children: [
                          SectionCard(
                            title: 'Amount due',
                            children: [
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    widget.method.name.toUpperCase(),
                                    style: sora(
                                      11,
                                      weight: FontWeight.w800,
                                      color: AppColors.inkSoft,
                                      letterSpacing: 0.6,
                                    ),
                                  ),
                                  priceText(_due, size: 34),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Align(
                                alignment: Alignment.centerLeft,
                                child: TextButton.icon(
                                  onPressed: () => Navigator.of(context).pop(),
                                  icon: const Icon(AppIcons.cart, size: 16),
                                  label: const Text(
                                    'Add more products / edit cart',
                                  ),
                                ),
                              ),
                            ],
                          ),
                          Text(
                            'QUICK AMOUNTS',
                            style: sora(
                              11,
                              weight: FontWeight.w800,
                              color: AppColors.inkSoft,
                              letterSpacing: 0.6,
                            ),
                          ),
                          const SizedBox(height: AppSpacing.sm),
                          Wrap(
                            spacing: AppSpacing.sm,
                            runSpacing: AppSpacing.sm,
                            children: [
                              for (final v in const [100, 200, 500, 1000])
                                PillChip(
                                  label: '₱$v',
                                  dense: true,
                                  selected: false,
                                  onTap: () => setState(
                                    () => _typed = v.toStringAsFixed(2),
                                  ),
                                ),
                              PillChip(
                                label: 'Exact',
                                dense: true,
                                selected: false,
                                onTap: () => setState(
                                  () => _typed = _due.toStringAsFixed(2),
                                ),
                              ),
                            ],
                          ),
                          if (_error != null) ...[
                            const SizedBox(height: AppSpacing.md),
                            PosAlert.err(text: _error!),
                          ],
                        ],
                      ),
                    ),
                    SafeArea(
                      top: false,
                      child: Container(
                        padding: const EdgeInsets.fromLTRB(
                          AppSpacing.screen,
                          AppSpacing.md,
                          AppSpacing.screen,
                          AppSpacing.md,
                        ),
                        decoration: const BoxDecoration(
                          color: AppColors.card,
                          border: Border(
                            top: BorderSide(color: AppColors.line),
                          ),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  'AMOUNT RECEIVED',
                                  style: sora(
                                    11,
                                    weight: FontWeight.w800,
                                    color: AppColors.inkSoft,
                                    letterSpacing: 0.6,
                                  ),
                                ),
                                Text(
                                  Fmt.peso(_received),
                                  style: sora(26, weight: FontWeight.w800),
                                ),
                              ],
                            ),
                            const SizedBox(height: AppSpacing.xs),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  'CHANGE',
                                  style: sora(
                                    11,
                                    weight: FontWeight.w800,
                                    color: AppColors.inkSoft,
                                    letterSpacing: 0.6,
                                  ),
                                ),
                                _covers
                                    ? priceText(
                                        _change,
                                        size: 26,
                                        color: AppColors.green,
                                      )
                                    : Text(
                                        '—',
                                        style: sora(
                                          20,
                                          weight: FontWeight.w800,
                                          color: AppColors.inkFaint,
                                        ),
                                      ),
                              ],
                            ),
                            const SizedBox(height: AppSpacing.md),
                            GridView.count(
                              crossAxisCount: 3,
                              shrinkWrap: true,
                              physics: const NeverScrollableScrollPhysics(),
                              mainAxisSpacing: AppSpacing.sm,
                              crossAxisSpacing: AppSpacing.sm,
                              childAspectRatio: 1.9,
                              children: [for (final k in _keys) _padKey(k)],
                            ),
                            const SizedBox(height: AppSpacing.md),
                            PosButton(
                              label: 'Complete Sale',
                              icon: AppIcons.check,
                              busy: _busy,
                              onPressed: _covers ? _complete : null,
                            ),
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

  Widget _padKey(String k) {
    final isBack = k == '⌫';
    return Material(
      color: AppColors.card,
      borderRadius: BorderRadius.circular(AppRadius.m),
      child: InkWell(
        onTap: () => _onKey(k),
        borderRadius: BorderRadius.circular(AppRadius.m),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.m),
            border: Border.all(color: AppColors.line),
          ),
          alignment: Alignment.center,
          child: isBack
              ? const Icon(AppIcons.backspace, size: 22, color: AppColors.ink)
              : Text(k, style: sora(20, weight: FontWeight.w800)),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- wallet ----

/// Screen 04 — WALLET (GCash, GoTyme and every other QR method).
///
/// The method's QR is shown full-screen, the reference number is captured, and
/// the payment completes for exactly the order total — a wallet never hands
/// back change.
class WalletPaymentScreen extends StatefulWidget {
  const WalletPaymentScreen({super.key, required this.method});

  final PaymentMethod method;

  @override
  State<WalletPaymentScreen> createState() => _WalletPaymentScreenState();
}

class _WalletPaymentScreenState extends State<WalletPaymentScreen> {
  final _ref = TextEditingController();
  bool _busy = false;
  String? _error;
  double _due = 0;
  bool _emptyCart = false;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final cart = PosScope.read(context).cart;
    _due = cart.total;
    _emptyCart = cart.isEmpty;
  }

  @override
  void dispose() {
    _ref.dispose();
    super.dispose();
  }

  /// Re-read on open: the owner may have just uploaded the QR in Settings.
  Future<void> _showQr() async {
    final scope = PosScope.read(context);
    final fresh = await scope.db.paymentMethodById(widget.method.id);
    final path = fresh?.qrImagePath ?? widget.method.qrImagePath;
    if (!mounted) return;
    if (path == null || path.isEmpty) {
      setState(() {
        _error =
            'No QR code is uploaded for ${widget.method.name} yet. Add '
            'one in Settings → Payment Methods, then reopen this screen.';
      });
      return;
    }
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
            children: [
              Text(
                widget.method.name,
                style: sora(17, weight: FontWeight.w800),
              ),
              if ((fresh?.accountName ?? '').isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  fresh!.accountName,
                  style: jakarta(13, color: AppColors.inkSoft),
                ),
              ],
              if ((fresh?.accountNumber ?? '').isNotEmpty)
                Text(
                  fresh!.accountNumber,
                  style: mono(13, color: AppColors.inkSoft),
                ),
              const SizedBox(height: AppSpacing.lg),
              StorageImage(
                path: path,
                width: 280,
                height: 280,
                icon: AppIcons.qr,
              ),
              const SizedBox(height: AppSpacing.lg),
              priceText(_due, size: 22),
              const SizedBox(height: AppSpacing.lg),
              PosButton(
                label: 'Close',
                variant: PosButtonVariant.quiet,
                onPressed: () => Navigator.of(ctx).pop(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirm() async {
    if (_busy) return;
    final ref = _ref.text.trim();
    if (widget.method.requireReference && ref.isEmpty) {
      setState(() {
        _error =
            'Enter the reference number from the customer’s payment app — '
            '${widget.method.name} requires it.';
      });
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final (order, error) = await submitSale(
      context,
      method: widget.method,
      referenceNo: ref,
    );
    if (!mounted) return;
    if (order == null) {
      setState(() {
        _busy = false;
        _error = error;
      });
      return;
    }
    _openReceipt(context, order);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.method.name),
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: 12),
            child: Center(child: SyncChip()),
          ),
        ],
      ),
      resizeToAvoidBottomInset: true,
      body: _emptyCart
          ? const EmptyState(
              icon: AppIcons.wallet,
              title: 'The cart is empty',
              message: 'Go back and add products before taking a payment.',
            )
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: Adaptive.formMax),
                child: Column(
                  children: [
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.all(AppSpacing.screen),
                        children: [
                          SectionCard(
                            title: 'Amount due',
                            children: [
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    'PAY VIA ${widget.method.name.toUpperCase()}',
                                    style: sora(
                                      11,
                                      weight: FontWeight.w800,
                                      color: AppColors.inkSoft,
                                      letterSpacing: 0.6,
                                    ),
                                  ),
                                  priceText(_due, size: 34),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Align(
                                alignment: Alignment.centerLeft,
                                child: TextButton.icon(
                                  onPressed: () => Navigator.of(context).pop(),
                                  icon: const Icon(AppIcons.cart, size: 16),
                                  label: const Text(
                                    'Add more products / edit cart',
                                  ),
                                ),
                              ),
                            ],
                          ),
                          PosButton(
                            label: 'Show QR Code',
                            icon: AppIcons.qr,
                            variant: PosButtonVariant.ghost,
                            onPressed: _showQr,
                          ),
                          if ((widget.method.accountName).isNotEmpty) ...[
                            const SizedBox(height: AppSpacing.xs),
                            Center(
                              child: Text(
                                widget.method.accountName,
                                style: jakarta(13, color: AppColors.inkSoft),
                              ),
                            ),
                          ],
                          const SizedBox(height: AppSpacing.md),
                          PosField(
                            label: 'Reference number',
                            controller: _ref,
                            required: widget.method.requireReference,
                            hint: 'e.g. GCash confirmation code',
                            textInputAction: TextInputAction.done,
                            onChanged: (_) {
                              if (_error != null) setState(() => _error = null);
                            },
                          ),
                          if (widget.method.requireReference)
                            Padding(
                              padding: const EdgeInsets.only(
                                left: 2,
                                bottom: AppSpacing.md,
                              ),
                              child: Text(
                                'Required for e-wallet payments — read it back to '
                                'the customer before completing the sale.',
                                style: jakarta(12, color: AppColors.inkSoft),
                              ),
                            ),
                          if (_error != null) PosAlert.err(text: _error!),
                        ],
                      ),
                    ),
                    SafeArea(
                      top: false,
                      child: Container(
                        padding: const EdgeInsets.fromLTRB(
                          AppSpacing.screen,
                          AppSpacing.md,
                          AppSpacing.screen,
                          AppSpacing.md,
                        ),
                        decoration: const BoxDecoration(
                          color: AppColors.card,
                          border: Border(
                            top: BorderSide(color: AppColors.line),
                          ),
                        ),
                        child: PosButton(
                          label: 'Confirm Payment',
                          icon: AppIcons.check,
                          busy: _busy,
                          onPressed: _confirm,
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
