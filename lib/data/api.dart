import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/env.dart';
import 'bundle.dart';
import 'sync_policy.dart';

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
  /// events, written PARENTS FIRST (B6). Each table insert is
  /// insert-if-absent, so a replayed bundle leaves 1 order, N items, 1 payment
  /// and N stock events — and a failure halfway leaves a valid prefix.
  Future<void> pushSale(Map<String, dynamic> bundle) async {
    for (final r in SalePush.rows(bundle)) {
      await _c.from(r.table).upsert(r.row, ignoreDuplicates: true);
    }
  }

  /// A void reaches the server as its own bundle: order_voids + reversal
  /// stock events. The order row is never part of a void push.
  Future<void> pushVoid(Map<String, dynamic> bundle) async {
    for (final r in VoidPush.rows(bundle)) {
      await _c.from(r.table).upsert(r.row, ignoreDuplicates: true);
    }
  }

  /// One page of a delta pull (B3/B4), keyset-paged on the SERVER clock.
  ///
  /// Rows are ordered by (cursor column, id) and filtered with `>=` on the
  /// cursor value; the caller then discards the rows at or below the cursor it
  /// already applied ([PullPage.after]). That is what makes a page boundary
  /// repeat-free without a compound `or=` filter, and because the cursor only
  /// ever holds a value the SERVER wrote, device clock skew cannot lose a row.
  Future<List<Map<String, dynamic>>> pullPage(
    String table, {
    required PullCursor cursor,
    int limit = PullPlan.pageSize,
  }) async {
    final col = PullPlan.cursorColumn(table);
    var q = _c.from(table).select();
    if (cursor.cursorValue != null) {
      q = q.gte(col, cursor.cursorValue!.toUtc().toIso8601String());
    }
    final res = await q
        .order(col, ascending: true)
        .order('id', ascending: true)
        .limit(limit);
    return (res as List).cast<Map<String, dynamic>>();
  }

  /// B7: the server assigns this device's next free 2-character code, so two
  /// devices can never pick the same one (order_no is globally unique). The
  /// call is idempotent on the device id: a retry returns the same code.
  Future<DeviceRegistration> registerDevice({
    required String deviceId,
    required String storeId,
    required String deviceName,
  }) async {
    final res = await _c.rpc(
      'register_device',
      params: {
        'p_device_id': deviceId,
        'p_store_id': storeId,
        'p_device_name': deviceName,
      },
    );
    final row = (res as List).cast<Map<String, dynamic>>().first;
    return DeviceRegistration(
      // The RPC's OUT column is `device_id` (a `returns table` column named
      // `id` would shadow the devices.id column inside plpgsql).
      deviceId: row['device_id'] as String,
      deviceCode: row['device_code'] as String,
    );
  }

  /// How long a push may take before the row is left for the next tick.
  static const Duration pushTimeout = Duration(seconds: 20);

  /// Classify a transport/provider error into the push policy's vocabulary
  /// (B5). A timeout, a socket error or a DNS failure is OFFLINE, never a
  /// failed attempt.
  static PushResult classifyError(Object error) {
    if (error is AuthException) return PushResult.authExpired;
    if (error is PostgrestException) {
      final code = int.tryParse(error.code ?? '');
      return PushPolicy.classify(status: code);
    }
    if (error is SocketException ||
        error is TimeoutException ||
        error is HttpException) {
      return PushResult.offline;
    }
    return PushResult.failed;
  }

  /// True when the SDK already has a session that can still be refreshed.
  Future<bool> refreshSession() async {
    try {
      final res = await _c.auth.refreshSession();
      return res.session != null;
    } catch (_) {
      return false;
    }
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

/// What the server decided for this device (B7).
class DeviceRegistration {
  const DeviceRegistration({required this.deviceId, required this.deviceCode});

  final String deviceId;
  final String deviceCode;
}
