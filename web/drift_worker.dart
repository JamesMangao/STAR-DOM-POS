// web/drift_worker.dart — the drift database worker (W2).
//
// web/drift_worker.js is compiled FROM THIS FILE with:
//
//     dart compile js -O2 web/drift_worker.dart -o web/drift_worker.js
//
// Compiling it here instead of downloading drift's release asset is deliberate:
// the worker talks the drift wire protocol to the code in main.dart.js, so the
// two must come from the same drift version. `pubspec.lock` pins drift; this
// file is the matching worker for exactly that version.
//
// `WasmDatabase.workerMainForOpen()` is drift's own entry point for the worker
// that `WasmDatabase.open()` spawns (dedicated + shared variants).
import 'package:drift/wasm.dart';

void main() => WasmDatabase.workerMainForOpen();
