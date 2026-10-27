import 'dart:convert';

import 'package:uuid/uuid.dart';

/// Pure, host-testable business logic. No Flutter/DB imports.

/// MONEY. The stored value stays a peso [double] (it round-trips to the
/// server's numeric(10,2) and every screen, export and import speaks pesos),
/// but no comparison, sum or difference is ever done in floating point: each
/// one converts to integer CENTAVOS first, which is what makes 0.1 + 0.2 equal
/// 0.3 and a 3 x 19.99 line total exactly 59.97.
class Money {
  Money._();

  /// Pesos -> integer centavos. The single rounding point in the app.
  static int cents(double pesos) => (pesos * 100).round();

  /// Integer centavos -> pesos.
  static double pesos(int cents) => cents / 100;

  /// Round a peso value to 2 decimals (compat wrapper for AppDatabase.r2).
  static double round(double value) => pesos(cents(value));

  /// Cent-exact equality — never `a == b` on money.
  static bool equal(double a, double b) => cents(a) == cents(b);

  static int compare(double a, double b) => cents(a).compareTo(cents(b));

  /// Cent-exact sum of any number of peso values.
  static double sum(Iterable<double> pesosValues) =>
      pesos(pesosValues.fold<int>(0, (acc, v) => acc + cents(v)));

  static double subtract(double a, double b) => pesos(cents(a) - cents(b));

  /// unit price x quantity, in cents (a line total can never drift).
  static double multiply(double unitPrice, int quantity) =>
      pesos(cents(unitPrice) * quantity);
}

/// Cashier math: change = received - due; sale completes only when received >= due.
class ChangeCalc {
  ChangeCalc._();

  static double compute({required double due, required double received}) =>
      Money.subtract(received, due);

  static bool canComplete({required double due, required double received}) =>
      Money.cents(received) >= Money.cents(due);
}

/// order_no = {device_code}-{YYMMDD}-{seq}, unique per store.
class OrderNo {
  OrderNo._();

  static String generate(
    String deviceCode,
    DateTime now,
    int seq, {
    int tzOffsetMinutes = BusinessDate.defaultTzOffsetMinutes,
  }) {
    final local = BusinessDate.local(now, tzOffsetMinutes: tzOffsetMinutes);
    final ymd =
        '${local.year % 100}'.padLeft(2, '0') +
        '${local.month}'.padLeft(2, '0') +
        '${local.day}'.padLeft(2, '0');
    return '$deviceCode-$ymd-${seq.toString().padLeft(3, '0')}';
  }

  /// YYMMDD day key for per-device daily sequences (STORE-LOCAL day).
  static String dayKey(
    DateTime now, {
    int tzOffsetMinutes = BusinessDate.defaultTzOffsetMinutes,
  }) {
    final local = BusinessDate.local(now, tzOffsetMinutes: tzOffsetMinutes);
    return '${local.year % 100}'.padLeft(2, '0') +
        '${local.month}'.padLeft(2, '0') +
        '${local.day}'.padLeft(2, '0');
  }
}

/// Business date is the STORE-LOCAL calendar day (UTC+8 in Manila, no DST).
/// Using the UTC day put every sale before 08:00 Manila on the previous date.
/// One helper so reports, End-of-Day and Close Day never disagree.
class BusinessDate {
  BusinessDate._();

  /// Asia/Manila is UTC+8 all year — the default when no setting exists.
  static const int defaultTzOffsetMinutes = 480;

  /// The store-local wall clock for an instant.
  static DateTime local(
    DateTime at, {
    int tzOffsetMinutes = defaultTzOffsetMinutes,
  }) => at.toUtc().add(Duration(minutes: tzOffsetMinutes));

  /// Local midnight, expressed as the canonical UTC instant to store.
  static DateTime startOfDayUtc(
    DateTime at, {
    int tzOffsetMinutes = defaultTzOffsetMinutes,
  }) {
    final l = local(at, tzOffsetMinutes: tzOffsetMinutes);
    return DateTime.utc(
      l.year,
      l.month,
      l.day,
    ).subtract(Duration(minutes: tzOffsetMinutes));
  }

