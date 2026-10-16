import 'dart:convert';
import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/env.dart';
import 'bundle.dart';

/// Supabase REST + Storage client. Lazy — only initialized when env is set.
class Api {
  Api._();
  static final Api instance = Api._();

  SupabaseClient? _client;
  SupabaseClient get _c => _client!;

  bool get isReady => _client != null;

  Future<void> init() async {
    if (!Env.isConfigured || isReady) return;
    await Supabase.initialize(
      url: Env.supabaseUrl,
      publishableKey: Env.supabaseAnonKey,
    );
    _client = Supabase.instance.client;
  }

  /// Push one entity row. Idempotent: every append-only table inserts with
  /// `ON CONFLICT (id) DO NOTHING` (`ignoreDuplicates`), so replaying a row or
  /// a whole bundle never duplicates data.
  Future<void> pushRow(String table, Map<String, dynamic> row) async {
    switch (table) {
      case SaleBundle.entity:
        return pushSale(row);
      case VoidBundle.entity:
        return pushVoid(row);
      default:
        await _c.from(table).upsert(row, ignoreDuplicates: true);
    }
  }

  /// A sale reaches the server as ONE bundle: order + items + payment + stock
  /// events. Each table insert is insert-if-absent, so a replayed bundle
  /// leaves 1 order, N items, 1 payment and N stock events.
  Future<void> pushSale(Map<String, dynamic> bundle) async {
    final order = bundle[SaleBundle.order] as Map<String, dynamic>?;
    final items = (bundle[SaleBundle.items] as List?)?.cast<Map<String, dynamic>>() ?? const [];
    final payment = bundle[SaleBundle.payment] as Map<String, dynamic>?;
    final stock =
        (bundle[SaleBundle.stockEvents] as List?)?.cast<Map<String, dynamic>>() ?? const [];
    if (order != null) {
      await _c.from('orders').upsert(order, ignoreDuplicates: true);
    }
    if (items.isNotEmpty) {
      await _c.from('order_items').upsert(items, ignoreDuplicates: true);
    }
    if (payment != null) {
      await _c.from('payments').upsert(payment, ignoreDuplicates: true);
    }
    if (stock.isNotEmpty) {
      await _c.from('stock_events').upsert(stock, ignoreDuplicates: true);
    }
  }

  /// A void reaches the server as its own bundle: order_voids + reversal
  /// stock events. The order row is never part of a void push.
  Future<void> pushVoid(Map<String, dynamic> bundle) async {
    final voidRow = bundle[VoidBundle.voidRow] as Map<String, dynamic>?;
    final stock =
        (bundle[VoidBundle.stockEvents] as List?)?.cast<Map<String, dynamic>>() ?? const [];
    if (voidRow != null) {
      await _c.from('order_voids').upsert(voidRow, ignoreDuplicates: true);
    }
    if (stock.isNotEmpty) {
      await _c.from('stock_events').upsert(stock, ignoreDuplicates: true);
    }
  }

  /// Delta pull: rows updated since [since]. Null = full pull.
  Future<List<Map<String, dynamic>>> pullRows(
    String table, {
    DateTime? since,
  }) async {
    var q = _c.from(table).select();
    if (since != null) {
      q = _c.from(table).select().gt('updated_at', since.toIso8601String());
    }
    final res = await q;
    return (res as List).cast<Map<String, dynamic>>();
  }

  /// Upload a file to the pos-assets bucket. Returns the object path.
  Future<String> uploadImage(String path, Uint8List bytes, String mime) async {
    await _c.storage
        .from('pos-assets')
        .uploadBinary(
          path,
          bytes,
          fileOptions: FileOptions(contentType: mime, upsert: true),
        );
    return path;
  }

  /// Short-lived signed URL for product/QR images.
  Future<String> signedUrl(
    String path, {
    Duration ttl = const Duration(minutes: 5),
  }) async {
    final res = await _c.storage
        .from('pos-assets')
        .createSignedUrl(path, ttl.inSeconds);
    return res;
  }

  String publicUrl(String path) =>
      '${Env.supabaseUrl}/storage/v1/object/public/pos-assets/$path';

  String encode(Map<String, dynamic> m) => jsonEncode(m);
}
