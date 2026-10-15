/// Build-time injected config (--dart-define). Never committed.
class Env {
  Env._();

  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');
  static const ownerEmail = String.fromEnvironment('OWNER_EMAIL');
  static const ownerPassword = String.fromEnvironment('OWNER_PASSWORD');

  static bool get isConfigured =>
      supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;

  static bool get hasOwnerCreds =>
      ownerEmail.isNotEmpty && ownerPassword.isNotEmpty;
}
