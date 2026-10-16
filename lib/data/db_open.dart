/// Platform-specific database opener (W2).
///
/// `flutter test` / a Dart VM run resolve to `db_open_io.dart`; the web build
/// resolves to `db_open_web.dart`. The condition is `dart.library.js_interop`
/// rather than `dart.library.html` so it is true for BOTH the dart2js and the
/// WasmGC compile targets, and false on the VM.
library;

export 'db_open_io.dart' if (dart.library.js_interop) 'db_open_web.dart';
export 'db_storage.dart';
