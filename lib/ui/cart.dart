import 'package:flutter/foundation.dart';

import '../data/db.dart';
import '../data/logic.dart';

/// One line in the open order: the product as it was tapped, plus a quantity.
///
/// The name and price are captured at tap time so editing a product while a
/// cart is open cannot rewrite a line the cashier is looking at — the same
/// snapshot rule the order rows themselves follow at sale time.
class CartLine {
  CartLine({
    required this.productId,
    required this.name,
    required this.unitPrice,
    this.categoryId,
    this.imagePath,
    this.quantity = 1,
  });

  final String productId;
  final String name;
  final double unitPrice;

  /// The shelf the product sits on — the bundle deals are per shelf
  /// ("any 4 stickers"), so the cart needs to know which one this is.
  final String? categoryId;
  final String? imagePath;
  int quantity;

  /// Cent-exact: unit price × quantity, never floating-point drift.
  double get lineTotal => Money.multiply(unitPrice, quantity);
}

/// The open order, held by the shell so switching tabs (Sell → Reports and
/// back) never loses it. Only in memory: closing the tab empties the cart,
/// which is correct — an uncharged cart is not a sale and must not be stored.
class CartModel extends ChangeNotifier {
  final List<CartLine> _lines = [];

  List<CartLine> get lines => List.unmodifiable(_lines);

  /// The bundle deals that apply to this cart ("any 4 stickers for ₱100").
  /// Set once at boot from the catalogue.
  List<BundleRule> _bundleRules = const [];

  List<BundleRule> get bundleRules => _bundleRules;

  set bundleRules(List<BundleRule> value) {
    _bundleRules = value;
    notifyListeners();
  }

  double _discount = 0;
  String _note = '';

  /// The discount the cashier typed by hand.
  double get discount => _discount;
  String get note => _note;

  bool get isEmpty => _lines.isEmpty;
  int get itemCount => _lines.fold<int>(0, (a, l) => a + l.quantity);

  double get subtotal => Money.sum(_lines.map((l) => l.lineTotal));

  /// The bundle deals that this cart actually qualifies for.
  BundleQuote get bundleQuote => BundleMath.quote(
    rules: _bundleRules,
    items: [
      for (final l in _lines)
        for (var i = 0; i < l.quantity; i++)
          BundleItem(
            productId: l.productId,
            name: l.name,
            categoryId: l.categoryId,
            unitPrice: l.unitPrice,
          ),
    ],
  );

  /// What the bundle deals save on this cart.
  double get bundleSavings => bundleQuote.savings;

  /// Everything taken off: the bundle deals plus the cashier's discount.
  double get totalDiscount => Money.round(_discount + bundleSavings);

  /// A discount can never exceed the subtotal or go negative: the total a
  /// customer is charged is always ≥ 0.
  double get total {
    final t = Money.subtract(subtotal, totalDiscount);
    return Money.compare(t, 0) < 0 ? 0.0 : t;
  }

  /// The bundle lines for the receipt ("Stickers Bundle · 4 items · −₱20.00").
  List<String> get bundleSummary => [
    for (final b in bundleQuote.bundles)
      '${b.rule.name} · ${b.items.length} items · −${b.savings.toStringAsFixed(2)}',
  ];

  void add(Product product) {
    final i = _index(product.id);
    if (i >= 0) {
      _lines[i].quantity++;
    } else {
      _lines.add(
        CartLine(
          productId: product.id,
          name: product.name,
          unitPrice: product.price,
          categoryId: product.categoryId,
          imagePath: product.imagePath,
        ),
      );
    }
    notifyListeners();
  }

  /// Adds a custom or unlisted item to the cart (for quick sales or manual entries).
  void addCustomItem({
    required String name,
    required double price,
    int quantity = 1,
    String? categoryId,
  }) {
    final customId = 'custom-${DateTime.now().millisecondsSinceEpoch}';
    _lines.add(
      CartLine(
        productId: customId,
        name: name,
        unitPrice: price,
        categoryId: categoryId,
        quantity: quantity > 0 ? quantity : 1,
      ),
    );
    notifyListeners();
  }

  /// +1 / −1 stepper. Quantity 0 (or below) removes the line — there is no
  /// "zero quantity" row on screen afterwards.
  void changeQuantity(String productId, int quantity) {
    final i = _index(productId);
    if (i < 0) return;
    if (quantity <= 0) {
      _lines.removeAt(i);
    } else {
      _lines[i].quantity = quantity;
    }
    notifyListeners();
  }

  void removeAt(int index) {
    _lines.removeAt(index);
    notifyListeners();
  }

  /// Put a removed line back at [index] — the other half of the undo snack
  /// on the cart's ✕. The line object is the snapshot taken at tap time, so
  /// restoring it re-creates exactly what the cashier saw.
  void restoreLine(CartLine line, int index) {
    final i = index.clamp(0, _lines.length);
    _lines.insert(i, line);
    notifyListeners();
  }

  /// Discount is a peso amount typed by the cashier, clamped to what is left
  /// after the bundle deals have done their part.
  set discount(double value) {
    final v = value.isNaN || value.isNegative ? 0.0 : Money.round(value);
    final room = Money.subtract(subtotal, bundleSavings);
    final max = room < 0 ? 0.0 : room;
    _discount = Money.compare(v, max) > 0 ? max : v;
    notifyListeners();
  }

  set note(String value) {
    _note = value;
    notifyListeners();
  }

  void clear() {
    _lines.clear();
    _discount = 0;
    _note = '';
    notifyListeners();
  }

  int _index(String productId) =>
      _lines.indexWhere((l) => l.productId == productId);
}
