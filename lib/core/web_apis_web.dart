import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'picked_image.dart';

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

/// The backup layer's durable shelf (see `data/local_backup.dart`).
/// localStorage sits OUTSIDE the database the bug can wipe, survives a
/// restart synchronously (readable before the DB even opens) and is per
/// origin. A browser that blocks it — private mode, quota — gets `null` /
/// `false`; the app keeps selling and reports the miss in Settings.
String? localStorageRead(String key) {
  try {
    return web.window.localStorage.getItem(key);
  } catch (_) {
    return null;
  }
}

bool localStorageWrite(String key, String value) {
  try {
    web.window.localStorage.setItem(key, value);
    return true;
  } catch (_) {
    return false; // QuotaExceededError or blocked storage — caller reports it
  }
}

/// Update flow: `web/index.html` fires `stardom-update-ready` on window when
/// the service worker has the NEXT build installed and waiting. Nothing in the
/// app used to listen for it, so a deployed fix never reached an open tab —
/// the shell shows its "New version ready" bar from this callback.
void listenForAppUpdate(void Function() onReady) {
  try {
    final handler = (web.Event _) {
      onReady();
    };
    web.window.addEventListener('stardom-update-ready', handler.toJS);
  } catch (_) {
    // A browser that cannot watch for updates still runs the POS, silently.
  }
}

