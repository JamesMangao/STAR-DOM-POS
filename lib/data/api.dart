import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
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

  /// The initialised client, for auth and anything else that needs it.
  SupabaseClient get client => _c;

  bool get isReady => _client != null;

  Future<void> init() async {
    if (!Env.isConfigured || isReady) return;
    await Supabase.initialize(
      url: Env.supabaseUrl,
      publishableKey: Env.supabaseAnonKey,
    );
    _client = Supabase.instance.client;
  }

  /// Push one entity row. Two conflict rules, split by whether the table's
  /// rows are immutable:
  ///
  ///   * APPEND-ONCE (orders, order_items, payments, order_voids,
  ///     stock_events): `ignoreDuplicates` — ON CONFLICT DO NOTHING, so
  ///     replaying a row or a whole bundle never duplicates data.
  ///   * MERGE (the LWW tables of 001 + day_closes): DO UPDATE. DO NOTHING
  ///     here silently dropped every edit made AFTER the row was first
  ///     pulled: a price change, an is_active toggle or the bundle_rules JSON
  ///     would report ok and never reach the server, and a site-data clear
  ///     would resurrect the old values. The server's lww_guard() decides
  ///     whether the merge actually lands (stale writes are refused there).
  Future<void> pushRow(String table, Map<String, dynamic> row) async {
    switch (table) {
      case SaleBundle.entity:
        return pushSale(row);
      case VoidBundle.entity:
        return pushVoid(row);
      default:
        if (table == 'stores') {
          // RLS on stores checks the PROPOSED row of the upsert: PostgreSQL
          // evaluates the INSERT policy's WITH CHECK before it resolves the
          // conflict, and this payload deliberately omits owner_id — so the
          // proposal carries owner_id = NULL and the server rejects the whole
          // write with "new row violates row-level security policy for table
          // stores" (reproduced server-side, 2026-10-25). Stamping the
          // session's own uid makes the check pass; the policy itself still
          // pins owner_id = auth.uid(), so a client can only ever claim its
          // own ownership — never write someone else's.
          final uid = _c.auth.currentUser?.id;
          if (uid != null) row['owner_id'] = uid;
        }
        if (_mergeOnConflict.contains(table)) {
          await _c.from(table).upsert(row);
        } else {
          await _c.from(table).upsert(row, ignoreDuplicates: true);
        }
    }
  }

  /// Tables whose push must UPDATE an existing row (LWW-guarded server-side).
  /// Everything else pushes insert-if-absent.
  static const Set<String> _mergeOnConflict = {
    'stores',
    'devices',
    'categories',
    'products',
    'payment_methods',
    'settings',
    'day_closes',
  };

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
        .order(table == 'settings' ? 'key' : 'id', ascending: true)
        .limit(limit);
    return (res as List).cast<Map<String, dynamic>>();
  }

  /// The store's device rows as the server keeps them, for the
  /// claim-after-site-data-clear flow: the booth re-attaches to its old row
  /// instead of registering a lookalike. RLS keeps this owner-scoped.
  Future<List<Map<String, dynamic>>> listDevices(String storeId) async {
    final res = await _c.from('devices').select().eq('store_id', storeId);
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
  /// (B5). A timeout or a network failure is OFFLINE, never a failed attempt.
  ///
  /// W2/web: `dart:io` does not exist in the browser, so the network shapes are
  /// `package:http`'s `ClientException` (what the browser fetch layer raises,
  /// including `XMLHttpRequestError`) plus `TimeoutException`. The VM's
  /// `SocketException`/`HttpException` are matched by NAME so one classifier
  /// serves both compile targets without importing `dart:io` anywhere.
  static PushResult classifyError(Object error) {
    if (error is AuthException) return PushResult.authExpired;
    if (error is PostgrestException) {
      final code = int.tryParse(error.code ?? '');
      return PushPolicy.classify(status: code);
    }
    if (error is TimeoutException || error is http.ClientException) {
      return PushResult.offline;
    }
    final name = error.runtimeType.toString();
    if (name == 'SocketException' ||
        name == 'HttpException' ||
        name == 'XMLHttpRequestError') {
      return PushResult.offline;
    }
    return PushResult.failed;
  }

  /// The server's own words for a rejected write — what actually lands in the
  /// outbox's last_error and (through SyncEngine) in the snackbar. Without
  /// this, a refusal is only ever "attempt 2 failed", and the owner cannot
  /// tell an RLS rejection from a stale session from a conflict.
  ///
  /// Transport shapes carry no server opinion and return null; the head line
  /// of an unknown failure shape is kept so Sync details is never silent.
  /// Truncated: this string is shown whole in a snack bar.
  static String? describeError(Object error) {
    const maxLen = 180;
    String clip(String s) =>
        s.length > maxLen ? '${s.substring(0, maxLen - 1)}…' : s;
    if (error is PostgrestException) {
      final code = int.tryParse(error.code ?? '');
      if (code == null || code < 400) return null;
      final msg = error.message.trim();
      final details = error.details?.toString().trim() ?? '';
      final body = details.isNotEmpty && details != msg
          ? '$msg — $details'
          : msg;
      return clip(
        body.isEmpty ? 'HTTP $code: server rejected the write' : 'HTTP $code: $body',
      );
    }
    return clip('${error.runtimeType}: $error');
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

  /// W3: the image BYTES for the offline cache. A signed URL is useless
  /// offline (it expires) and a cross-origin <img> is not reliably cached by
  /// WebKit, so the bytes are fetched here and stored in the local
  /// `image_cache` table, which renders with the network off.
  Future<Uint8List> downloadImage(String path) async =>
      await _c.storage.from('pos-assets').download(path);

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