  /// YYYY-MM-DD key of the store-local day.
  static String key(
    DateTime at, {
    int tzOffsetMinutes = defaultTzOffsetMinutes,
  }) {
    final l = local(at, tzOffsetMinutes: tzOffsetMinutes);
    return '${l.year.toString().padLeft(4, '0')}-'
        '${l.month.toString().padLeft(2, '0')}-'
        '${l.day.toString().padLeft(2, '0')}';
  }

  static bool sameDay(
    DateTime a,
    DateTime b, {
    int tzOffsetMinutes = defaultTzOffsetMinutes,
  }) =>
      key(a, tzOffsetMinutes: tzOffsetMinutes) ==
      key(b, tzOffsetMinutes: tzOffsetMinutes);
}

/// Deterministic outbox event id — dedupe key for idempotent push.
/// Same (entity, entityId, updatedAt) always yields the same UUID.
/// Both sides are normalised to UTC so a device clock in local time and a
/// server in UTC agree on the id.
class OutboxEventId {
  OutboxEventId._();

  static const _uuid = Uuid();
  static const _ns = '6ba7b810-9dad-11d1-80b4-00c04fd430c8'; // Namespace URL

  static String of(String entity, String entityId, DateTime updatedAt) =>
      _uuid.v5(_ns, '$entity:$entityId:${updatedAt.toUtc().toIso8601String()}');
}

/// Ids that are the SAME on the phone and on the server.
///
/// The Node scripts (scripts/import-lib.js) and this app derive every seeded
/// id the same way — uuid v5 of a fixed namespace plus a stable name — so a
/// row created by the server import and the same row created by the app's
/// local seed carry the SAME primary key. The two copies merge instead of
/// duplicating, and an opening-stock event counted on one side is never
/// counted twice.
class StableId {
  StableId._();

  static const _uuid = Uuid();
  static const _ns = '6ba7b810-9dad-11d1-80b4-00c04fd430c8'; // Namespace URL

  /// `StableId.of('products', '17')` — the id of product #17.
  static String of(String table, String key) => _uuid.v5(_ns, '$table:$key');
}

/// The shelf status the owner writes by hand on the inventory sheet.
class StockStatus {
  StockStatus._();

  static const inStock = 'In Stock';
  static const lowStock = 'Low Stock';
  static const restock = 'Restock';
  static const outOfStock = 'Out of Stock';

  static const all = <String>[inStock, lowStock, restock, outOfStock];

  /// True when the value is one the sheet actually uses. Anything else is
  /// shown verbatim, never silently rewritten.
  static bool isKnown(String value) => all.contains(value);
}

/// May this product be rung up right now?
///
/// The sheet's status is NOT derivable from the count: it says "Low Stock" at
/// 10 units and "In Stock" at 10 units on different rows. So the status wins
/// when it says the item is gone, and the count decides otherwise — except
/// for a row whose count the sheet could not read ("##") but which the owner
/// still marked "In Stock": that one stays sellable, because the shelf says it
/// is there.
class StockRules {
  StockRules._();

  static bool canSell({required int stock, required String status}) {
    if (status == StockStatus.outOfStock) return false;
    if (stock > 0) return true;
    return status == StockStatus.inStock;
  }
}

/// A bundle deal from the inventory sheet: "any 4 stickers for ₱100".
class BundleRule {
  const BundleRule({
    required this.name,
    required this.quantity,
    required this.price,
    required this.categoryIds,
  });

  final String name;

  /// How many items make one bundle.
  final int quantity;

  /// What the whole bundle costs, in pesos.
  final double price;

  /// The categories this deal applies to (by category id).
  final Set<String> categoryIds;

  bool appliesTo(String? categoryId) =>
      categoryId != null && categoryIds.contains(categoryId);
}

