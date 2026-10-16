import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'api.dart';

/// W1 — authentication is a ONE-TIME sign-in screen, not embedded credentials.
///
/// The old design compiled `OWNER_EMAIL` / `OWNER_PASSWORD` into the app and
/// signed in silently. In a public web bundle that password is readable by
/// anyone who opens devtools, so it is gone: the owner types it once, inside
/// the installed app, and `supabase_flutter` persists the session itself
/// (localStorage on the web) and refreshes it silently afterwards.
///
/// Selling NEVER depends on auth. The local database is primary, the outbox
/// keeps filling while signed out, and a missing session is only a small
/// "Sign in to sync" chip.
class OwnerAuth {
  OwnerAuth._();
  static final OwnerAuth instance = OwnerAuth._();

  /// Deliberate client-side delay after a rejected attempt — the server is the
  /// real gate; this only makes guessing inside the app pointless.
  static const Duration attemptDelay = Duration(seconds: 2);

  final _controller = StreamController<bool>.broadcast();
  Stream<bool> get changes => _controller.stream;

  StreamSubscription<AuthState>? _sub;
  bool _signedIn = false;
  String? _userId;

  bool get signedIn => _signedIn;
  String? get userId => _userId;

  /// True when the build actually carries the two public defines.
  bool get configured => Api.instance.isReady;

  /// Start watching the SDK's session, and adopt one that is already restored
  /// from a previous visit (no password needed for a surviving session).
  Future<void> init() async {
    if (!Api.instance.isReady) return;
    _sub ??= Api.instance.client.auth.onAuthStateChange.listen((state) {
      _apply(state.session);
    });
    _apply(Api.instance.client.auth.currentSession);
  }

  void _apply(Session? session) {
    final signedIn = session != null;
    if (signedIn == _signedIn && session?.user.id == _userId) return;
    _signedIn = signedIn;
    _userId = session?.user.id;
    if (!_controller.isClosed) _controller.add(_signedIn);
  }

  /// The first-run (or expired-session) sign-in. Returns a plain verdict; the
  /// UI shows a generic message and never echoes the server's error text.
  Future<SignInOutcome> signIn({
    required String email,
    required String password,
  }) async {
    if (!Api.instance.isReady) return SignInOutcome.notConfigured;
    if (email.trim().isEmpty || password.isEmpty) {
      return SignInOutcome.invalidInput;
    }
    try {
      final res = await Api.instance.client.auth.signInWithPassword(
        email: email.trim(),
        password: password,
      );
      _apply(res.session);
      return _signedIn ? SignInOutcome.ok : SignInOutcome.rejected;
    } on AuthException {
      await Future<void>.delayed(attemptDelay);
      return SignInOutcome.rejected;
    } catch (_) {
      await Future<void>.delayed(attemptDelay);
      // A transport failure is not a wrong password — say "offline", not
      // "rejected", so nobody retypes a correct password forever.
      return SignInOutcome.offline;
    }
  }

  Future<void> signOut() async {
    if (!Api.instance.isReady) return;
    try {
      await Api.instance.client.auth.signOut();
    } catch (_) {}
    _apply(null);
  }
}

enum SignInOutcome {
  ok,
  rejected,
  offline,
  invalidInput,
  notConfigured;

  /// Generic, non-revealing copy for the sign-in screen.
  String get message => switch (this) {
    ok => 'Signed in',
    rejected => 'Sign-in failed. Check the email and password.',
    offline => 'No connection. You can keep selling — sync will catch up.',
    invalidInput => 'Enter the owner email and password.',
    notConfigured => 'This build has no Supabase URL/key (check dart-defines).',
  };
}
