import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import 'db.dart';
import 'logic.dart';

/// The shop's shelf, bundled with the app.
///
/// The source of truth is the paper inventory
/// (docs/inventory/ARTSHOP_DATABASE_2.md), turned into data by
/// `scripts/catalogue-build.js`. The phone carries the result so a booth with
/// no signal still shows the real products, their real artwork and the real
/// bundle deals — and the server import writes the SAME rows with the SAME
/// ids, so the two sides merge instead of duplicating.
class Catalogue {
  // Not a const constructor: [bundleRules] is derived from the categories and
  // the bundle rules, so it cannot be a constant.
  Catalogue({
    required this.version,
    required this.source,
    required this.spec,
    required this.currency,
    required this.store,
    required this.categories,
    required this.products,
    required this.bundles,
  });

  /// Where the catalogue lives inside the app bundle.
  static const assetPath = 'assets/catalogue/catalogue.json';

  final int version;

  /// The document the rows came from (the PDF).
  final String source;

  /// The checked-in spec the rows were transcribed into.
  final String spec;
  final String currency;
  final CatalogueStore store;
  final List<CatalogueCategory> categories;
  final List<CatalogueProduct> products;
  final List<CatalogueBundle> bundles;

  /// The bundle deals, resolved to the category ids they apply to.
  late final List<BundleRule> bundleRules = [
    for (final b in bundles)
      BundleRule(
        name: b.name,
        quantity: b.quantity,
        price: b.price,
        categoryIds: {
          for (final c in categories)
            if (b.types.contains(c.type)) c.id,
        },
      ),
  ];

  /// The bundled artwork of a product, or null when it has none.
  String? assetFor(String productId) {
    for (final p in products) {
      if (p.id == productId) return p.imageAsset;
    }
    return null;
  }

  /// Parse the catalogue JSON. Throws [FormatException] on anything it does
  /// not understand — a broken catalogue must fail loudly at build time, not
  /// quietly half-seed the shelf.
  factory Catalogue.parse(String source) {
    final json = jsonDecode(source) as Map<String, dynamic>;
    final categories = [
      for (final c in (json['categories'] as List? ?? const []))
        CatalogueCategory(
          id: c['id'] as String,
          slug: c['slug'] as String,
          name: c['name'] as String,
          sortOrder: (c['sortOrder'] as num?)?.toInt() ?? 0,
          type: c['type'] as String,
        ),
    ];
    final bySlug = {for (final c in categories) c.slug: c};

    final products = <CatalogueProduct>[];
    for (final p in (json['products'] as List? ?? const [])) {
      final slug = p['category'] as String?;
      final category = bySlug[slug];
      if (category == null) {
        throw FormatException('product "${p['name']}" has no known category');
      }
      products.add(
        CatalogueProduct(
          id: p['id'] as String,
          slug: p['slug'] as String?,
          sourceId: (p['sourceId'] as num?)?.toInt(),
          ref: p['ref'] as String?,
          type: p['type'] as String,
          category: category,
          name: p['name'] as String,
          price: (p['price'] as num?)?.toDouble(),
          stock: (p['stock'] as num?)?.toInt(),
          status: (p['status'] as String?) ?? StockStatus.inStock,
          notes: p['notes'] as String?,
          col1: (p['col1'] as num?)?.toInt(),
          barcode: p['barcode'] as String?,
          imageSource: p['imageSource'] as String?,
          imageAsset: p['imageAsset'] as String?,
        ),
      );
    }

    final bundles = [
      for (final b in (json['bundles'] as List? ?? const []))
        CatalogueBundle(
          name: b['name'] as String,
          quantity: (b['quantity'] as num).toInt(),
          price: (b['price'] as num).toDouble(),
          types: [
            for (final t in (b['types'] as List? ?? const [])) t as String,
          ],
        ),
    ];

    final s = json['store'] as Map<String, dynamic>;
    return Catalogue(
      version: (json['version'] as num?)?.toInt() ?? 1,
      source: json['source'] as String? ?? '',
      spec: json['spec'] as String? ?? '',
      currency: json['currency'] as String? ?? 'PHP',
      store: CatalogueStore(
        id: s['id'] as String,
        name: s['name'] as String,
        tagline: s['tagline'] as String? ?? '',
        receiptName: s['receiptName'] as String? ?? '',
        receiptTin: s['receiptTin'] as String? ?? '',
        receiptAddress: s['receiptAddress'] as String? ?? '',
        receiptAccreditation: s['receiptAccreditation'] as String? ?? '',
        receiptFooter: s['receiptFooter'] as String? ?? '',
        currency: s['currency'] as String? ?? 'PHP',
      ),
      categories: categories,
      products: products,
      bundles: bundles,
    );
  }