/// The owner's bundle deals as they ride through the synced `settings` table
/// (under [key]). The catalogue's built-in deals are the DEFAULT; this row is
/// the override the owner edits in Settings → Promo bundles. Because it lives
/// in `settings`, it syncs to the server and survives a site-data clear —
/// exactly what the other two storage options could not promise.
///
/// Decode is defensive on purpose: a corrupt or half-written value must fall
/// back to the catalogue's deals at boot, never crash the booth. A malformed
/// ENTRY is dropped and the rest survive; only a structurally broken value
/// returns null. An empty list is legitimate — the owner turned every deal
/// off — and is distinct from null ("use the catalogue").
class BundleRulesCodec {
  BundleRulesCodec._();

  static const key = 'bundle_rules';

  static String encode(List<BundleRule> rules) => jsonEncode([
    for (final r in rules)
      {
        'name': r.name,
        'quantity': r.quantity,
        'price': r.price,
        'categoryIds': [...r.categoryIds]..sort(),
      },
  ]);

  static List<BundleRule>? tryDecode(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return null;
      final out = <BundleRule>[];
      for (final e in decoded) {
        if (e is! Map) continue;
        final name = e['name'];
        final quantity = e['quantity'];
        final price = e['price'];
        final ids = e['categoryIds'];
        if (name is! String || name.trim().isEmpty) continue;
        if (quantity is! num || quantity < 2) continue;
        if (price is! num || price < 0) continue;
        if (ids is! List) continue;
        final catIds = {
          for (final id in ids)
            if (id is String && id.isNotEmpty) id,
        };
        if (catIds.isEmpty) continue;
        out.add(
          BundleRule(
            name: name.trim(),
            quantity: quantity.toInt(),
            price: Money.round(price.toDouble()),
            categoryIds: catIds,
          ),
        );
      }
      return out;
    } catch (_) {
      return null;
    }
  }
}

/// One item that can go into a bundle.
class BundleItem {
  const BundleItem({
    required this.productId,
    required this.name,
    required this.categoryId,
    required this.unitPrice,
  });

  final String productId;
  final String name;
  final String? categoryId;
  final double unitPrice;
}

/// A bundle that was actually applied to the cart.
class AppliedBundle {
  const AppliedBundle({
    required this.rule,
    required this.items,
    required this.listTotal,
  });

  final BundleRule rule;
  final List<BundleItem> items;

  /// What the items cost on their own.
  final double listTotal;

  /// What the bundle costs.
  double get bundleTotal => rule.price;

  /// What the customer saves — always positive, never a surcharge.
  double get savings => Money.subtract(listTotal, bundleTotal);

  /// The names of the items, for the receipt line.
  String get summary => items.map((i) => i.name).join(', ');
}

/// The result of pricing a cart against the bundle deals.
class BundleQuote {
  const BundleQuote({required this.bundles});

  static const empty = BundleQuote(bundles: []);

  final List<AppliedBundle> bundles;

  /// Total saved by the bundles, in pesos.
  double get savings => Money.sum(bundles.map((b) => b.savings));

  bool get isEmpty => bundles.isEmpty;
}

/// A bundle deal the cart is ONE ITEM away from — the hint on the Sell
/// screen ("add 1 more sticker for the Stickers Bundle").
class BundleHint {
  const BundleHint({
    required this.rule,
    required this.needed,
    required this.inCart,
  });

  final BundleRule rule;

  /// How many more eligible items the cart needs.
  final int needed;

  /// How many eligible items are already in the cart.
  final int inCart;

  /// "Stickers Bundle · any 4 for ₱100.00"
  String get label =>
      '${rule.name} · any ${rule.quantity} for ₱${rule.price.toStringAsFixed(2)}';

  /// "Add 1 more sticker" — in the shop's own plural.
  String get prompt => 'Add $needed more';
}

/// The bundle pricing rules.
///
/// A bundle only ever makes the sale CHEAPER: the dearest items go into the
/// bundle first (that is where the saving is), and a group whose bundle price
/// is not below its own total is left alone — the customer pays the shelf
/// price rather than being charged a "bundle" premium.
class BundleMath {
  BundleMath._();

