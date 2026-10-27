import 'dart:async';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../core/icons.dart';
import '../core/tokens.dart';
import '../core/web_apis.dart' as web;
import '../data/api.dart';
import '../data/db.dart';
import '../data/logic.dart';
import 'adaptive.dart';
import 'scope.dart';
import 'widgets.dart';

String _extFor(String mime) => switch (mime) {
  'image/png' => 'png',
  'image/jpeg' => 'jpg',
  _ => 'webp',
};

/// Screen 08 — PRODUCTS.
///
/// The owner's shelf list: photo, name, category, price, stock. Selling stays
/// on the Sell screen — this list is for editing, and every edit lands in the
/// outbox like everything else.
class ProductsScreen extends StatefulWidget {
  const ProductsScreen({super.key});

  @override
  State<ProductsScreen> createState() => _ProductsScreenState();
}

class _ProductsScreenState extends State<ProductsScreen> {
  final _search = TextEditingController();
  List<Product> _products = const [];
  List<Category> _categories = const [];
  Map<String, String> _categoryNames = const {};
  String? _categoryId;
  bool _loading = true;
  bool _started = false;
  Timer? _debounce;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final scope = PosScope.read(context);
    final cats = await scope.db.listCategories(scope.store);
    final rows = await scope.db.listProducts(
      scope.store,
      categoryId: _categoryId,
      search: _search.text.trim(),
    );
    if (!mounted) return;
    setState(() {
      _categories = [
        for (final c in cats)
          if (c.isActive) c,
      ];
      _categoryNames = {for (final c in cats) c.id: c.name};
      _products = rows;
      _loading = false;
    });
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    if (value.trim().isEmpty) {
      _load(); // clearing the box must feel instant
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 250), _load);
  }

  void _selectCategory(String? id) {
    if (_categoryId == id) return;
    setState(() {
      _categoryId = id;
      _loading = true;
    });
    _load();
  }

  Future<void> _openForm({Product? product}) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ProductFormScreen(product: product),
      ),
    );
    if (mounted) _load();
  }

  Future<void> _openCategories() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const CategoriesScreen()));
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Products'),
        actions: [
          IconButton(
            tooltip: 'Categories',
            onPressed: _openCategories,
            icon: const Icon(AppIcons.category, size: 22),
          ),
          const Padding(
            padding: EdgeInsets.only(right: 12),
            child: Center(child: SyncChip()),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openForm(),
        icon: const Icon(AppIcons.plus),
        label: const Text('Add product'),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: Adaptive.wideContentMax),
          child: Column(
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
                  hint: 'Search products',
                  onChanged: _onSearchChanged,
                ),
              ),
              // Category chips — the same ones the Sell screen uses, so the
              // owner filters the shelf the same way everywhere.
              if (_categories.isNotEmpty)
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
                            dense: true,
                            onTap: () => _selectCategory(c.id),
                          ),
                        ),
                    ],
                  ),
                ),
              Expanded(child: _buildGrid()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGrid() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_products.isEmpty) {
      final searching = _search.text.trim().isNotEmpty;
      final inCategory = _categoryId != null;
      return EmptyState(
        icon: AppIcons.products,
        title: searching
            ? 'No matching products'
            : inCategory
            ? 'Nothing in this category'
            : 'No products yet',
        message: searching
            ? 'Try another name.'
            : inCategory
            ? 'Pick All to see the whole shelf, or add one here.'
            : 'Add the first product, or sync once you are online to pull '
                  'the list from the shop.',
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: LayoutBuilder(
        builder: (context, constraints) {
          const gap = AppSpacing.md;
          const screen = AppSpacing.screen;
          // Cards stay ~215 px wide and up to four across — a shelf you can
          // scan, not a table stretched over a desktop. Minimum two columns
          // because a lone 300 px card reads as a bug on a phone.
          final cols = ((constraints.maxWidth - 2 * screen + gap) / (215 + gap))
              .floor()
              .clamp(2, 4)
              .toInt();
          final side =
              (constraints.maxWidth - 2 * screen - (cols - 1) * gap) / cols;
          return GridView.builder(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.fromLTRB(
              screen,
              AppSpacing.sm,
              screen,
              88, // clear of the extended FAB
            ),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: cols,
              mainAxisSpacing: gap,
              crossAxisSpacing: gap,
              childAspectRatio: side / (side + 116),
            ),
            itemCount: _products.length,
            itemBuilder: (context, i) {
              final p = _products[i];
              return _ProductTile(
                product: p,
                categoryName: _categoryNames[p.categoryId] ?? 'No category',
                onOpen: () => _openForm(product: p),
              );
            },
          );
        },
      ),
    );
  }
}

