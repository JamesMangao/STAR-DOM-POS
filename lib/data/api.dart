import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/env.dart';

/// Supabase REST + Storage client. Lazy — only initialized when env is set.
class Api {
  Api._();
  static final Api instance = Api._();

  SupabaseClient? _client;
  SupabaseClient get _c => _client!;

  bool get isReady => _client != null;

  Future<void> init() async {
    if (!Env.isConfigured || isReady) return;
    await Supabase.initialize(url: Env.supabaseUrl, anonKey: Env.supabaseAnonKey);
    _client = Supabase.instance.client;
  }

  /// Push one entity row. Idempotent: server dedupes on primary key.
  Future<void> pushRow(String table, Map<String, dynamic> row) async {
    await _c.from(table).upsert(row);
  }

  /// Delta pull: rows updated since [since]. Null = full pull.
  Future<List<Map<String, dynamic>>> pullRows(String table, {DateTime? since}) async {
    var q = _c.from(table).select();
    if (since != null) {
      q = _c.from(table).select().gt('updated_at', since.toIso8601String());
    }
    final res = await q;
    return (res as List).cast<Map<String, dynamic>>();
  }

  /// Upload a file to the pos-assets bucket. Returns the object path.
  Future<String> uploadImage(String path, List<int> bytes, String mime) async {
    await _c.storage.from('pos-assets').uploadBinary(path, bytes,
        fileOptions: FileOptions(contentType: mime, upsert: true));
    return path;
  }

  /// Short-lived signed URL for product/QR images.
  Future<String> signedUrl(String path,
      {Duration ttl = const Duration(minutes: 5)}) async {
    final res = await _c.storage
        .from('pos-assets')
        .createSignedUrl(path, ttl.inSeconds);
    return res;
  }

  String publicUrl(String path) =>
      '${Env.supabaseUrl}/storage/v1/object/public/pos-assets/$path';

  String encode(Map<String, dynamic> m) => jsonEncode(m);
}
