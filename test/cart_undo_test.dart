import 'package:flutter_test/flutter_test.dart';

import 'package:stardom_pos/data/db.dart';
import 'package:stardom_pos/ui/cart.dart';

/// `restoreLine` is the other half of the cart ✕'s undo snack: the line is
/// captured before removal and put back exactly where it was, quantity and
/// all. An index past the end clamps instead of throwing — the list can move
/// while the snack is on screen.
void main() {
  Product product(String id, String name) => Product(
    id: id,
    storeId: 'store-1',
    categoryId: null,
    name: name,
    price: 30,
    barcode: null,
    imagePath: null,
    stockQuantity: 5,
    isActive: true,
    stockStatus: 'In Stock',
    createdAt: DateTime.utc(2026, 1, 1),
    updatedAt: DateTime.utc(2026, 1, 1),
    deletedAt: null,
    syncedAt: null,
  );

  test('restoreLine puts a removed line back at its index with its quantity', () {
    final cart = CartModel();
    cart.add(product('p1', 'A'));
    cart.add(product('p2', 'B'));
    cart.add(product('p3', 'C'));
    cart.changeQuantity('p2', 3);

    final removed = cart.lines[1];
    cart.removeAt(1);
    expect(cart.lines.map((l) => l.productId).toList(), ['p1', 'p3']);
    expect(cart.itemCount, 2);

    cart.restoreLine(removed, 1);
    expect(
      cart.lines.map((l) => l.productId).toList(),
      ['p1', 'p2', 'p3'],
      reason: 'the snapshot returns to the same position',
    );
    expect(cart.lines[1].quantity, 3, reason: 'quantity survives the round-trip');
    expect(cart.itemCount, 5);
  });

  test('restoring past the end clamps to append instead of throwing', () {
    final cart = CartModel();
    cart.add(product('p1', 'A'));
    cart.add(product('p2', 'B'));

    final line = cart.lines[0];
    cart.removeAt(0);
    cart.restoreLine(line, 99);
    expect(cart.lines.last.productId, 'p1');
    expect(cart.lines.map((l) => l.productId).toList(), ['p2', 'p1']);
  });

  test('restoring notifies listeners — the cart bar must redraw', () {
    final cart = CartModel();
    cart.add(product('p1', 'A'));
    var notified = 0;
    cart.addListener(() => notified++);

    final line = cart.lines.first;
    cart.removeAt(0);
    cart.restoreLine(line, 0);
    expect(notified, 2, reason: 'remove AND restore both announce');
  });
}