/// One card in the shelf grid: photo on top, then name, category, price and
/// how many are on hand. The whole card opens the edit form — the pencil in
/// the corner just says so out loud. Inactive products stay visible under a
/// scrim, because the owner has to be able to switch them back on.
class _ProductTile extends StatelessWidget {
  const _ProductTile({
    required this.product,
    required this.categoryName,
    required this.onOpen,
  });

  final Product product;
  final String categoryName;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final p = product;
    return PosCard(
      padding: EdgeInsets.zero,
      margin: EdgeInsets.zero,
      onTap: onOpen,
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
                  StorageImage(path: p.imagePath, productId: p.id, radius: 0),
                  if (!p.isActive)
                    Container(
                      color: AppColors.card.withValues(alpha: 0.72),
                      alignment: Alignment.center,
                      child: StatusBadge('Inactive', kind: BadgeKind.voided),
                    ),
                  Positioned(
                    top: 8,
                    right: 8,
                    child: Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: AppColors.card,
                        shape: BoxShape.circle,
                        border: Border.all(color: AppColors.line),
                      ),
                      child: const Icon(
                        AppIcons.edit,
                        size: 15,
                        color: AppColors.inkSoft,
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
                          p.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: sora(
                            14.5,
                            weight: FontWeight.w700,
                            height: 1.2,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      StatusBadge(
                        p.stockStatus,
                        kind: stockBadgeKind(p.stockStatus),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    categoryName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: jakarta(11, color: AppColors.inkSoft),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(child: priceText(p.price, size: 15.5)),
                      Text(
                        '${p.stockQuantity} on hand',
                        style: jakarta(
                          11.5,
                          weight: FontWeight.w700,
                          color: p.stockQuantity > 0
                              ? AppColors.green
                              : AppColors.primary,
                        ),
                      ),
                    ],
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

/// Screen 08b — PRODUCT FORM.
///
/// One screen for "new" and "edit": identity, category, barcode, photo, the
/// stock adjustment and (in edit mode) a soft delete. The photo is picked,
/// downscaled to 400 px and uploaded to `pos-assets/products/{id}.{ext}` in the
/// same tap — a photo that never leaves the iPad is not a photo the other
/// device will ever see.
class ProductFormScreen extends StatefulWidget {
  const ProductFormScreen({super.key, this.product});

  final Product? product;

  @override
  State<ProductFormScreen> createState() => _ProductFormScreenState();
}

class _ProductFormScreenState extends State<ProductFormScreen> {
  final _name = TextEditingController();
  final _price = TextEditingController();
  final _barcode = TextEditingController();
  final _notes = TextEditingController();
  String? _categoryId;
  String? _imagePath;
  String _stockStatus = StockStatus.inStock;
  bool _isActive = true;
  bool _saving = false;
  bool _photoBusy = false;
  String? _error;
  int _stock = 0;
  List<Category> _categories = const [];
  bool _started = false;

  /// Live duplicate check while typing the name (owner request): a debounced
  /// LIKE query against the LOCAL database — never the network — and the
  /// matches render under the field, tappable to open that product instead.
  Timer? _nameDebounce;
  List<Product> _nameMatches = const [];

  String get _id => widget.product?.id ?? const Uuid().v4();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final p = widget.product;
    if (p != null) {
      _name.text = p.name;
      _price.text = p.price.toStringAsFixed(2);
      _barcode.text = p.barcode ?? '';
      _categoryId = p.categoryId;
      _imagePath = p.imagePath;
      _isActive = p.isActive;
      _stock = p.stockQuantity;
      _stockStatus = p.stockStatus;
      _notes.text = p.notes ?? '';
    }
    _loadCategories();
  }

  @override
  void dispose() {
    _nameDebounce?.cancel();
    _name.dispose();
    _price.dispose();
    _barcode.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _loadCategories() async {
    final scope = PosScope.read(context);
    final cats = await scope.db.listCategories(scope.store);
    if (!mounted) return;
    setState(() => _categories = cats.where((c) => c.isActive).toList());
  }

  void _onNameChanged(String value) {
    _nameDebounce?.cancel();
    final query = value.trim();
    if (query.length < 2) {
      if (_nameMatches.isNotEmpty) {
        setState(() => _nameMatches = const []);
      }
      return;
    }
    _nameDebounce = Timer(
      const Duration(milliseconds: 200),
      () => _findNameMatches(query),
    );
  }

  /// The typed name against the shelf: every other live product whose name
  /// (or barcode — the same box matches either) contains the query, the
  /// product being edited excluded, five at most. Inactive rows are KEPT and
  /// flagged — finding a dormant twin is exactly when you want this list.
  Future<void> _findNameMatches(String query) async {
    final scope = PosScope.read(context);
    final rows = await scope.db.listProducts(scope.store, search: query);
    if (!mounted) return;
    setState(() {
      _nameMatches = [
        for (final p in rows)
          if (p.id != _id) p,
      ].take(5).toList();
    });
  }

  /// The list under the name field: label, rows, tap to open [product] in
  /// its own edit screen (the half-typed form stays underneath — backing out
  /// returns to it untouched).
  Widget _buildNameMatches() {
    if (_nameMatches.isEmpty) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.surfaceLow,
        borderRadius: BorderRadius.circular(AppRadius.l),
        border: Border.all(color: AppColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
            child: Text(
              'ALREADY IN THE SHOP — TAP TO OPEN',
              style: sora(
                10,
                weight: FontWeight.w800,
                color: AppColors.inkSoft,
                letterSpacing: 0.7,
              ),
            ),
          ),
          for (var i = 0; i < _nameMatches.length; i++) ...[
            if (i > 0)
              const Divider(height: 1, indent: 14, endIndent: 14),
            InkWell(
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ProductFormScreen(product: _nameMatches[i]),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _nameMatches[i].name,
                        style: sora(13.5, weight: FontWeight.w700),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (!_nameMatches[i].isActive) ...[
                      const SizedBox(width: 8),
                      const StatusBadge(
                        'Inactive',
                        kind: BadgeKind.voided,
                      ),
                    ],
                    const SizedBox(width: 10),
                    priceText(_nameMatches[i].price, size: 13.5),
                    const SizedBox(width: 6),
                    const Icon(
                      AppIcons.edit,
                      size: 15,
                      color: AppColors.inkFaint,
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  Future<void> _pickPhoto() async {
    if (_photoBusy) return;
    final source = await _askPhotoSource();
    if (source == null || !mounted) return;
    final picked = source == 'camera'
        ? await web.pickImageFromCamera(maxDimension: 400)
        : await web.pickImage(maxDimension: 400);
    if (picked == null || !mounted) return;
    if (!Api.instance.isReady) {
      showSnack(
        context,
        'Uploading a photo needs an internet connection — try again online.',
        error: true,
      );
      return;
    }
    setState(() => _photoBusy = true);
    final scope = PosScope.read(context);
    final path = 'products/$_id.${_extFor(picked.mime)}';
    try {
      await Api.instance.uploadImage(path, picked.bytes, picked.mime);
      await scope.db.cacheImage(
        path: path,
        bytes: picked.bytes,
        contentType: picked.mime,
      );
      if (!mounted) return;
      setState(() {
        _imagePath = path;
        _photoBusy = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _photoBusy = false);
      showSnack(context, 'The photo could not be uploaded.', error: true);
    }
  }

  /// Ask the cashier whether to pick from the gallery or take a camera photo.
  /// Returns null when cancelled.
  Future<String?> _askPhotoSource() async {
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.xl),
          side: const BorderSide(color: AppColors.lineHi),
        ),
        title: Text(
          'Add product photo',
          style: sora(18, weight: FontWeight.w800),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(AppIcons.image, color: AppColors.inkSoft),
              title: const Text('Choose from gallery'),
              onTap: () => Navigator.of(ctx).pop('gallery'),
            ),
            ListTile(
              leading: const Icon(AppIcons.camera, color: AppColors.inkSoft),
              title: const Text('Take a photo'),
              onTap: () => Navigator.of(ctx).pop('camera'),
            ),
          ],
        ),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('Cancel', style: sora(13, color: AppColors.inkSoft)),
          ),
        ],
      ),
    );
  }

  Future<void> _adjustStock() async {
    final controller = TextEditingController();
    final delta = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.xl),
          side: const BorderSide(color: AppColors.lineHi),
        ),
        title: Text('Adjust stock', style: sora(18, weight: FontWeight.w800)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('On hand now: $_stock', style: jakarta(13)),
            const SizedBox(height: 10),
            TextField(
              controller: controller,
              keyboardType: const TextInputType.numberWithOptions(signed: true),
              style: jakarta(16, weight: FontWeight.w500),
              decoration: const InputDecoration(
                labelText: 'Change by',
                hintText: '+5 to add, -2 to remove',
              ),
            ),
          ],
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
            onPressed: () => Navigator.of(ctx)
                .pop(int.tryParse(controller.text.trim().replaceAll('+', ''))),
          ),
        ],
      ),
    );
    controller.dispose();
    if (delta == null || delta == 0 || !mounted) return;
    final scope = PosScope.read(context);
    final device = await scope.devices.ensureRegistered(scope.store);
    await scope.db.adjustStock(
      _id,
      delta,
      'manual',
      deviceId: device.id,
      storeId: scope.store,
    );
    final fresh = await scope.db.productById(_id);
    if (!mounted) return;
    setState(() => _stock = fresh?.stockQuantity ?? (_stock + delta));
    showSnack(context, 'Stock updated — now $_stock on hand.');
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    final price = double.tryParse(_price.text.trim()) ?? -1;
    if (name.isEmpty) {
      setState(() => _error = 'The product needs a name.');
      return;
    }
    if (price < 0) {
      setState(() => _error = 'Enter a price of ₱0.00 or more.');
      return;
    }
    final scope = PosScope.read(context);
    // Refuse a NORMALISED duplicate name at the form: the server's unique
    // index (migration 006) would reject the push anyway, and "Sync failed"
    // is a much worse place to learn about it than the field that caused it.
    final dup = await scope.db.liveProductByName(
      scope.store,
      name,
      excludeId: _id,
    );
    if (!mounted) return;
    if (dup != null) {
      setState(
        () => _error =
            '“${dup.name}” already exists — pick a different '
            'name, or edit that product instead.',
      );
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final device = await scope.devices.ensureRegistered(scope.store);
    final p = widget.product;
    final now = DateTime.now().toUtc();
    final updated = Product(
      id: _id,
      storeId: scope.store,
      categoryId: _categoryId,
      name: name,
      price: price,
      barcode: _barcode.text.trim().isEmpty ? null : _barcode.text.trim(),
      imagePath: _imagePath,
      stockQuantity: _stock,
      isActive: _isActive,
      stockStatus: _stockStatus,
      sourceRef: p?.sourceRef,
      notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
      sourceCol1: p?.sourceCol1,
      createdAt: p?.createdAt ?? now,
      updatedAt: now,
      deletedAt: null,
      syncedAt: null,
    );
    await scope.db.upsertProduct(
      updated,
      deviceId: device.id,
      storeId: scope.store,
    );
    await scope.sync.syncAll();
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    final yes = await confirm(
      context,
      title: 'Delete this product?',
      message:
          '“${_name.text.trim()}” disappears from the Sell screen. Past sales '
          'keep their line because every receipt is a snapshot.',
      confirmLabel: 'Delete',
      danger: true,
    );
    if (!yes || !mounted) return;
    final scope = PosScope.read(context);
    final device = await scope.devices.ensureRegistered(scope.store);
    await scope.db.softDeleteProduct(
      _id,
      deviceId: device.id,
      storeId: scope.store,
    );
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.product == null ? 'New product' : 'Edit product'),
      ),
      body: CenteredWidth(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.screen),
          children: [
            SectionCard(
              title: 'Photo',
              children: [
                Row(
                  children: [
                    SizedBox(
                      width: 72,
                      height: 72,
                      child: StorageImage(
                        path: _imagePath,
                        radius: AppRadius.m,
                        icon: AppIcons.camera,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: PosButton(
                        label: _photoBusy ? 'Uploading…' : 'Choose photo',
                        icon: AppIcons.upload,
                        variant: PosButtonVariant.ghost,
                        busy: _photoBusy,
                        onPressed: _pickPhoto,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  'Square-ish works best. It is resized to 400 px before it goes '
                  'up, so a big photo never blocks the sale.',
                  style: jakarta(11.5, color: AppColors.inkSoft),
                ),
              ],
            ),
            PosField(
              label: 'Name',
              controller: _name,
              required: true,
              onChanged: _onNameChanged,
            ),
            _buildNameMatches(),
            PosField(
              label: 'Price',
              controller: _price,
              required: true,
              prefix: '₱',
              hint: '0.00',
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
            ),
            PosField(
              label: 'Barcode',
              controller: _barcode,
              hint: 'Optional',
              keyboardType: TextInputType.text,
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(left: 2, bottom: 6),
                    child: Text(
                      'CATEGORY',
                      style: sora(
                        11,
                        weight: FontWeight.w800,
                        color: AppColors.inkSoft,
                        letterSpacing: 0.6,
                      ),
                    ),
                  ),
                  DropdownButtonFormField<String?>(
                    initialValue: _categoryId,
                    style: jakarta(16, weight: FontWeight.w500),
                    dropdownColor: AppColors.card,
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: AppColors.card,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 14,
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(color: AppColors.line),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(
                          color: AppColors.ink,
                          width: 1.5,
                        ),
                      ),
                    ),
                    items: [
                      const DropdownMenuItem<String?>(
                        value: null,
                        child: Text('No category'),
                      ),
                      for (final c in _categories)
                        DropdownMenuItem<String?>(
                          value: c.id,
                          child: Text(c.name),
                        ),
                    ],
                    onChanged: (v) => setState(() => _categoryId = v),
                  ),
                ],
              ),
            ),
            SectionCard(
              title: 'Stock',
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '$_stock on hand',
                        style: sora(15, weight: FontWeight.w800),
                      ),
                    ),
                    PosButton(
                      label: 'Adjust',
                      icon: AppIcons.edit,
                      expanded: false,
                      variant: PosButtonVariant.quiet,
                      onPressed: _adjustStock,
                    ),
                  ],
                ),
              ],
            ),
            SectionCard(
              title: 'Shelf',
              children: [
                _StatusDropdown(
                  value: _stockStatus,
                  onChanged: (v) => setState(() => _stockStatus = v),
                ),
                const SizedBox(height: AppSpacing.md),
                PosField(
                  label: 'Note',
                  controller: _notes,
                  hint: 'e.g. RESTOCK',
                  keyboardType: TextInputType.text,
                ),
                if (widget.product?.sourceRef != null ||
                    widget.product?.sourceCol1 != null) ...[
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    [
                      if (widget.product?.sourceRef != null)
                        'Sheet id ${widget.product!.sourceRef}',
                      if (widget.product?.sourceCol1 != null)
                        'Column 1: ${widget.product!.sourceCol1}',
                    ].join(' · '),
                    style: jakarta(11.5, color: AppColors.inkSoft),
                  ),
                ],
              ],
            ),
            SwitchListTile(
              value: _isActive,
              contentPadding: EdgeInsets.zero,
              title: Text('Active', style: sora(14, weight: FontWeight.w700)),
              subtitle: Text(
                'Inactive products stay here but cannot be sold.',
                style: jakarta(12, color: AppColors.inkSoft),
              ),
              onChanged: (v) => setState(() => _isActive = v),
            ),
            if (_error != null) ...[
              PosAlert.err(text: _error!),
              const SizedBox(height: AppSpacing.md),
            ],
            PosButton(
              label: 'Save product',
              icon: AppIcons.check,
              busy: _saving,
              onPressed: _save,
            ),
            if (widget.product != null) ...[
              const SizedBox(height: AppSpacing.sm),
              PosButton(
                label: 'Delete product',
                icon: AppIcons.delete,
                variant: PosButtonVariant.danger,
                onPressed: _delete,
              ),
            ],
            const SizedBox(height: AppSpacing.xl),
          ],
        ),
      ),
    );
  }
}

