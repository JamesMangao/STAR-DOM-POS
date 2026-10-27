/// One name-normalisation rule for the whole sync stack.
///
/// Two catalogue rows with names that differ only in case or spacing are the
/// SAME shelf item ("PHM" vs "phm", "Gay af" vs "gay af" — both appeared in
/// the live database and showed twice on the Sell screen). Every layer that
/// decides "is this the same thing?" — the pull-time merge, the post-pull
/// dedupe and the server's unique index (migration 006) — must agree, or the
/// layers fight each other. SQL mirrors this in `norm_name()` exactly.
class NameNorm {
  NameNorm._();

  /// lowercase, collapse inner whitespace runs to one space, trim the ends.
  static String normalize(String name) =>
      name.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

  /// True when two names are the same shelf item under [normalize].
  static bool equal(String a, String b) => normalize(a) == normalize(b);
}
