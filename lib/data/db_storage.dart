import 'db.dart';

/// What the platform opener actually did (W2).
///
/// The web build has to REPORT which storage backend drift/WebKit picked
/// (`opfsShared`, `opfsLocks`, `sharedIndexedDb`, `unsafeIndexedDb`,
/// `inMemory`) instead of assuming one, because only some of them survive a
/// reboot — and `inMemory` means every sale is lost on reload, which the owner
/// must be able to see in Settings.
class DatabaseOpenResult {
  const DatabaseOpenResult({
    required this.db,
    required this.storageMode,
    required this.persistent,
    required this.missingFeatures,
  });

  final AppDatabase db;

  /// `WasmStorageImplementation.name` on the web; a plain label elsewhere.
  final String storageMode;

  /// False only when nothing survives a reload (`inMemory`).
  final bool persistent;

  /// Browser features drift found missing, which is why it picked this mode.
  final List<String> missingFeatures;

  /// The single line printed in Settings.
  String get description => persistent
      ? '$storageMode — data survives reloads'
      : '$storageMode — NOT persistent, do not use for real sales';
}