/// The shelf status the owner writes by hand on the inventory sheet.
///
/// The four values are the sheet's own — never derived from the stock count,
/// because the sheet says "Low Stock" at 10 units and "In Stock" at 10 units
/// on different rows.
class _StatusDropdown extends StatelessWidget {
  const _StatusDropdown({required this.value, required this.onChanged});

  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final known = StockStatus.all.contains(value);
    return DropdownButtonFormField<String>(
      initialValue: value,
      style: jakarta(16, weight: FontWeight.w500),
      dropdownColor: AppColors.card,
      decoration: InputDecoration(
        filled: true,
        fillColor: AppColors.card,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 14,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AppColors.line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AppColors.ink, width: 1.5),
        ),
      ),
      items: [
        for (final s in StockStatus.all)
          DropdownMenuItem<String>(value: s, child: Text(s)),
        // A value the sheet uses that this app does not know is still shown.
        if (!known) DropdownMenuItem<String>(value: value, child: Text(value)),
      ],
      onChanged: (v) {
        if (v != null) onChanged(v);
      },
    );
  }
}

/// Screen 08c — CATEGORIES.
///
/// Add, rename and hide the shelf categories the Sell screen chips by. A
/// category is never hard-deleted: old products and past sales point at it.
class CategoriesScreen extends StatefulWidget {
  const CategoriesScreen({super.key});

