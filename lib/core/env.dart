/// Build-time injected config (`--dart-define`). Never committed.
///
/// W1: the web bundle is PUBLIC, so ONLY the two public values are ever
/// compiled into it. `OWNER_EMAIL` / `OWNER_PASSWORD` used to live here and
/// were therefore extractable from `main.dart.js`; the app now asks the owner
/// to sign in once, on a first-run screen, and never carries the password.
/// Those two keys stay in `.env` for the Node scripts only (import.js still
/// creates the owner through the admin API).
class Env {
  Env._();

  static const supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://pykhzrpgdszcwvpydebt.supabase.co',
  );
  static const supabaseAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue: 'sb_publishable_GUsWizNLV0LhXs-n_0gfTg_rjivKdJ5',
  );

  static bool get isConfigured =>
      supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;

  /// The complete `--dart-define` whitelist (scripts/env.js and
  /// scripts/build-web.js must agree with this list).
  static const dartDefineWhitelist = ['SUPABASE_URL', 'SUPABASE_ANON_KEY'];
}