  /// The catalogue as it sits in the app bundle.
  ///
  /// The parsed catalogue is kept so anything can ask for the artwork of a
  /// product (the image widget does) without loading the bundle again.
  static Catalogue? _current;

  /// The catalogue this app run started with, if it was loaded.
  static Catalogue? get current => _current;

  static Future<Catalogue> load() async {
    if (_current != null) return _current!;
    final catalogue = Catalogue.parse(await rootBundle.loadString(assetPath));
    _current = catalogue;
    return catalogue;
  }
}

/// The shop itself, as the catalogue describes it.
class CatalogueStore {
  const CatalogueStore({
    required this.id,
    required this.name,
    required this.tagline,
    required this.receiptName,
    required this.receiptTin,
    required this.receiptAddress,
    required this.receiptAccreditation,
    required this.receiptFooter,
    required this.currency,
  });

  final String id;
  final String name;
  final String tagline;
  final String receiptName;
  final String receiptTin;
  final String receiptAddress;
  final String receiptAccreditation;
  final String receiptFooter;
  final String currency;
}

/// One shelf category.
class CatalogueCategory {
  const CatalogueCategory({
    required this.id,
    required this.slug,
    required this.name,
    required this.sortOrder,
    required this.type,
  });

  final String id;
  final String slug;
  final String name;
  final int sortOrder;

  /// The inventory sheet's own name for this shelf ("STICKER", "ART PRINT").
  final String type;
}

/// One product row of the inventory sheet.
class CatalogueProduct {
  const CatalogueProduct({
    required this.id,
    required this.slug,
    required this.sourceId,
    required this.ref,
    required this.type,
    required this.category,
    required this.name,
    required this.price,
    required this.stock,
    required this.status,
    required this.notes,
    required this.col1,
    required this.barcode,
    required this.imageSource,
    required this.imageAsset,
  });

  final String id;

  /// The product's slug ("bleeding-heart-sticker") — the identity the id is
  /// derived from, so a row keeps its id when the sheet is re-ordered.
  final String? slug;

  /// The row number on the sheet (1-based), and the id the server import uses.
  final int? sourceId;

  /// The item id the sheet wrote down ("#001"). Empty on most rows.
  final String? ref;
  final String type;
  final CatalogueCategory category;
  final String name;

  /// Null when the sheet's price was a placeholder ("₱xx.xx").
  final double? price;

  /// Null when the sheet's count was unreadable ("##").
  final int? stock;

  /// The shelf status the owner wrote by hand.
  final String status;

  /// The sheet's note, verbatim.
  final String? notes;

  /// The sheet's unnamed "Column 1", verbatim. Never interpreted.
  final int? col1;
  final String? barcode;

  /// The artwork file this row's design came from, inside assets/Assets.
  final String? imageSource;

  /// The artwork inside the app bundle, or null when the row has no art.
  final String? imageAsset;

  /// A row with no price cannot be sold (the sheet left it as a placeholder).
  bool get isActive => price != null && price! > 0;

  /// The units on hand; an unreadable count is zero, but the shelf status the
  /// owner wrote is kept as it is.
  int get stockOnHand => stock ?? 0;
}

/// One bundle deal.
class CatalogueBundle {
  const CatalogueBundle({
    required this.name,
    required this.quantity,
    required this.price,
    required this.types,
  });