  @override
  State<CategoriesScreen> createState() => _CategoriesScreenState();
}

class _CategoriesScreenState extends State<CategoriesScreen> {
  final _new = TextEditingController();
  List<Category> _categories = const [];
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _load();
  }

  @override
  void dispose() {
    _new.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final scope = PosScope.read(context);
    final cats = await scope.db.listCategories(scope.store);
    if (!mounted) return;
    setState(() => _categories = cats);
  }

  Future<void> _add() async {
    final name = _new.text.trim();
    if (name.isEmpty) return;
    final scope = PosScope.read(context);
    // One chip per shelf: a NORMALISED duplicate name is refused here rather
    // than rejected by the server's unique index (migration 006) mid-sync.
    final dup = await scope.db.liveCategoryByName(scope.store, name);
    if (dup != null) {
      if (!mounted) return;
      showSnack(
        context,
        '“${dup.name}” already exists as a category.',
        error: true,
      );
      _new.clear();
      return;
    }
    final now = DateTime.now().toUtc();
    final sortOrder =
        _categories.fold<int>(0, (a, c) => a > c.sortOrder ? a : c.sortOrder) +
        1;
    await scope.db.upsertCategory(
      Category(
        id: const Uuid().v4(),
        storeId: scope.store,
        name: name,
        sortOrder: sortOrder,
        isActive: true,
        createdAt: now,
        updatedAt: now,
        deletedAt: null,
        syncedAt: null,
      ),
    );
    _new.clear();
    await _load();
  }

  Future<void> _edit(Category c) async {
    final controller = TextEditingController(text: c.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.xl),
          side: const BorderSide(color: AppColors.lineHi),
        ),
        title: Text('Rename', style: sora(18, weight: FontWeight.w800)),
        content: TextField(
          controller: controller,
          style: jakarta(16, weight: FontWeight.w500),
          decoration: const InputDecoration(labelText: 'Category name'),
        ),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('Cancel', style: sora(13, color: AppColors.inkSoft)),
          ),
          PosButton(
            label: 'Save',
            expanded: false,
            height: 44,
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty || name == c.name || !mounted) return;
    final scope = PosScope.read(context);
    final dup = await scope.db.liveCategoryByName(
      scope.store,
      name,
      excludeId: c.id,
    );
    if (dup != null) {
      if (!mounted) return;
      showSnack(
        context,
        '“${dup.name}” already exists as a category.',
        error: true,
      );
      return;
    }
    await scope.db.upsertCategory(
      c.copyWith(name: name, updatedAt: DateTime.now().toUtc()),
    );
    await _load();
  }

  Future<void> _toggleActive(Category c) async {
    final scope = PosScope.read(context);
    await scope.db.upsertCategory(
      c.copyWith(isActive: !c.isActive, updatedAt: DateTime.now().toUtc()),
    );
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Categories')),
      body: CenteredWidth(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.screen),
          children: [
            Row(
              children: [
                Expanded(
                  child: PosField(
                    label: 'New category',
                    controller: _new,
                    hint: 'e.g. Candles',
                    onSubmitted: (_) => _add(),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.md),
                  child: PosButton(
                    label: 'Add',
                    icon: AppIcons.plus,
                    expanded: false,
                    onPressed: _add,
                  ),
                ),
              ],
            ),
            for (final c in _categories)
              PosCard(
                margin: const EdgeInsets.only(bottom: AppSpacing.md),
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md,
                  vertical: AppSpacing.sm,
                ),
                onTap: () => _edit(c),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        c.name,
                        style: sora(
                          14.5,
                          weight: FontWeight.w700,
                          color: c.isActive
                              ? AppColors.ink
                              : AppColors.inkFaint,
                        ),
                      ),
                    ),
                    if (!c.isActive)
                      const Padding(
                        padding: EdgeInsets.only(right: 8),
                        child: StatusBadge('Hidden', kind: BadgeKind.neutral),
                      ),
                    Switch(
                      value: c.isActive,
                      activeTrackColor: AppColors.primary,
                      onChanged: (_) => _toggleActive(c),
                    ),
                  ],
                ),
              ),
            if (_categories.isEmpty)
              const EmptyState(
                icon: AppIcons.category,
                title: 'No categories yet',
                message:
                    'Categories become the chips on the Sell screen. Add the '
                    'first one above.',
              ),
          ],
        ),
      ),
    );
  }
}
