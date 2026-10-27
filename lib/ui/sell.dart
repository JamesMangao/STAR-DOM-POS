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
import 'cart.dart';
import 'cart_screen.dart';
import 'payment.dart';
import 'scope.dart';
import 'widgets.dart';

/// Screen 01 — SELL.
///
/// Browse by category, search by name, tap to add. Items without a photo get
/// the neutral placeholder (about 4 in 10 products have no art). The cart bar
/// sticks to the bottom of the tab, above the shell's nav bar, so the cashier
/// can see what is in the basket without leaving the grid.
class SellScreen extends StatefulWidget {
  const SellScreen({super.key});

  @override
  State<SellScreen> createState() => _SellScreenState();
}

class _SellScreenState extends State<SellScreen> {
  final _search = TextEditingController();

  List<Category> _categories = const [];
  List<Product> _products = const [];
  List<(Product, int)> _topSellers = const [];
  bool _loading = true;
  String? _categoryId;
  Timer? _debounce;
  Timer? _topReloadTimer;
  StreamSubscription<Set<TableUpdate>>? _dbSub;
  bool _started = false;

  /// Scan-to-add (HID barcode scanner): characters arrive every few ms and a
  /// final Enter. The burst is buffered here; a human typing is far slower
  /// than the 80 ms inter-key ceiling, so the two can never be confused.
  final _scanBuffer = StringBuffer();
  DateTime _lastScanKey = DateTime(2000);

  @override
  void initState() {
    super.initState();
    // The scanner types into whichever node has focus. When NO field is
    // focused (the usual state on the Sell grid) the keystrokes reach this
    // screen-level handler instead of disappearing.
    HardwareKeyboard.instance.addHandler(_onHardwareKey);
  }