  final String name;

  /// How many items make one bundle.
  final int quantity;

  /// What the whole bundle costs.
  final double price;

  /// The inventory types it applies to ("STICKER", "ART PRINT", …).
  final List<String> types;
}

/// What the catalogue seed did.
class CatalogueSeedReport {
  const CatalogueSeedReport({
    required this.storeCreated,
    required this.categoriesCreated,
    required this.productsCreated,
    required this.stockEventsCreated,
  });

  static const empty = CatalogueSeedReport(
    storeCreated: false,
    categoriesCreated: 0,
    productsCreated: 0,
    stockEventsCreated: 0,
  );

  final bool storeCreated;
  final int categoriesCreated;
  final int productsCreated;
  final int stockEventsCreated;

  bool get didAnything =>
      storeCreated ||
      categoriesCreated > 0 ||
      productsCreated > 0 ||
      stockEventsCreated > 0;
}

/// Put the bundled catalogue into the local database.
///
/// Idempotent by construction: a row that is already there is left exactly as
/// it is, so the owner's price edits and stock counts survive a re-seed, and
/// the opening stock is written as a stock event with the SAME id the server
/// import uses — so the two sides never count the same units twice.
class CatalogueSeed {
  CatalogueSeed._();

  static Future<CatalogueSeedReport> apply(
    AppDatabase db,
    Catalogue catalogue, {
    DateTime? at,
  }) async {
    final existingStores = await db.allStores();
    if (existingStores.isNotEmpty &&
        !existingStores.any((s) => s.id == catalogue.store.id)) {
      return CatalogueSeedReport.empty;
    }

    final now = at ?? DateTime.now().toUtc();
    final storeId = catalogue.store.id;

    if (await db.hasProducts(storeId)) {
      return CatalogueSeedReport.empty;
    }

    var storeCreated = false;
    var categoriesCreated = 0;
    var productsCreated = 0;
    var stockEventsCreated = 0;

    storeCreated = await db.seedStore(
      Store(
        id: storeId,
        name: catalogue.store.name,
        tagline: catalogue.store.tagline,
        ownerId: '',
        receiptName: catalogue.store.receiptName,
        receiptTin: catalogue.store.receiptTin,
        receiptAddress: catalogue.store.receiptAddress,
        receiptAccreditation: catalogue.store.receiptAccreditation,
        receiptFooter: catalogue.store.receiptFooter,
        currency: catalogue.store.currency,
        createdAt: now,
        updatedAt: now,
      ),
    );

    for (final c in catalogue.categories) {
      final created = await db.seedCategory(
        Category(
          id: c.id,
          storeId: storeId,
          name: c.name,
          sortOrder: c.sortOrder,
          isActive: true,
          createdAt: now,
          updatedAt: now,
          deletedAt: null,
          syncedAt: null,
        ),
      );
      if (created) categoriesCreated++;
    }

    for (final p in catalogue.products) {
      final created = await db.seedProduct(
        Product(
          id: p.id,
          storeId: storeId,
          categoryId: p.category.id,
          name: p.name,
          price: p.price ?? 0,
          barcode: p.barcode,
          // The bundled artwork, so the shelf renders with no network at all.
          imagePath: p.imageAsset,
          stockQuantity: 0,
          isActive: p.isActive,
          stockStatus: p.status,
          sourceRef: p.ref,
          notes: p.notes,
          sourceCol1: p.col1,
          createdAt: now,
          updatedAt: now,
          deletedAt: null,
          syncedAt: null,
        ),
      );
      if (created) productsCreated++;

      if (p.stockOnHand > 0) {
        final stocked = await db.seedOpeningStock(
          productId: p.id,
          delta: p.stockOnHand,
          storeId: storeId,
          at: now,
        );
        if (stocked) stockEventsCreated++;
      }
    }

    return CatalogueSeedReport(
      storeCreated: storeCreated,
      categoriesCreated: categoriesCreated,
      productsCreated: productsCreated,
      stockEventsCreated: stockEventsCreated,
    );
  }
}