  static BundleQuote quote({
    required List<BundleRule> rules,
    required List<BundleItem> items,
  }) {
    if (rules.isEmpty || items.isEmpty) return BundleQuote.empty;

    final applied = <AppliedBundle>[];

    for (final rule in rules) {
      final eligible = items
          .where((i) => rule.appliesTo(i.categoryId))
          .toList();
      if (eligible.length < rule.quantity) continue;

      // Dearest first: the bundle takes the items where the saving is
      // biggest. Ties keep the cart's own order, so the result is stable.
      final sorted = [...eligible]
        ..sort((a, b) {
          final byPrice = Money.compare(b.unitPrice, a.unitPrice);
          if (byPrice != 0) return byPrice;
          return a.productId.compareTo(b.productId);
        });

      for (var i = 0; i + rule.quantity <= sorted.length; i += rule.quantity) {
        final group = sorted.sublist(i, i + rule.quantity);
        final listTotal = Money.sum(group.map((g) => g.unitPrice));
        // Only a real saving counts as a bundle.
        if (Money.compare(rule.price, listTotal) >= 0) continue;
        applied.add(
          AppliedBundle(rule: rule, items: group, listTotal: listTotal),
        );
      }
    }

    return BundleQuote(bundles: applied);
  }

  /// The deals the cart is close to completing.
  ///
  /// One hint per rule: the shop has three deals, and a screen full of
  /// hints is a screen nobody reads. A rule that is already applied is not
  /// hinted again — the cart shows the saving instead.
  static List<BundleHint> hints({
    required List<BundleRule> rules,
    required List<BundleItem> items,
  }) {
    if (rules.isEmpty || items.isEmpty) return const [];
    final out = <BundleHint>[];
    for (final rule in rules) {
      final eligible = items.where((i) => rule.appliesTo(i.categoryId)).length;
      if (eligible == 0) continue;
      final inCart = eligible % rule.quantity;
      if (inCart == 0) continue; // a full bundle is already priced
      out.add(
        BundleHint(rule: rule, needed: rule.quantity - inCart, inCart: inCart),
      );
    }
    return out;
  }
}

/// Last-write-wins by updated_at. Server wins ties (device clock drift).
class LastWriteWins {
  LastWriteWins._();

  /// Returns true when the server version should overwrite the local one.
  /// Applied to EVERY mutable table (products used to be the only one).
  static bool serverWins({
    required DateTime? localUpdatedAt,
    required DateTime? serverUpdatedAt,
  }) {
    if (serverUpdatedAt == null) return false;
    if (localUpdatedAt == null) return true;
    return !serverUpdatedAt.isBefore(localUpdatedAt);
  }
}

/// Stock = sum of delta events. Never an absolute overwrite.
class StockDelta {
  StockDelta._();

  static int sum(Iterable<int> deltas) => deltas.fold(0, (a, b) => a + b);
}

/// Append-only rules for orders (F3).
class OrderRules {
  OrderRules._();

  /// Orders, order_items, payments and order_voids are immutable after insert.
  static bool isImmutable(String entity) =>
      entity == 'orders' ||
      entity == 'order_items' ||
      entity == 'payments' ||
      entity == 'order_voids';

  /// Voided is DERIVED: an order is voided iff an order_voids row exists.
  static bool isVoided({required bool hasVoidRow}) => hasVoidRow;

  /// A void may only be appended once per order.
  static bool canVoid({required bool hasVoidRow}) => !hasVoidRow;
}

/// Orders-list status chip. Voided comes from `order_voids`; the rest comes
/// from outbox state — never from a mutated order row.
enum OrderChip { voided, failed, pending, synced }

class OrderChips {
  OrderChips._();

  static OrderChip of({
    required bool hasVoid,
    required bool synced,
    required bool failed,
  }) {
    if (hasVoid) return OrderChip.voided;
    if (failed) return OrderChip.failed;
    if (!synced) return OrderChip.pending;
    return OrderChip.synced;
  }
}
