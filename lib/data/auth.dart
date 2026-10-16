import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/env.dart';

/// Silent auth — no login UI. Auto sign-in with embedded owner creds.
class SilentAuth {
  SilentAuth._();
  static final SilentAuth instance = SilentAuth._();

  static const _kUserId = 'owner_user_id';

  final _storage = const FlutterSecureStorage();

  bool _inited = false;
  bool _signedIn = false;
  String? _userId;
  String? lastError;

  bool get signedIn => _signedIn;
  String? get userId => _userId;

  /// Call once at app start. Offline-safe: never blocks.
  Future<void> init() async {
    if (_inited) return;
    _inited = true;
    try {
      final saved = await _storage.read(key: _kUserId);
      if (saved != null) {
        _userId = saved;
        _signedIn = true;
      }
    } catch (_) {
      // secure storage unavailable (e.g. desktop test) — stay signed-out
    }
  }

  /// Sign in with the embedded owner credentials. Retries in background on failure.
  Future<bool> signIn() async {
    if (!Env.hasOwnerCreds || !Env.isConfigured) return false;
    try {
      final res = await Supabase.instance.client.auth.signInWithPassword(
        email: Env.ownerEmail,
        password: Env.ownerPassword,
      );
      final uid = res.user?.id;
      if (uid == null) return false;
      _userId = uid;
      _signedIn = true;
      lastError = null;
      try {
        await _storage.write(key: _kUserId, value: uid);
      } catch (_) {}
      return true;
    } catch (e) {
      lastError = e.toString();
      return false;
    }
  }

  /// Restore a persisted session (if Supabase still holds it) without creds.
  Future<bool> restoreSession() async {
    try {
      final session = Supabase.instance.client.auth.currentSession;
      if (session == null) return false;
      _userId = session.user.id;
      _signedIn = true;
      return true;
    } catch (_) {
      return false;
    }
  }

  Map<String, String> authHeaders() => const {};

  String encodeSession(Session s) =>
      jsonEncode({'access': s.accessToken, 'refresh': s.refreshToken});
}
