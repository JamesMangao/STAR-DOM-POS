import 'package:drift/wasm.dart';

import 'db.dart';
import 'db_storage.dart';

/// The drift database name — the OPFS file / IndexedDB database name.
const String kDatabaseName = 'stardom_pos';

/// Web opener (W2).
///
/// `WasmDatabase.open` probes the browser and picks the most reliable storage
/// it can actually use, then tells us which one it chose. That choice is what
/// Settings reports: no COOP/COEP headers are served, so `opfsLocks` is
/// normally unavailable and an iPad lands on an IndexedDB backend, which is
/// both cross-origin-fetch-safe (Supabase and signed image URLs keep working)
/// and durable across restarts.
///
/// `sqlite3.wasm` and `drift_worker.js` are committed in `web/` and shipped as
/// part of the build, so nothing is fetched from a CDN at runtime (W4).
Future<DatabaseOpenResult> openAppDatabase() async {
  final result = await WasmDatabase.open(
    databaseName: kDatabaseName,
    sqlite3Uri: Uri.parse('sqlite3.wasm'),
    driftWorkerUri: Uri.parse('drift_worker.js'),
  );

  final impl = result.chosenImplementation;
  return DatabaseOpenResult(
    db: AppDatabase(result.resolvedExecutor),
    storageMode: impl.name,
    persistent: impl.storageApi != null,
    missingFeatures: result.missingFeatures.map((f) => f.name).toList(),
  );
}