  // First read of the scope happens here, not in initState: an inherited
  // lookup during initState is illegal in Flutter.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _loadCategories();
    _loadProducts();
    _loadTopSellers();
    _watchOrders();
  }

  /// A sale (or a void) re-ranks the quick-add row. The order tables are the
  /// only writes that change it, so listen to just those and coalesce the
  /// burst — same pattern as the Orders screen, scoped to one cheap query.
  void _watchOrders() {
    final db = PosScope.read(context).db;
    _dbSub = db
        .tableUpdates(
          TableUpdateQuery.onAllTables([
            db.orders,
            db.orderItems,
            db.orderVoids,
          ]),
        )
        .listen((_) {
          _topReloadTimer?.cancel();
          _topReloadTimer = Timer(const Duration(milliseconds: 250), () {
            if (mounted) _loadTopSellers();
          });
        });
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    _debounce?.cancel();
    _topReloadTimer?.cancel();
    _dbSub?.cancel();
    _search.dispose();
    super.dispose();
  }

  /// True while any text field owns focus — then typed characters belong to
  /// that field and the burst handler must stay out of the way (the field's
  /// own submit path handles the barcode).
  bool get _typingIntoField {
    var node = FocusManager.instance.primaryFocus;
    while (node != null) {
      if (node.context?.widget is EditableText) return true;
      node = node.parent;
    }
    return false;
  }

  bool _onHardwareKey(KeyEvent event) {
    if (!mounted || event is! KeyDownEvent) return false;
    if (_typingIntoField) {
      _scanBuffer.clear();
      return false;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      final code = _scanBuffer.toString();
      _scanBuffer.clear();
      // A real scan: several chars within the ceiling, Enter right behind.
      if (code.length >= 4 &&
          DateTime.now().difference(_lastScanKey).inMilliseconds < 500) {
        unawaited(_addByBarcode(code));
        return true; // consume: the burst WAS the action, not a submit
      }
      return false;
    }
    final ch = event.character;
    if (ch == null || ch.isEmpty || ch.length > 1) return false;
    final now = DateTime.now();
    if (now.difference(_lastScanKey).inMilliseconds > 80) {
      _scanBuffer.clear(); // chain broke — this is human typing
    }
    _scanBuffer.write(ch);
    _lastScanKey = now;
    return false;
  }

  /// Scanner burst → exact barcode → straight into the cart.
  Future<void> _addByBarcode(String code) async {
    final scope = PosScope.read(context);
    final match = await scope.db.productByBarcode(scope.store, code);
    if (!mounted) return;
    if (match == null || !match.isActive) {
      showSnack(
        context,
        match == null
            ? 'No product has barcode $code.'
            : 'Barcode $code is “${match.name}” — it is inactive in Products.',
        error: true,
      );
      return;
    }
    _addToCart(match);
  }

  /// One gate for every add on this screen: the stock rule decides, and a
  /// refusal says where to fix it. Successful adds confirm quietly.
  void _addToCart(Product product, {bool announce = false}) {
    if (!StockRules.canSell(
      stock: product.stockQuantity,
      status: product.stockStatus,
    )) {
      showSnack(
        context,
        '“${product.name}” is out of stock — update it in Products to sell '
        'again.',
        error: true,
      );
      return;
    }
    PosScope.of(context).cart.add(product);
    if (announce) showSnack(context, 'Added “${product.name}”.');
  }

  /// Search submit: an exact barcode match skips the grid and adds the item
  /// (the scanner's Enter path when a field happens to be focused); anything
  /// else falls through to the normal name search.
  Future<void> _onSearchSubmit(String value) async {
    final code = value.trim();
    if (code.isEmpty) {
      _loadProducts();
      return;
    }
    final scope = PosScope.read(context);
    final match = await scope.db.productByBarcode(scope.store, code);
    if (!mounted) return;
    if (match != null) {
      _search.clear();
      _addToCart(match, announce: true);
      _loadProducts();
      return;
    }
    _loadProducts();
  }

  /// The day's best sellers, newest fixture for the quick-add row. Re-run
  /// when products change (a void or a new sale moves the ranking); the
  /// 60 s tick from the shell is enough — this is a shortcut, not a report.
  Future<void> _loadTopSellers() async {
    final scope = PosScope.read(context);
    final tz = await scope.db.tzOffsetMinutes(scope.store);
    final now = DateTime.now();
    final start = BusinessDate.startOfDayUtc(now, tzOffsetMinutes: tz);
    final rows = await scope.db.topSellers(
      scope.store,
      start: start,
      end: start.add(const Duration(days: 1)),
    );
    if (!mounted) return;
    setState(() => _topSellers = rows);
  }

  Future<void> _loadCategories() async {
    final scope = PosScope.read(context);
    final cats = await scope.db.listCategories(scope.store);
    if (!mounted) return;
    setState(() => _categories = cats.where((c) => c.isActive).toList());
  }

  Future<void> _loadProducts() async {
    final scope = PosScope.read(context);
    final rows = await scope.db.listProducts(
      scope.store,
      categoryId: _categoryId,
      search: _search.text.trim(),
    );
    if (!mounted) return;
    setState(() {
      // Inactive products stay editable in Products but never enter a sale.
      // Products with no art used to be filtered out HERE as well, which hid
      // ~4 in 10 items while Products still called them Active — the two
      // screens disagreed. They are marked INACTIVE once at launch instead
      // (AppDatabase.deactivatePhotolessProducts), so `isActive` is the only
      // rule, and one the owner switches back on shows its placeholder here.
      _products = rows.where((p) => p.isActive).toList();
      _loading = false;
    });
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), _loadProducts);
    // Clearing the box must reset immediately (the suffix icon clears it).
    if (value.isEmpty) _loadProducts();
  }

  @override
  Widget build(BuildContext context) {
    final scope = PosScope.of(context);
    final cart = scope.cart;

    return Scaffold(
      appBar: AppBar(
        title: const _BrandTitle(),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(child: SyncChip()),
          ),
          PosButton(
            label: 'Refresh',
            icon: AppIcons.refresh,
            expanded: false,
            height: 40,
            variant: PosButtonVariant.ghost,
            onPressed: () => scope.sync.syncAll(),
          ),
        ],
      ),
      body: Adaptive.isWide(context) ? _buildWide(cart) : _buildNarrow(cart),
    );
  }

  Widget _buildWide(CartModel cart) => Row(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Expanded(child: _buildBrowse(cart)),
      Container(
        width: 380,
        decoration: const BoxDecoration(
          border: Border(left: BorderSide(color: AppColors.line)),
        ),
        child: _CartPanel(cart: cart),
      ),
    ],
  );

  /// The browsing column: search, category chips and the product grid. Shared
  /// by both layouts so the grid logic lives in one place.
  Widget _buildBrowse(CartModel cart) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.screen,
          AppSpacing.sm,
          AppSpacing.screen,
          0,
        ),
        child: SearchField(
          controller: _search,
          onChanged: _onSearchChanged,
          onSubmitted: _onSearchSubmit,
        ),
      ),
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
                label: 'All',
                selected: _categoryId == null,
                onTap: () => _selectCategory(null),
              ),
            ),
            for (final c in _categories)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: PillChip(
                  label: c.name,
                  selected: _categoryId == c.id,
                  onTap: () => _selectCategory(c.id),
                ),
              ),
          ],
        ),
      ),
      _buildTopSellers(),
      Expanded(child: _buildGrid()),
      // Wide layout: bundle bar lives here (narrows put it above the CartBar).
      if (Adaptive.isWide(context)) _buildBundleHintBar(cart),
    ],
  );

  /// Narrow (phone + iPad portrait): the cart rides a sticky bar at the bottom
  /// and opens the Cart as a bottom sheet on tap — faster than a full page
  /// push, keeps the product grid visible behind it.
  Widget _buildNarrow(CartModel cart) => Column(
    children: [
      Expanded(child: _buildBrowse(cart)),
      _buildBundleHintBar(cart),
      ListenableBuilder(
        listenable: cart,
        builder: (context, _) {
          if (cart.isEmpty) return const SizedBox.shrink();
          return _CartBar(
            itemCount: cart.itemCount,
            total: cart.total,
            onTap: () => showModalBottomSheet(
              context: context,
              isScrollControlled: true,
              backgroundColor: Colors.transparent,
              builder: (_) => const CartScreen(),
            ),
          );
        },
      ),
    ],
  );

  /// Real-time banner pinned to the bottom edge announcing active bundle
  /// discounts, progress towards the next bundle, or available deals.
  Widget _buildBundleHintBar(CartModel cart) {
    return ListenableBuilder(
      listenable: cart,
      builder: (context, _) {
        final hints = BundleMath.hints(
          rules: cart.bundleRules,
          items: [
            for (final l in cart.lines)
              for (var i = 0; i < l.quantity; i++)
                BundleItem(
                  productId: l.productId,
                  name: l.name,
                  categoryId: l.categoryId,
                  unitPrice: l.unitPrice,
                ),
          ],
        );

        final hasApplied = cart.bundleSavings > 0;
        final String text;
        final Color bgColor;
        final Color borderColor;
        final Color textColor;
        final IconData icon;

        if (hasApplied && hints.isEmpty) {
          // Bundle is complete and applied!
          text =
              '${cart.bundleSummary.join(' · ')} — Savings: ${Fmt.peso(cart.bundleSavings)}';
          bgColor = const Color(0xFFE8F5E9);
          borderColor = const Color(0xFFA5D6A7);
          textColor = const Color(0xFF1B5E20);
          icon = AppIcons.check;
        } else if (hasApplied && hints.isNotEmpty) {
          // Bundles applied, plus progress toward another bundle
          text =
              '${cart.bundleSummary.join(' · ')} (${Fmt.peso(cart.bundleSavings)} saved) · Next: ${hints.first.label} — ${hints.first.prompt}';
          bgColor = AppColors.yellowSoft;
          borderColor = AppColors.lineYellow;
          textColor = AppColors.ink;
          icon = AppIcons.discount;
        } else if (hints.isNotEmpty) {
          // Progress towards the first bundle
          text = hints.map((h) => '${h.label} — ${h.prompt}').join('   |   ');
          bgColor = AppColors.yellowSoft;
          borderColor = AppColors.lineYellow;
          textColor = AppColors.ink;
          icon = AppIcons.discount;
        } else if (cart.bundleRules.isNotEmpty) {
          // No qualifying items in cart yet; announce active deal
          final deals = cart.bundleRules
              .map(
                (r) => '${r.name}: any ${r.quantity} for ${Fmt.peso(r.price)}',
              )
              .join(' · ');
          text = 'Promo: $deals';
          bgColor = AppColors.yellowSoft.withValues(alpha: 0.5);
          borderColor = AppColors.lineYellow;
          textColor = AppColors.ink;
          icon = AppIcons.discount;
        } else {
          return const SizedBox.shrink();
        }

        return Container(
          decoration: BoxDecoration(
            color: bgColor,
            border: Border(top: BorderSide(color: borderColor)),
          ),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 16, color: textColor),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  text,
                  style: sora(
                    12.5,
                    weight: FontWeight.w700,
                    color: textColor,
                    height: 1.2,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _selectCategory(String? id) {
    setState(() => _categoryId = id);
    _loadProducts();
  }

  /// "Today's top sellers" — a chip row of the day's best movers so the
  /// repeat sale is two taps. Hidden while a search or category filter is
  /// active (it would contradict the filtered grid) and when the day has no
  /// sales yet.
  Widget _buildTopSellers() {
    final visible =
        _topSellers.isNotEmpty &&
        _categoryId == null &&
        _search.text.trim().isEmpty;
    if (!visible) return const SizedBox.shrink();
    return SizedBox(
      height: 46,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.screen,
          0,
          AppSpacing.screen,
          6,
        ),
        children: [
          for (final (product, units) in _topSellers)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: _TopSellerChip(
                product: product,
                units: units,
                onTap: () => _addToCart(product, announce: true),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildGrid() {
    if (_loading) {
      return GridView.builder(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.screen,
          AppSpacing.sm,
          AppSpacing.screen,
          AppSpacing.lg,
        ),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisSpacing: AppSpacing.md,
          crossAxisSpacing: AppSpacing.md,
          childAspectRatio: 0.85,
        ),
        itemCount: 6,
        itemBuilder: (context, i) => const ProductSkeleton(),
      );
    }
    if (_products.isEmpty) {
      final searching = _search.text.trim().isNotEmpty || _categoryId != null;
      if (searching) {
        return const EmptyState(
          icon: AppIcons.search,
          title: 'No matching products',
          message: 'Try another name, or switch the category chip back to All.',
        );
      }
      final scope = PosScope.read(context);
      return EmptyState(
        icon: AppIcons.products,
        title: 'No products yet',
        message:
            'Products arrive from the local database. Items without a photo '
            'are hidden until the owner adds one in Products. Sync once you '
            'are online, or run the import on the shop computer.',
        action: PosButton(
          label: 'Sync now',
          icon: AppIcons.sync,
          expanded: false,
          variant: PosButtonVariant.ghost,
          onPressed: () => scope.sync.syncAll(),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // 2 columns on a phone, more on the iPad landscape canvas — the card
        // keeps its proportions instead of stretching to 500 px wide.
        final cols = ((constraints.maxWidth - 2 * AppSpacing.screen) ~/ 240)
            .clamp(2, 4);
        final gap = AppSpacing.md;
        final side =
            (constraints.maxWidth - 2 * AppSpacing.screen - (cols - 1) * gap) /
            cols;
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.screen,
            AppSpacing.sm,
            AppSpacing.screen,
            AppSpacing.lg,
          ),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cols,
            mainAxisSpacing: gap,
            crossAxisSpacing: gap,
            // Square art + a two-line name + the price + padding.
            childAspectRatio: side / (side + 104),
          ),
          itemCount: _products.length,
          itemBuilder: (context, i) => _ProductCard(product: _products[i]),
        );
      },
    );
  }
}

/// One quick-add chip in the top-sellers row: thumbnail, name, sold count.
/// Tapping goes through the same stock gate as the grid card.
class _TopSellerChip extends StatelessWidget {
  const _TopSellerChip({
    required this.product,
    required this.units,
    required this.onTap,
  });

  final Product product;
  final int units;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.card,
      borderRadius: BorderRadius.circular(AppRadius.pill),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        child: Container(
          padding: const EdgeInsets.fromLTRB(6, 4, 12, 4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.pill),
            border: Border.all(color: AppColors.line),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 28,
                height: 28,
                child: StorageImage(
                  path: product.imagePath,
                  productId: product.id,
                  radius: AppRadius.pill,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                product.name,
                style: sora(12.5, weight: FontWeight.w700),
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.yellowSoft,
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                  border: Border.all(color: AppColors.lineYellow),
                ),
                child: Text(
                  '×$units',
                  style: sora(
                    10,
                    weight: FontWeight.w800,
                    color: AppColors.onYellow,
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

/// The top page header: the graffiti STAR:DOM mark NEXT TO the name — the
/// lockup the owner sent (logo kept, name added). Wrapped in a FittedBox so
/// a narrow phone scales the whole lockup down instead of colliding with
/// the sync chip in the actions.
class _BrandTitle extends StatelessWidget {
  const _BrandTitle();

  @override
  Widget build(BuildContext context) {
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Image.asset(
            'assets/stardom-logo.webp',
            height: 30,
            fit: BoxFit.contain,
            // Keep the image sharp on hi-DPI screens without bleeding into
            // the neighbouring action buttons.
            filterQuality: FilterQuality.medium,
            // The name stands right next to it — a missing logo just leaves
            // the lockup alone on the bar.
            errorBuilder: (context, err, trace) => const SizedBox.shrink(),
          ),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'ST⭐️R:Dom × ka1ofakind',
                style: sora(
                  17,
                  weight: FontWeight.w800,
                  letterSpacing: -0.5,
                  height: 1.1,
                ),
              ),
              Text(
                'ARTISAN & POP-UP HUB',
                style: sora(
                  9.5,
                  weight: FontWeight.w700,
                  color: AppColors.inkSoft,
                  letterSpacing: 1.3,
                  height: 1.3,
                ),
              ),
            ],
          ),
          const SizedBox(width: 10),
          // The second booth of the collab: ka1ofakind's mark stands on the
          // far right of the name, same height family as the ST⭐️R:Dom logo.
          Image.asset(
            'assets/ka1ofakind.png',
            height: 30,
            fit: BoxFit.contain,
            filterQuality: FilterQuality.medium,
            // The lockup stands on its own if the partner mark is
            // missing — never block the header on one asset.
            errorBuilder: (context, err, trace) => const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

class _ProductCard extends StatelessWidget {
  const _ProductCard({required this.product});

  final Product product;

  /// The card draws a red "can't sell" overlay when [StockRules.canSell]
  /// says no — the tap must agree with the picture. Blocking silently would
  /// leave the cashier wondering, so the refusal says where to fix it.
  void _add(BuildContext context) {
    if (!StockRules.canSell(
      stock: product.stockQuantity,
      status: product.stockStatus,
    )) {
      showSnack(
        context,
        '“${product.name}” is out of stock — update it in Products to sell '
        'again.',
        error: true,
      );
      return;
    }
    PosScope.of(context).cart.add(product);
  }

  @override
  Widget build(BuildContext context) {
    final cart = PosScope.of(context).cart;
    return PosCard(
      padding: EdgeInsets.zero,
      onTap: () => _add(context),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppRadius.l),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: 1,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  StorageImage(path: product.imagePath, productId: product.id),
                  ListenableBuilder(
                    listenable: cart,
                    builder: (context, _) {
                      final inCart = cart.lines
                          .where((l) => l.productId == product.id)
                          .fold<int>(0, (a, l) => a + l.quantity);
                      if (inCart == 0) return const SizedBox.shrink();
                      // Every increment pops the badge (≤150 ms, instant
                      // under reduced motion) — the ONLY confirmation a tap
                      // on the grid gets.
                      return Positioned(
                        top: 8,
                        right: 8,
                        child: TweenAnimationBuilder<double>(
                          key: ValueKey(inCart),
                          tween: Tween(begin: 0.6, end: 1.0),
                          duration: posMotion(context)
                              ? const Duration(milliseconds: 150)
                              : Duration.zero,
                          curve: Curves.easeOutBack,
                          builder: (context, scale, child) =>
                              Transform.scale(scale: scale, child: child),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 9,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.yellow,
                              borderRadius: BorderRadius.circular(AppRadius.pill),
                              border: Border.all(color: AppColors.lineYellow),
                            ),
                            child: Text(
                              '$inCart',
                              style: sora(
                                12,
                                weight: FontWeight.w800,
                                color: AppColors.onYellow,
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                  if (!StockRules.canSell(
                    stock: product.stockQuantity,
                    status: product.stockStatus,
                  ))
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          // A legible scrim, not a solid block: the art stays
                          // recognisable behind it so the cashier still knows
                          // WHICH product is gone.
                          color: AppColors.card.withValues(alpha: 0.72),
                          borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(AppRadius.l),
                          ),                          ),
                        child: Center(
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 5,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.failedBg,
                              borderRadius: BorderRadius.circular(
                                AppRadius.pill,
                              ),
                              border: Border.all(
                                color: AppColors.failedBorder,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  AppIcons.error,
                                  size: 13,
                                  color: AppColors.failedText,
                                ),
                                const SizedBox(width: 5),
                                Text(
                                  'OUT OF STOCK',
                                  style: sora(
                                    10,
                                    weight: FontWeight.w800,
                                    color: AppColors.failedText,
                                    letterSpacing: 0.6,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          product.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: sora(
                            14.5,
                            weight: FontWeight.w700,
                            height: 1.25,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      // ONE badge: stockStatus already reads "Low Stock" in
                      // this same pending colour. The old second literal
                      // "LOW STOCK" badge pushed the row to 241 px and
                      // overflowed 222 px cells with the name squeezed out.
                      StatusBadge(
                        product.stockStatus,
                        kind: stockBadgeKind(product.stockStatus),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    Fmt.peso(product.price),
                    style: sora(
                      15.5,
                      weight: FontWeight.w800,
                      color: AppColors.primary,
                      height: 1.1,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "3 items · ₱120.00" + View Cart — the sticky bar above the nav (design 01).
class _CartBar extends StatelessWidget {
  const _CartBar({required this.itemCount, required this.total, this.onTap});

  final int itemCount;
  final double total;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.card,
      elevation: 0,
      child: Container(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.screen,
          AppSpacing.md,
          AppSpacing.screen,
          AppSpacing.md,
        ),
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: AppColors.line)),
        ),
        child: Row(
          children: [
            Expanded(
              // The count/total crossfade-rise (≤180 ms, instant under
              // reduced motion) so a changing total reads as a change.
              child: AnimatedSwitcher(
                duration: posMotion(context)
                    ? const Duration(milliseconds: 180)
                    : Duration.zero,
                switchInCurve: Curves.easeOutCubic,
                transitionBuilder: (child, anim) => FadeTransition(
                  opacity: anim,
                  child: SlideTransition(
                    position: Tween(
                      begin: const Offset(0, 0.35),
                      end: Offset.zero,
                    ).animate(anim),
                    child: child,
                  ),
                ),
                child: Text(
                  '$itemCount item${itemCount == 1 ? '' : 's'} · '
                  '${Fmt.peso(total)}',
                  key: ValueKey('$itemCount-${Fmt.peso(total)}'),
                  style: sora(15, weight: FontWeight.w800),
                ),
              ),
            ),
            PosButton(
              label: 'View Cart',
              icon: AppIcons.cart,
              expanded: false,
              height: 48,
              onPressed: onTap,
            ),
          ],
        ),
      ),
    );
  }
}

/// The pinned cart panel for the landscape Sell split: lines (with steppers),
/// the bundle deals (when one has landed), a compact totals card and the
/// enabled payment methods — the full cart flow in place, so the cashier
/// never leaves the product grid to ring up a sale.
///
/// It owns its own payment-method list and discount/note controllers, exactly
/// like the Cart screen does, and reads the same shell [CartModel].
class _CartPanel extends StatefulWidget {
  const _CartPanel({required this.cart});

  final CartModel cart;

  @override
  State<_CartPanel> createState() => _CartPanelState();
}

class _CartPanelState extends State<_CartPanel> {
  List<PaymentMethod> _methods = const [];
  final _discount = TextEditingController();
  final _note = TextEditingController();
  bool _started = false;

  CartModel get cart => widget.cart;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (cart.discount > 0) {
      _discount.text = cart.discount.toStringAsFixed(2);
    }
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

  void _openPayment(PaymentMethod method) {
    final screen = method.type == 'cash'
        ? CashPaymentScreen(method: method)
        : WalletPaymentScreen(method: method);
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: cart,
      builder: (context, _) {
        if (cart.isEmpty) {
          return const Center(
            child: EmptyState(
              icon: AppIcons.cart,
              title: 'Cart is empty',
              message: 'Tap a product to start a sale.',
            ),
          );
        }
        return ListView(
          padding: const EdgeInsets.all(AppSpacing.md),
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 2, bottom: AppSpacing.sm),
              child: Text(
                'CART · ${cart.itemCount} item${cart.itemCount == 1 ? '' : 's'}',
                style: sora(
                  12,
                  weight: FontWeight.w800,
                  color: AppColors.inkSoft,
                  letterSpacing: 0.6,
                ),
              ),
            ),
            for (var i = 0; i < cart.lines.length; i++) CartLineRow(index: i),
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadius.m),
                  ),
                ),
                onPressed: () => showAddCustomProductDialog(context, cart),
                icon: const Icon(AppIcons.plus, size: 18),
                label: const Text('Add Custom / Extra Product'),
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
                        style: sora(13.5, weight: FontWeight.w600, height: 1.3),
                      ),
                    ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    'Bundle savings · ${Fmt.peso(cart.bundleSavings)}',
                    style: sora(
                      13,
                      weight: FontWeight.w700,
                      color: AppColors.inkSoft,
                    ),
                  ),
                ],
              ),
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
                      Text('Total', style: sora(17, weight: FontWeight.w800)),
                      priceText(cart.total, size: 22),
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
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final m in _methods)
                        Padding(
                          padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                          child: PosButton(
                            label: m.name,
                            icon: m.type == 'cash'
                                ? AppIcons.cash
                                : AppIcons.wallet,
                            variant: m.type == 'cash'
                                ? PosButtonVariant.primary
                                : PosButtonVariant.ghost,
                            onPressed: () => _openPayment(m),
                          ),
                        ),
                    ],
                  ),
              ],
            ),
          ],
        );
      },
    );
  }
}
