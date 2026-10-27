import 'package:flutter/material.dart';

import '../core/format.dart';
import '../core/icons.dart';
import '../core/tokens.dart';
import '../data/db.dart';
import 'adaptive.dart';
import 'cart.dart';
import 'payment.dart';
import 'scope.dart';
import 'widgets.dart';

/// Screen 02 — CART.
///
/// Change quantities, remove a line, add a discount and a short note, then
/// pick how the customer is paying. Everything the cart edits lives in the
/// shell's [CartModel], so switching tabs never loses the basket.
class CartScreen extends StatefulWidget {
  const CartScreen({super.key});

  @override
  State<CartScreen> createState() => _CartScreenState();
}

class _CartScreenState extends State<CartScreen> {
  List<PaymentMethod> _methods = const [];
  final _discount = TextEditingController();
  final _note = TextEditingController();
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final cart = PosScope.read(context).cart;
    // The fields show what the cart already holds (the cashier may have
    // switched tabs before coming back here).
    if (cart.discount > 0) _discount.text = cart.discount.toStringAsFixed(2);
    if (cart.note.isNotEmpty) _note.text = cart.note;
    _loadMethods();
  }

  @override
  void dispose() {
    _discount.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _loadMethods() async {
    final scope = PosScope.read(context);
    final rows = await scope.db.listPaymentMethods(scope.store);
    if (!mounted) return;
    setState(() => _methods = rows.where((m) => m.isEnabled).toList());
  }

  @override
  Widget build(BuildContext context) {
    final scope = PosScope.of(context);
    final cart = scope.cart;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Cart'),
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: 12),
            child: Center(child: SyncChip()),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: cart,
        builder: (context, _) {
          if (cart.isEmpty) {
            return const EmptyState(
              icon: AppIcons.cart,
              title: 'The cart is empty',
              message: 'Tap products on the Sell screen to start a sale.',
            );
          }
          return CenteredWidth(
            child: ListView(
              padding: const EdgeInsets.all(AppSpacing.screen),
              children: [
                for (var i = 0; i < cart.lines.length; i++)
                  CartLineRow(index: i),
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.md),
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(AppRadius.m),
                            ),
                          ),
                          onPressed: () => Navigator.of(context).pop(),
                          icon: const Icon(AppIcons.plus, size: 18),
                          label: const Text('Add more products'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(AppRadius.m),
                            ),
                          ),
                          onPressed: () =>
                              showAddCustomProductDialog(context, cart),
                          icon: const Icon(AppIcons.products, size: 18),
                          label: const Text('Add custom item'),
                        ),
                      ),
                    ],
                  ),
                ),
                if (cart.bundleSavings > 0)
                  SectionCard(
                    title: 'Bundle deals',
                    children: [
                      for (final b in cart.bundleSummary)
                        Padding(
                          padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                          child: Text(
                            b,
                            style: sora(
                              14,
                              weight: FontWeight.w600,
                              height: 1.3,
                            ),
                          ),
                        ),
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        'Bundle savings · ${Fmt.peso(cart.bundleSavings)}',
                        style: sora(
                          13,
                          weight: FontWeight.w700,
                          color: AppColors.switchInk,
                        ),
                      ),
                    ],
                  ),
                const SizedBox(height: AppSpacing.sm),
                PosField(
                  label: 'Discount',
                  controller: _discount,
                  hint: '0.00',
                  prefix: '₱',
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  onChanged: (v) {
                    cart.discount = double.tryParse(v.trim()) ?? 0;
                  },
                ),
                PosField(
                  label: 'Order note',
                  controller: _note,
                  hint: 'Add a note (optional)',
                  onChanged: (v) => cart.note = v,
                ),
                const SizedBox(height: AppSpacing.xs),
                SectionCard(
                  title: 'Totals',
                  children: [
                    DetailRow('Subtotal', Fmt.peso(cart.subtotal)),
                    DetailRow('Discount', '-${Fmt.peso(cart.discount)}'),
                    const Divider(),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Total',
                            style: sora(17, weight: FontWeight.w800),
                          ),
                          priceText(cart.total, size: 24),
                        ],
                      ),
                    ),
                  ],
                ),
                SectionCard(
                  title: 'Payment method',
                  children: [
                    if (_methods.isEmpty)
                      const PosAlert.info(
                        text:
                            'No payment method is enabled. Enable one in '
                            'Settings → Payment Methods.',
                      )
                    else
                      Wrap(
                        spacing: AppSpacing.sm,
                        runSpacing: AppSpacing.sm,
                        children: [
                          for (final m in _methods)
                            PosButton(
                              label: m.name,
                              expanded: false,
                              icon: m.type == 'cash'
                                  ? AppIcons.cash
                                  : AppIcons.wallet,
                              variant: m.type == 'cash'
                                  ? PosButtonVariant.primary
                                  : PosButtonVariant.ghost,
                              onPressed: () => _openPayment(m),
                            ),
                        ],
                      ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// Cash gets the keypad, every other method gets the QR + reference flow.
  void _openPayment(PaymentMethod method) {
    final screen = method.type == 'cash'
        ? CashPaymentScreen(method: method)
        : WalletPaymentScreen(method: method);
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));
  }
}

