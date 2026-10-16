import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// W2: ask the browser to make this origin's storage persistent, so WebKit does
/// not evict the local database (every unsynced sale would go with it).
/// Returns what the browser ANSWERED, not what we asked for.
Future<bool> requestPersistentStorage() async {
  try {
    final storage = web.window.navigator.storage;
    if ((await storage.persisted().toDart).toDart) return true;
    return (await storage.persist().toDart).toDart;
  } catch (_) {
    return false; // unsupported (private mode, old WebKit) — ignore silently
  }
}

@JS('navigator')
external _Navigator get _navigator;

extension type _Navigator(JSObject _) implements JSObject {
  external _WakeLock? get wakeLock;
  external bool get onLine;
}

extension type _WakeLock(JSObject _) implements JSObject {
  external JSPromise<JSObject> request(String type);
  external JSPromise<JSObject> release();
}

_WakeLock? _sentinel;

/// W-rule: while the app is visible, keep the screen on. Guarded: an
/// unsupported browser, or a denied request, is ignored silently.
Future<bool> acquireWakeLock() async {
  try {
    final wakeLock = _navigator.wakeLock;
    if (wakeLock == null) return false;
    _sentinel = await wakeLock.request('screen').toDart as _WakeLock;
    return true;
  } catch (_) {
    return false;
  }
}

Future<void> releaseWakeLock() async {
  final sentinel = _sentinel;
  _sentinel = null;
  try {
    await sentinel?.release().toDart;
  } catch (_) {}
}

/// W2: "Export data (JSON)" — a Blob download, since a PWA has no filesystem
/// and no share sheet for a plain file on every iOS version.
void downloadFile(String filename, String mimeType, Uint8List bytes) {
  final blob = web.Blob([bytes.toJS].toJS, web.BlobPropertyBag(type: mimeType));
  final url = web.URL.createObjectURL(blob);
  final anchor = web.HTMLAnchorElement()
    ..href = url
    ..download = filename
    ..style.display = 'none';
  web.document.body?.append(anchor);
  anchor.click();
  anchor.remove();
  web.URL.revokeObjectURL(url);
}

bool get hasStorageManager => true;

/// Expose the boot facts on `window.__stardomBootInfo` for the offline test
/// (scripts/offline-test.js) and for a human debugging an installed PWA in
/// Safari's console. It contains no secret: storage mode, persistence verdict,
/// outbox counts and the signed-in flag.
void setBootInfo(String json) {
  try {
    // `Window` is an extension type over JSObject, so the property helper is
    // reached through the representation type.
    (web.window as JSObject).setProperty('__stardomBootInfo'.toJS, json.toJS);
  } catch (_) {}
}
