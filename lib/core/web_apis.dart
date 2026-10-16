/// Guarded browser APIs (W2/W3/W4).
///
/// Everything here is best-effort: on a platform that lacks the API the value
/// is simply false / a no-op, and the app keeps selling. `library;` + the
/// conditional export means the VM build (tests) never sees `dart:js_interop`.
library;

export 'web_apis_stub.dart' if (dart.library.js_interop) 'web_apis_web.dart';