/// One cart line: thumbnail, name, unit price, 48 pt stepper, line total.
///
/// Public (not `_`) because the Sell screen's landscape cart panel reuses it —
/// one line widget, two surfaces, so a stepper change cannot drift between the
/// Cart screen and the pinned panel.
class CartLineRow extends StatelessWidget {
  const CartLineRow({super.key, required this.index});

  final int index;

  @override
  Widget build(BuildContext context) {
    final cart = PosScope.of(context).cart;
    final line = cart.lines[index];
    return PosCard(
      margin: const EdgeInsets.only(bottom: AppSpacing.md),
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 56,
                height: 56,
                child: StorageImage(path: line.imagePath, radius: AppRadius.s),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      line.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: sora(14.5, weight: FontWeight.w700, height: 1.25),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${Fmt.peso(line.unitPrice)} each',
                      style: sora(
                        13,
                        weight: FontWeight.w800,
                        color: AppColors.primary,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Remove',
                onPressed: () {
                  // Capture BEFORE the removal: the undo snack restores this
                  // exact snapshot at the same position.
                  final line = cart.lines[index];
                  final at = index;
                  cart.removeAt(at);
                  showSnack(
                    context,
                    'Removed “${line.name}”.',
                    actionLabel: 'Undo',
                    onAction: () => cart.restoreLine(line, at),
                  );
                },
                icon: const Icon(
                  AppIcons.close,
                  size: 20,
                  color: AppColors.inkFaint,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              QtyStepper(
                quantity: line.quantity,
                onIncrement: () =>
                    cart.changeQuantity(line.productId, line.quantity + 1),
                onDecrement: () =>
                    cart.changeQuantity(line.productId, line.quantity - 1),
                onTapQuantity: () => _showQuantityDialog(context, cart, line),
              ),
              const Spacer(),
              priceText(line.lineTotal, size: 17, color: AppColors.ink),
            ],
          ),
        ],
      ),
    );
  }
}

/// Public dialog allowing cashiers to add an unlisted or custom product on the fly.
void showAddCustomProductDialog(BuildContext context, CartModel cart) {
  final nameCtrl = TextEditingController();
  final priceCtrl = TextEditingController();
  final qtyCtrl = TextEditingController(text: '1');
  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.xl),
        side: const BorderSide(color: AppColors.lineHi),
      ),
      title: Text(
        'Add custom item',
        style: sora(18, weight: FontWeight.w800),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            PosField(
              label: 'Product name',
              controller: nameCtrl,
              hint: 'e.g. Extra item, keychain, custom sticker',
              autofocus: true,
            ),
            PosField(
              label: 'Price',
              controller: priceCtrl,
              prefix: '₱',
              hint: '0.00',
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
            ),
            PosField(
              label: 'Quantity',
              controller: qtyCtrl,
              hint: '1',
              keyboardType: TextInputType.number,
            ),
          ],
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: Text('Cancel', style: sora(13, color: AppColors.inkSoft)),
        ),
        PosButton(
          label: 'Add to cart',
          expanded: false,
          height: 44,
          onPressed: () {
            final name = nameCtrl.text.trim();
            final price = double.tryParse(priceCtrl.text.trim()) ?? 0;
            final qty = int.tryParse(qtyCtrl.text.trim()) ?? 1;
            if (name.isNotEmpty && price >= 0) {
              cart.addCustomItem(name: name, price: price, quantity: qty);
            }
            Navigator.of(ctx).pop();
          },
        ),
      ],
    ),
  );
}

void _showQuantityDialog(BuildContext context, CartModel cart, CartLine line) {
  final controller = TextEditingController(text: '${line.quantity}');
  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.xl),
        side: const BorderSide(color: AppColors.lineHi),
      ),
      title: Text('Set quantity', style: sora(18, weight: FontWeight.w800)),
      content: SizedBox(
        width: 320,
        child: PosField(
          label: 'Quantity for "${line.name}"',
          controller: controller,
          hint: 'Enter quantity',
          keyboardType: TextInputType.number,
          autofocus: true,
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: Text('Cancel', style: sora(13, color: AppColors.inkSoft)),
        ),
        PosButton(
          label: 'Apply',
          expanded: false,
          height: 44,
          onPressed: () {
            final val = int.tryParse(controller.text.trim());
            if (val != null) {
              cart.changeQuantity(line.productId, val);
            }
            Navigator.of(ctx).pop();
          },
        ),
      ],
    ),
  );
}