/// Hand the tab to that waiting worker: index.html's `stardomApplyUpdate`
/// activates it and reloads the page. The reload is about to happen, so the
/// promise it returns is deliberately not awaited.
void applyAppUpdate() {
  try {
    final fn = (web.window as JSObject).getProperty('stardomApplyUpdate'.toJS);
    if (fn != null && fn.isA<JSFunction>()) {
      (fn as JSFunction).callAsFunction(null);
    }
  } catch (_) {
    // No hook on this page: the button simply does nothing rather than throw.
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
  external JSPromise<JSAny?> release();
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

/// Design §2.10: `prefers-reduced-motion: reduce` must make everything
/// instant. Read live from the media query (not cached) so flipping the OS
/// setting while the app is open takes effect on the next frame. Guarded like
/// everything else here: an unsupported browser just returns false.
bool prefersReducedMotion() {
  try {
    return web.window
        .matchMedia('(prefers-reduced-motion: reduce)')
        .matches;
  } catch (_) {
    return false;
  }
}

/// W3/photo upload: open the system photo picker, take ONE image and downscale
/// it to ≤400 px BEFORE it reaches drift or the `pos-assets` bucket (device
/// rule: a 3 GB iPad tab must never hold 2000 px product art).
///
/// Returns null when the picker is dismissed without a choice.
Future<PickedImage?> pickImage({int maxDimension = 400}) async {
  return _pickImageFromSource(null, maxDimension: maxDimension);
}

/// W3: open the camera directly (rear-facing on iPad) and return ONE downscaled
/// image. Returns null when cancelled.
Future<PickedImage?> pickImageFromCamera({int maxDimension = 400}) async {
  return _pickImageFromSource('environment', maxDimension: maxDimension);
}

Future<PickedImage?> _pickImageFromSource(
  String? source, {
  required int maxDimension,
}) async {
  final input = web.HTMLInputElement()
    ..type = 'file'
    ..accept = 'image/*'
    ..style.display = 'none';
  if (source != null) {
    input.capture = source;
  }
  web.document.body?.append(input);
  try {
    final file = await _pickFile(input);
    if (file == null) return null;
    final (bytes, mime) = await _downscale(file, maxDimension);
    // An unreadable file is treated as no selection — never an upload of 0 B.
    if (bytes.isEmpty) return null;
    return PickedImage(
      bytes: bytes,
      mime: mime,
      filename: file.name.isEmpty ? 'image.${_extFor(mime)}' : file.name,
    );
  } finally {
    input.remove();
  }
}

/// A change event is not enough: dismissing the picker fires NO event at all,
/// and the caller would wait forever on "Cancel". So the pick settles on the
/// choice OR on the window regaining focus with an empty input (cancelled).
Future<web.File?> _pickFile(web.HTMLInputElement input) {
  final completer = Completer<web.File?>();
  var settled = false;
  StreamSubscription<web.Event>? changeSub;
  void Function(JSAny?)? focusHandler;

  web.File? chosen() {
    final list = input.files;
    if (list == null || list.length == 0) return null;
    return list.item(0);
  }

  void settle(web.File? file) {
    if (settled) return;
    settled = true;
    changeSub?.cancel();
    final handler = focusHandler;
    if (handler != null) {
      web.window.removeEventListener('focus', handler.toJS);
    }
    completer.complete(file);
  }

  changeSub = input.onChange.listen((_) => settle(chosen()));
  focusHandler = (JSAny? _) {
    // Let the change event win the race: it fires before focus returns.
    Future<void>.delayed(const Duration(milliseconds: 250), () {
      if (!settled) settle(chosen());
    });
  };
  web.window.addEventListener('focus', focusHandler.toJS);
  input.click();
  return completer.future;
}

/// Fit inside [maxDimension] x [maxDimension] and encode as WebP (falling back
/// to whatever the canvas actually produced — PNG on a browser without WebP).
/// Any failure returns the original bytes rather than losing the photo.
Future<(Uint8List, String)> _downscale(web.File file, int maxDimension) async {
  final originalMime = file.type.isEmpty ? 'image/jpeg' : file.type;
  final Uint8List original;
  try {
    original = Uint8List.view((await file.arrayBuffer().toDart).toDart);
  } catch (_) {
    return (Uint8List(0), originalMime);
  }
  try {
    final bitmap = await web.window.createImageBitmap(file).toDart;
    final nw = bitmap.width;
    final nh = bitmap.height;
    if (nw <= 0 || nh <= 0) return (original, originalMime);
    final scale = (maxDimension / (nw > nh ? nw : nh)).clamp(0.0, 1.0);
    final w = (nw * scale).round().clamp(1, maxDimension);
    final h = (nh * scale).round().clamp(1, maxDimension);
    final canvas = web.HTMLCanvasElement()
      ..width = w
      ..height = h;
    final ctx = canvas.getContext('2d') as web.CanvasRenderingContext2D;
    ctx.drawImage(bitmap, 0, 0, w, h);
    final decoded = _decodeDataUrl(canvas.toDataURL('image/webp', 0.85.toJS));
    if (decoded == null) return (original, originalMime);
    return decoded;
  } catch (_) {
    return (original, originalMime);
  }
}

(Uint8List, String)? _decodeDataUrl(String dataUrl) {
  if (!dataUrl.startsWith('data:')) return null;
  final comma = dataUrl.indexOf(',');
  if (comma < 0) return null;
  final mime = dataUrl.substring(5, comma).split(';').first;
  try {
    final bytes = Uint8List.fromList(
      base64Decode(dataUrl.substring(comma + 1)),
    );
    if (bytes.isEmpty) return null;
    return (bytes, mime.isEmpty ? 'image/webp' : mime);
  } catch (_) {
    return null;
  }
}

String _extFor(String mime) => switch (mime) {
  'image/png' => 'png',
  'image/jpeg' => 'jpg',
  _ => 'webp',
};

/// Hand a file to the iPad's share sheet. False means "this browser cannot
/// share files here" — the caller falls back to a download, never to nothing.
Future<bool> shareFile(
  String filename,
  String mimeType,
  Uint8List bytes,
) async {
  try {
    final blob = web.Blob(
      [bytes.toJS].toJS,
      web.BlobPropertyBag(type: mimeType),
    );
    final file = web.File(
      [blob].toJS,
      filename,
      web.FilePropertyBag(type: mimeType),
    );
    final data = web.ShareData(files: [file].toJS);
    final nav = web.window.navigator;
    if (!nav.canShare(data)) return false;
    await nav.share(data).toDart;
    return true;
  } catch (_) {
    // A dismissed sheet throws AbortError; an unsupported browser throws too.
    return false;
  }
}

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

/// W4: PWA install prompt. Captures the `beforeinstallprompt` event so the
/// app can show its own "Install this app" banner instead of relying on the
/// browser's hidden menu. Returns null on platforms without the event.
class PwaInstallPrompt {
  PwaInstallPrompt._();
  static final PwaInstallPrompt instance = PwaInstallPrompt._();

  JSPromise<JSAny?>? _deferred;

  /// Listen for `beforeinstallprompt` and stash the event for later use.
  void listen() {
    try {
      final handler = (web.Event e) {
        e.preventDefault();
        _deferred = (e as dynamic).prompt?.toDart as JSPromise<JSAny?>?;
      };
      web.window.addEventListener('beforeinstallprompt', handler.toJS);
    } catch (_) {}
  }

  /// Show the install prompt. Returns true when the prompt was shown.
  Future<bool> show() async {
    if (_deferred == null) return false;
    try {
      await _deferred!.toDart;
      _deferred = null;
      return true;
    } catch (_) {
      _deferred = null;
      return false;
    }
  }

  bool get isAvailable => _deferred != null;
}
